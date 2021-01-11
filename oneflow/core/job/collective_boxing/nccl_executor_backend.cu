/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/job/collective_boxing/nccl_executor_backend.h"
#include "oneflow/core/job/collective_boxing/request_store.h"
#include "oneflow/core/device/nccl_util.h"
#include "oneflow/core/graph/boxing/collective_boxing_util.h"
#include "oneflow/core/job/resource_desc.h"
#include "oneflow/core/job/machine_context.h"
#include "oneflow/core/control/ctrl_client.h"
#include "oneflow/core/kernel/batch_memcpy_kernel_util.h"
#include "oneflow/core/job/global_for.h"
#include "oneflow/core/thread/thread_pool.h"
#include "oneflow/core/device/cuda_util.h"
#include <nccl.h>

#include <memory>

namespace oneflow {

namespace boxing {

namespace collective {

namespace {

ncclRedOp_t GetNcclReduceOp(ReduceMethod reduce_method) {
  if (reduce_method == kReduceMethodSum) {
    return ncclRedOp_t::ncclSum;
  } else {
    UNIMPLEMENTED();
  }
}

std::string GetNcclUniqueIdRpcKey(const std::string& name, int64_t stream_id) {
  return "CollectiveBoxingExecutorNcclUniqueIdRpcKey-" + name + "-" + std::to_string(stream_id);
}

int64_t GetRequestSize(const RequestDesc& request) {
  return Shape(request.op_desc().shape()).elem_cnt()
         * GetSizeOfDataType(request.op_desc().data_type());
}

int64_t GetAlignedRequestSize(const RequestDesc& request) {
  return GetCudaAlignedSize(GetRequestSize(request));
}

struct CopyParams {
  void* dst;
  const void* src;
  int64_t count;
};

constexpr int64_t kMultiCopyParamsMaxSize = 128;

struct MultiCopyParams {
  CopyParams params[kMultiCopyParamsMaxSize];
  int64_t count;

  MultiCopyParams() : count(0), params{} {}

  void Add(void* dst, const void* src, int64_t count) {
    CHECK_LT(this->count, kMultiCopyParamsMaxSize);
    params[this->count].dst = dst;
    params[this->count].src = src;
    params[this->count].count = count;
    this->count += 1;
  }
};

using BulkType = ulonglong2;

__global__ void MultiCopyGpu(MultiCopyParams multi_params) {
  for (int64_t p = 0; p < multi_params.count; ++p) {
    const CopyParams params = multi_params.params[p];
    auto* bulk_dst = reinterpret_cast<BulkType*>(params.dst);
    const auto* bulk_src = reinterpret_cast<const BulkType*>(params.src);
    const int64_t bulk_count = params.count / sizeof(BulkType);
    CUDA_1D_KERNEL_LOOP_T(int64_t, i, bulk_count) { bulk_dst[i] = bulk_src[i]; }
    const int64_t tail_offset = bulk_count * sizeof(BulkType);
    auto* tail_dst = reinterpret_cast<char*>(params.dst) + tail_offset;
    const auto* tail_src = reinterpret_cast<const char*>(params.src) + tail_offset;
    const int64_t tail_count = params.count - tail_offset;
    CUDA_1D_KERNEL_LOOP_T(int64_t, i, tail_count) { tail_dst[i] = tail_src[i]; }
  }
}

void MultiCopy(cudaStream_t stream, const MultiCopyParams& multi_params) {
  if (multi_params.count <= 0) { return; }
  CHECK_LE(multi_params.count, kMultiCopyParamsMaxSize);
  int64_t max_count = multi_params.params[0].count;
  for (int64_t i = i; i < multi_params.count; ++i) {
    max_count = std::max(max_count, multi_params.params[i].count);
  }
  MultiCopyGpu<<<BlocksNum4ThreadsNum(max_count), kCudaThreadsNumPerBlock, 0, stream>>>(
      multi_params);
}

class CommRank final {
 public:
  OF_DISALLOW_COPY(CommRank);
  CommRank(int32_t device_id, int32_t global_rank, int32_t global_rank_count, int32_t local_rank,
           int32_t local_rank_count)
      : device_id_(device_id),
        global_rank_(global_rank),
        global_rank_count_(global_rank_count),
        local_rank_(local_rank),
        local_rank_count_(local_rank_count),
        nccl_comm_(nullptr) {}

  CommRank(CommRank&& rhs) noexcept {
    this->device_id_ = rhs.device_id_;
    this->global_rank_ = rhs.global_rank_;
    this->global_rank_count_ = rhs.global_rank_count_;
    this->local_rank_ = rhs.local_rank_;
    this->local_rank_count_ = rhs.local_rank_count_;
    this->nccl_comm_ = rhs.nccl_comm_;
    rhs.nccl_comm_ = nullptr;
  }

  ~CommRank() {
    if (nccl_comm_ != nullptr) {
      CudaCurrentDeviceGuard(device_id_);
      OF_NCCL_CHECK(ncclCommDestroy(nccl_comm_));
    }
  }

  int32_t device_id() const { return device_id_; }

  int32_t global_rank() const { return global_rank_; }

  int32_t global_rank_count() const { return global_rank_count_; }

  int32_t local_rank() const { return local_rank_; }

  int32_t local_rank_count() const { return local_rank_count_; }

  ncclComm_t nccl_comm() const { return nccl_comm_; }

  void InitRank(ncclUniqueId unique_id) {
    CudaCurrentDeviceGuard(device_id_);
    OF_NCCL_CHECK(ncclCommInitRank(&nccl_comm_, global_rank_count_, unique_id, global_rank_));
  }

 private:
  int32_t device_id_;
  int32_t global_rank_;
  int32_t global_rank_count_;
  int32_t local_rank_;
  int32_t local_rank_count_;
  ncclComm_t nccl_comm_;
};

class CommGroup final {
 public:
  OF_DISALLOW_COPY(CommGroup);
  CommGroup() = default;
  ~CommGroup() = default;
  CommGroup(CommGroup&& rhs) noexcept {
    rank_vec_.swap(rhs.rank_vec_);
    global_rank2local_rank_.swap(rhs.global_rank2local_rank_);
    global_rank_count_ = rhs.global_rank_count_;
  }

  void InitGroup(const DeviceSet& device_set, const std::string& unique_name) {
    CudaCurrentDeviceGuard guard;
    const int64_t this_machine_id = Global<MachineCtx>::Get()->this_machine_id();
    global_rank_count_ = device_set.device_size();
    std::vector<int32_t> local_ranks;
    for (int32_t i = 0; i < global_rank_count_; ++i) {
      if (device_set.device(i).machine_id() == this_machine_id) {
        global_rank2local_rank_.emplace(i, local_ranks.size());
        local_ranks.push_back(i);
      }
    }
    const int32_t local_rank_count = local_ranks.size();
    CHECK_GT(local_rank_count, 0);
    ncclUniqueId nccl_unique_id{};
    if (local_ranks.front() == 0) {
      if (local_rank_count != global_rank_count_) {
        Global<CtrlClient>::Get()->PushKV(unique_name, NcclUniqueIdToString(nccl_unique_id));
      }
      OF_NCCL_CHECK(ncclGetUniqueId(&nccl_unique_id));
    } else {
      Global<CtrlClient>::Get()->PullKV(unique_name, [&nccl_unique_id](const std::string& val) {
        NcclUniqueIdFromString(val, &nccl_unique_id);
      });
    }
    rank_vec_.reserve(local_rank_count);
    OF_NCCL_CHECK(ncclGroupStart());
    for (int32_t local_rank = 0; local_rank < local_ranks.size(); ++local_rank) {
      const int32_t global_rank = local_ranks.at(local_rank);
      const int32_t device_id = device_set.device(global_rank).device_id();
      OF_CUDA_CHECK(cudaSetDevice(device_id));
      rank_vec_.emplace_back(device_id, global_rank, global_rank_count_, local_rank,
                             local_rank_count);
      rank_vec_.at(local_rank).InitRank(nccl_unique_id);
    }
    OF_NCCL_CHECK(ncclGroupEnd());
  }

  int32_t global_rank_count() const { return global_rank_count_; }

  int32_t local_rank_count() const { return rank_vec_.size(); }

  const CommRank& GetCommRank(int32_t local_rank) const { return rank_vec_.at(local_rank); }

  int32_t GetLocalRank(int32_t global_rank) const {
    return global_rank2local_rank_.at(global_rank);
  }

 private:
  std::vector<CommRank> rank_vec_;
  int32_t global_rank_count_ = 0;
  HashMap<int32_t, int32_t> global_rank2local_rank_;
};

class StreamCtx {
 public:
  OF_DISALLOW_COPY(StreamCtx);
  StreamCtx(int32_t device_id, size_t fusion_buffer_size)
      : device_id_(device_id), fusion_buffer_size_(fusion_buffer_size) {
    CudaCurrentDeviceGuard guard(device_id_);
    int priority;
    OF_CUDA_CHECK(cudaDeviceGetStreamPriorityRange(nullptr, &priority));
    OF_CUDA_CHECK(cudaStreamCreateWithPriority(&stream_, cudaStreamNonBlocking, priority));
    OF_CUDA_CHECK(cudaMalloc(&fusion_buffer_, fusion_buffer_size_));
  }
  ~StreamCtx() {
    CudaCurrentDeviceGuard guard(device_id_);
    OF_CUDA_CHECK(cudaStreamSynchronize(stream_));
    OF_CUDA_CHECK(cudaStreamDestroy(stream_));
    OF_CUDA_CHECK(cudaFree(fusion_buffer_));
  }

  int32_t device_id() const { return device_id_; }

  cudaStream_t stream() const { return stream_; }

  size_t fusion_buffer_size() const { return fusion_buffer_size_; }

  char* fusion_buffer() const { return fusion_buffer_; }

 private:
  int32_t device_id_;
  cudaStream_t stream_ = nullptr;
  size_t fusion_buffer_size_;
  char* fusion_buffer_ = nullptr;
};

};  // namespace

struct NcclExecutorBackend::Impl {
  Impl() = default;
  ~Impl() {
    request_id2stream_id2comm_group.clear();
    stream_id2device_id2stream_ctx.clear();
    device_set2stream_id2comm_group.clear();
  }
  HashMap<DeviceSet, std::vector<CommGroup>> device_set2stream_id2comm_group;
  std::vector<std::vector<std::unique_ptr<StreamCtx>>> stream_id2device_id2stream_ctx;
  std::vector<std::vector<CommGroup>*> request_id2stream_id2comm_group;

  const CommGroup& GetCommGroup(const std::vector<int32_t>& request_ids, int32_t stream_id) const {
    const auto* stream_id2comm_group = request_id2stream_id2comm_group.at(request_ids.at(0));
    for (int64_t request_id = 0; request_id < request_ids.size(); ++request_id) {
      CHECK_EQ(request_id2stream_id2comm_group.at(request_id), stream_id2comm_group);
    }
    return stream_id2comm_group->at(stream_id);
  }
};

NcclExecutorBackend::NcclExecutorBackend()
    : collective_boxing_conf_(Global<ResourceDesc, ForSession>::Get()->collective_boxing_conf()),
      shutdown_(false) {
  OF_CUDA_CHECK(cudaGetDeviceCount(&num_devices_));
  callback_executor_pool_.reset(new ThreadPool(num_devices_));
  CHECK_GT(collective_boxing_conf_.nccl_num_streams(), 0);
  num_streams_ = collective_boxing_conf_.nccl_num_streams();
  CHECK_GE(collective_boxing_conf_.nccl_fusion_threshold_mb(), 0);
  fusion_threshold_ = collective_boxing_conf_.nccl_fusion_threshold_mb() * 1024 * 1024;
  event_list_poll_thread_ = std::thread([this]() {
    std::list<Event> local_event_list;
    while (true) {
      {
        std::unique_lock<std::mutex> lock(event_list_mutex_);
        if (local_event_list.empty()) {
          event_list_cond_.wait(lock, [this]() { return (!event_list_.empty()) || shutdown_; });
        }
        local_event_list.splice(local_event_list.end(), event_list_);
      }
      if (local_event_list.empty() && shutdown_) { break; }
      for (auto it = local_event_list.begin(); it != local_event_list.end();) {
        OF_CUDA_CHECK(cudaSetDevice(it->device_id));
        cudaError_t err = cudaEventQuery(it->cuda_event);
        if (err == cudaErrorNotReady) {
          ++it;
          continue;
        } else if (err == cudaSuccess) {
          OF_CUDA_CHECK(cudaEventDestroy(it->cuda_event));
          auto callback_ptr =
              std::make_shared<std::function<void(Maybe<void>)>>(std::move(it->callback));
          callback_executor_pool_->AddWork(
              [callback_ptr]() { (*callback_ptr)(Maybe<void>::Ok()); });
          local_event_list.erase(it++);
        } else {
          OF_CUDA_CHECK(err);
          UNIMPLEMENTED();
        }
      }
    }
  });
}

NcclExecutorBackend::~NcclExecutorBackend() {
  {
    std::unique_lock<std::mutex> lock(event_list_mutex_);
    shutdown_ = true;
    event_list_cond_.notify_all();
  }
  event_list_poll_thread_.join();
  callback_executor_pool_.reset();
  impl_.reset();
}

void NcclExecutorBackend::GroupRequests(const std::vector<int32_t>& request_ids,
                                        std::vector<std::vector<int32_t>>* groups) {
  std::vector<int32_t> group;
  int64_t group_size = 0;
  auto IsOpFusionEnabled = [&](const RequestDesc& request) -> bool {
    const OpType op_type = request.op_desc().op_type();
    if (op_type == OpType::kOpTypeAllReduce) {
      return collective_boxing_conf_.nccl_fusion_all_reduce();
    } else if (op_type == OpType::kOpTypeAllGather) {
      return collective_boxing_conf_.nccl_fusion_all_gather();
    } else if (op_type == OpType::kOpTypeReduceScatter) {
      return collective_boxing_conf_.nccl_fusion_reduce_scatter();
    } else if (op_type == OpType::kOpTypeReduce) {
      return collective_boxing_conf_.nccl_fusion_reduce();
    } else if (op_type == OpType::kOpTypeBroadcast) {
      return collective_boxing_conf_.nccl_fusion_broadcast();
    } else if (op_type == OpType::kOpTypeAll2All) {
      return false;
    } else {
      UNIMPLEMENTED();
      return false;
    }
  };
  auto CanFuse = [&](const RequestDesc& lhs, const RequestDesc& rhs) -> bool {
    const bool enable_mixed_fusion = (!collective_boxing_conf_.nccl_fusion_all_reduce_use_buffer())
                                     && collective_boxing_conf_.nccl_enable_mixed_fusion();
    if (lhs.device_set() != rhs.device_set()) { return false; }
    if (!IsOpFusionEnabled(lhs) || !IsOpFusionEnabled(rhs)) { return false; }
    if (lhs.op_desc().op_type() != rhs.op_desc().op_type() && (!enable_mixed_fusion)) {
      return false;
    }
    const OpType op_type = lhs.op_desc().op_type();
    if (op_type == OpType::kOpTypeAllReduce) {
      if (collective_boxing_conf_.nccl_fusion_all_reduce_use_buffer()) {
        CHECK(lhs.op_desc().has_reduce_method());
        CHECK(rhs.op_desc().has_reduce_method());
        return lhs.op_desc().reduce_method() == rhs.op_desc().reduce_method()
               && lhs.op_desc().data_type() == rhs.op_desc().data_type();
      } else {
        return true;
      }
    } else if (op_type == OpType::kOpTypeReduce || op_type == OpType::kOpTypeBroadcast
               || op_type == OpType::kOpTypeReduceScatter || op_type == OpType::kOpTypeAllGather) {
      return true;
    } else if (op_type == OpType::kOpTypeAll2All) {
      return false;
    } else {
      UNIMPLEMENTED();
      return false;
    }
  };

  for (const int32_t request_id : request_ids) {
    const auto& request = request_store_->MutRequestEntry(request_id)->desc();
    const int64_t size = GetAlignedRequestSize(request);
    if (group.empty() || !CanFuse(request_store_->MutRequestEntry(group.back())->desc(), request)
        || group_size + size > fusion_threshold_
        || group.size() >= collective_boxing_conf_.nccl_fusion_max_ops()) {
      if (!group.empty()) {
        groups->emplace_back();
        groups->back().swap(group);
        group_size = 0;
      }
    }
    group.push_back(request_id);
    group_size += size;
  }
  if (!group.empty()) {
    groups->emplace_back();
    groups->back().swap(group);
  }
}

void NcclExecutorBackend::ExecuteRequests(const std::vector<int32_t>& request_ids) {
  std::vector<const RequestDesc*> group;
  std::vector<std::map<int64_t, std::shared_ptr<const RuntimeRequestInfo>>> ranks;
  group.reserve(request_ids.size());
  for (const int32_t request_id : request_ids) {
    auto* request_entry = request_store_->MutRequestEntry(request_id);
    group.push_back(&request_entry->desc());
    ranks.emplace_back();
    for (int32_t local_rank = 0; local_rank < request_entry->LocalRankCount(); ++local_rank) {
      ranks.back()[request_entry->LocalRankToGlobalRank(local_rank)] =
          request_entry->GetRuntimeRequest(local_rank);
    }
    request_entry->ResetRuntimeRequest();
  }
  CHECK_EQ(group.size(), ranks.size());
  if (group.empty()) { return; }

  const int64_t group_size = group.size();
  std::map<int64_t, std::vector<std::shared_ptr<const std::function<void(const Maybe<void>&)>>>>
      device_id2callbacks;
  const int64_t stream_id = current_stream_id_;
  current_stream_id_ = (current_stream_id_ + 1) % num_streams_;
  CudaCurrentDeviceGuard device_guard;
  auto& comm_group = impl_->GetCommGroup(request_ids, stream_id);
  auto& device_id2stream_ctx = impl_->stream_id2device_id2stream_ctx.at(stream_id);
  if (group.front()->op_desc().op_type() == OpType::kOpTypeAllReduce
      && collective_boxing_conf_.nccl_fusion_all_reduce_use_buffer() && group.size() > 1) {
    int64_t offset = 0;
    std::map<int64_t, MultiCopyParams> device_id2copy_in_params;
    std::map<int64_t, MultiCopyParams> device_id2copy_out_params;
    for (int64_t i = 0; i < group.size(); ++i) {
      const RequestDesc* request_desc = group.at(i);
      if (i != 0) {
        CHECK_EQ(request_desc->op_desc().reduce_method(), group.front()->op_desc().reduce_method());
        CHECK_EQ(request_desc->op_desc().data_type(), group.front()->op_desc().data_type());
      }
      const std::map<int64_t, std::shared_ptr<const RuntimeRequestInfo>>& rank2request_info =
          ranks.at(i);
      const int64_t size = GetRequestSize(*request_desc);
      CHECK_LE(offset + size, fusion_threshold_);
      const int64_t aligned_size = GetCudaAlignedSize(size);
      for (const auto& rank7request_info : rank2request_info) {
        const int64_t rank = rank7request_info.first;
        const RuntimeRequestInfo& request_info = *rank7request_info.second;
        const DeviceDesc& device_desc = request_desc->device_set().device().Get(rank);
        const int64_t device_id = device_desc.device_id();
        auto& stream_ctx = device_id2stream_ctx.at(device_id);
        device_id2copy_in_params[device_id].Add(stream_ctx->fusion_buffer() + offset,
                                                request_info.send_buff, size);
        device_id2copy_out_params[device_id].Add(request_info.recv_buff,
                                                 stream_ctx->fusion_buffer() + offset, size);
        device_id2callbacks[device_id].reserve(group_size);
        device_id2callbacks[device_id].push_back(request_info.callback);
      }
      offset += aligned_size;
    }
    for (auto& device_id7copy_in_params : device_id2copy_in_params) {
      OF_CUDA_CHECK(cudaSetDevice(device_id7copy_in_params.first));
      MultiCopy(device_id2stream_ctx.at(device_id7copy_in_params.first)->stream(),
                device_id7copy_in_params.second);
    }
    OF_NCCL_CHECK(ncclGroupStart());
    const int64_t size_of_data_type = GetSizeOfDataType(group.front()->op_desc().data_type());
    CHECK_EQ(offset % size_of_data_type, 0);
    const int64_t elem_cnt = offset / size_of_data_type;
    for (int32_t local_rank = 0; local_rank < comm_group.local_rank_count(); ++local_rank) {
      const CommRank& comm_rank = comm_group.GetCommRank(local_rank);
      OF_CUDA_CHECK(cudaSetDevice(comm_rank.device_id()));
      auto& stream_ctx = device_id2stream_ctx.at(comm_rank.device_id());
      OF_NCCL_CHECK(ncclAllReduce(stream_ctx->fusion_buffer(), stream_ctx->fusion_buffer(),
                                  elem_cnt, GetNcclDataType(group.front()->op_desc().data_type()),
                                  GetNcclReduceOp(group.front()->op_desc().reduce_method()),
                                  comm_rank.nccl_comm(), stream_ctx->stream()));
    }
    OF_NCCL_CHECK(ncclGroupEnd());
    for (auto& device_id7copy_out_params : device_id2copy_out_params) {
      OF_CUDA_CHECK(cudaSetDevice(device_id7copy_out_params.first));
      MultiCopy(device_id2stream_ctx.at(device_id7copy_out_params.first)->stream(),
                device_id7copy_out_params.second);
    }
  } else {
    OF_NCCL_CHECK(ncclGroupStart());

    for (int64_t i = 0; i < group.size(); ++i) {
      const RequestDesc* request_desc = group.at(i);
      const OpDesc& op_desc = request_desc->op_desc();
      const std::map<int64_t, std::shared_ptr<const RuntimeRequestInfo>>& rank2request_info =
          ranks.at(i);
      for (const auto& rank7request_info : rank2request_info) {
        const int64_t rank = rank7request_info.first;
        const RuntimeRequestInfo& request_info = *rank7request_info.second;
        const DeviceDesc& device_desc = request_desc->device_set().device().Get(rank);
        const int64_t device_id = device_desc.device_id();
        OF_CUDA_CHECK(cudaSetDevice(device_id));
        const int32_t local_rank = comm_group.GetLocalRank(rank);
        const CommRank& comm_rank = comm_group.GetCommRank(local_rank);
        ncclComm_t comm = comm_rank.nccl_comm();
        auto& stream_ctx = device_id2stream_ctx.at(device_id);
        ncclDataType_t nccl_data_type = GetNcclDataType(op_desc.data_type());
        const OpType op_type = op_desc.op_type();
        const int64_t num_ranks = op_desc.num_ranks();
        const int64_t elem_cnt = Shape(op_desc.shape()).elem_cnt();
        const void* send_buff = request_info.send_buff;
        void* recv_buff = request_info.recv_buff;
        device_id2callbacks[device_id].reserve(group_size);
        device_id2callbacks[device_id].push_back(request_info.callback);
        if (op_type == OpType::kOpTypeAllReduce) {
          OF_NCCL_CHECK(ncclAllReduce(send_buff, recv_buff, elem_cnt, nccl_data_type,
                                      GetNcclReduceOp(op_desc.reduce_method()), comm,
                                      stream_ctx->stream()));
        } else if (op_type == OpType::kOpTypeAllGather) {
          CHECK_EQ(elem_cnt % num_ranks, 0);
          OF_NCCL_CHECK(ncclAllGather(send_buff, recv_buff, elem_cnt / num_ranks, nccl_data_type,
                                      comm, stream_ctx->stream()));
        } else if (op_type == OpType::kOpTypeReduceScatter) {
          CHECK_EQ(elem_cnt % num_ranks, 0);
          OF_NCCL_CHECK(ncclReduceScatter(send_buff, recv_buff, elem_cnt / num_ranks,
                                          nccl_data_type, GetNcclReduceOp(op_desc.reduce_method()),
                                          comm, stream_ctx->stream()));
        } else if (op_type == OpType::kOpTypeReduce) {
          OF_NCCL_CHECK(ncclReduce(send_buff, recv_buff, elem_cnt, nccl_data_type,
                                   GetNcclReduceOp(op_desc.reduce_method()), op_desc.root(), comm,
                                   stream_ctx->stream()));
        } else if (op_type == OpType::kOpTypeBroadcast) {
          OF_NCCL_CHECK(ncclBroadcast(send_buff, recv_buff, elem_cnt, nccl_data_type,
                                      op_desc.root(), comm, stream_ctx->stream()));
        } else if (op_type == OpType::kOpTypeAll2All) {
#if NCCL_VERSION_CODE > 2700
          const int64_t elem_per_rank = elem_cnt / num_ranks;
          const int64_t elem_per_chunk = elem_per_rank / num_ranks;
          const int64_t dtype_size = GetSizeOfDataType(op_desc.data_type());
          const int64_t chunk_size = elem_per_chunk * dtype_size;
          for (int64_t j = 0; j < num_ranks; ++j) {
            OF_NCCL_CHECK(ncclSend(reinterpret_cast<const void*>(
                                       reinterpret_cast<const char*>(send_buff) + j * chunk_size),
                                   elem_per_chunk, nccl_data_type, j, comm, stream_ctx->stream()));
            OF_NCCL_CHECK(ncclRecv(
                reinterpret_cast<void*>(reinterpret_cast<char*>(recv_buff) + j * chunk_size),
                elem_per_chunk, nccl_data_type, j, comm, stream_ctx->stream()));
          }
#else
          UNIMPLEMENTED();
#endif
        } else {
          UNIMPLEMENTED();
        }
      }
    }
    OF_NCCL_CHECK(ncclGroupEnd());
  }
  for (auto& device_id7callbacks : device_id2callbacks) {
    const int64_t device_id = device_id7callbacks.first;
    OF_CUDA_CHECK(cudaSetDevice(device_id));
    cudaEvent_t event;
    OF_CUDA_CHECK(cudaEventCreateWithFlags(&event, cudaEventDisableTiming));
    OF_CUDA_CHECK(cudaEventRecord(event, device_id2stream_ctx.at(device_id)->stream()));
    {
      std::unique_lock<std::mutex> event_list_lock(event_list_mutex_);
      event_list_.emplace_back(Event{device_id, event, [=](const Maybe<void>& status) {
                                       for (const auto& callback : device_id7callbacks.second) {
                                         (*callback)(status);
                                       }
                                     }});
      event_list_cond_.notify_all();
    }
  }
}

void NcclExecutorBackend::Init(const CollectiveBoxingPlan& collective_boxing_plan,
                               std::shared_ptr<RequestStore> request_store) {
  request_store_ = request_store;
  impl_ = std::make_unique<Impl>();
  CudaCurrentDeviceGuard guard;
  std::set<int64_t> local_device_ids;
  for (int32_t request_id = 0; request_id < request_store_->RequestCount(); ++request_id) {
    auto* request_entry = request_store_->MutRequestEntry(request_id);
    const auto& request = request_entry->desc();
    if (request.op_desc().backend() != Backend::kBackendNCCL) { continue; }
    if (!request_entry->HasRankOnThisNode()) { continue; }
    const DeviceSet& device_set = request.device_set();
    if (impl_->device_set2stream_id2comm_group.count(device_set) > 0) { continue; }
    auto& stream_id2comm_group = impl_->device_set2stream_id2comm_group[device_set];
    stream_id2comm_group.resize(num_streams_);
    for (int32_t stream_id = 0; stream_id < num_streams_; ++stream_id) {
      stream_id2comm_group.at(stream_id).InitGroup(
          device_set, GetNcclUniqueIdRpcKey(request.op_desc().name(), stream_id));
    }
    for (int32_t i = 0; i < stream_id2comm_group.at(0).local_rank_count(); ++i) {
      local_device_ids.emplace(stream_id2comm_group.at(0).GetCommRank(i).device_id());
    }
  }
  impl_->request_id2stream_id2comm_group.resize(request_store_->RequestCount());
  for (int32_t request_id = 0; request_id < request_store_->RequestCount(); ++request_id) {
    const DeviceSet& device_set = request_store_->MutRequestEntry(request_id)->desc().device_set();
    auto it = impl_->device_set2stream_id2comm_group.find(device_set);
    if (it != impl_->device_set2stream_id2comm_group.end()) {
      impl_->request_id2stream_id2comm_group.at(request_id) = &it->second;
    } else {
      impl_->request_id2stream_id2comm_group.at(request_id) = nullptr;
    }
  }
  impl_->stream_id2device_id2stream_ctx.resize(num_streams_);
  for (int64_t stream_id = 0; stream_id < num_streams_; ++stream_id) {
    impl_->stream_id2device_id2stream_ctx.at(stream_id).resize(num_devices_);
    for (const int64_t device_id : local_device_ids) {
      impl_->stream_id2device_id2stream_ctx.at(stream_id).at(device_id) =
          std::make_unique<StreamCtx>(device_id, fusion_threshold_);
    }
  }
}

}  // namespace collective

}  // namespace boxing

}  // namespace oneflow