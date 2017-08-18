#include "oneflow/core/register/register_manager.h"
#include "oneflow/core/job/id_manager.h"
#include "oneflow/core/job/job_desc.h"
#include "oneflow/core/register/blob.h"

namespace oneflow {

void RegstMgr::NewRegsts(const RegstDescProto& regst_desc_proto,
                         std::function<void(Regst*)> OneRegstDone) {
  const RtRegstDesc* runtime_regst_desc = new RtRegstDesc(regst_desc_proto);
  rt_regst_descs_.emplace_back(runtime_regst_desc);
  for (int64_t i = 0; i < regst_desc_proto.register_num(); ++i) {
    Regst* regst = new Regst;
    regst->regst_desc_ = runtime_regst_desc;

    size_t elem_size = sizeof(float);
    if (JobDesc::Singleton()->floating_point_type() == kDouble) {
      elem_size = sizeof(double);
    }
    int64_t elem_cnt = 0;
    std::vector<std::string> lbns;
    lbns.reserve(regst_desc_proto.lbn2blob_desc().size());
    for (const auto& pair : regst_desc_proto.lbn2blob_desc()) {
      const Shape& shape_ptr =
          runtime_regst_desc->GetBlobDescFromLbn(pair.first)->shape();
      lbns.push_back(pair.first);
      elem_cnt += shape_ptr.elem_cnt();
    }
    std::sort(lbns.begin(), lbns.end());
    std::pair<char*, std::function<void()>> allocation =
        MemoryAllocator::Singleton()->Allocate(regst_desc_proto.mem_case(),
                                               elem_cnt * elem_size);

    int64_t blob_idx = 0;
    for (const std::string& lbn : lbns) {
      const Shape* shape_ptr =
          &(runtime_regst_desc->GetBlobDescFromLbn(lbn)->shape());
      auto blob_ptr =
          of_make_unique<Blob>(allocation.first + blob_idx, shape_ptr);
      CHECK(regst->lbn2blob_.emplace(lbn, std::move(blob_ptr)).second);
      blob_idx += shape_ptr->elem_cnt() * elem_size;
    }
    Shape* packed_blob_shape = new Shape({elem_cnt});
    regst->packed_blob_.reset(new Blob(allocation.first, packed_blob_shape));
    regst->deleter_ = [allocation, packed_blob_shape]() {
      allocation.second();
      delete packed_blob_shape;
    };
    OneRegstDone(regst);
  }
}

}  // namespace oneflow
