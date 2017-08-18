#ifndef ONEFLOW_CORE_OPERATOR_INNERPRODUCT_OP_H_
#define ONEFLOW_CORE_OPERATOR_INNERPRODUCT_OP_H_

#include "oneflow/core/operator/operator_manager.h"

namespace oneflow {

class InnerProductOp final : public UserOperator {
 public:
  OF_DISALLOW_COPY_AND_MOVE(InnerProductOp);
  InnerProductOp() = default;
  ~InnerProductOp() = default;

  void InitFromOpConf(const OperatorConf& op_conf) override;
  const PbMessage& GetSpecialConf() const override;
  void InferBlobDesc4FwBlobs(
      std::function<BlobDesc*(const std::string)> GetBlobDesc4BnInOp,
      ParallelPolicy policy, int64_t parallel_id,
      int64_t parallel_num) const override;
  void FixParallelDesc(ParallelDesc* pr_desc) const override {
    if (pr_desc->policy() == kModelParallel) {
      pr_desc->RemoveNeedlessDevice(GetInt32FromSpecialConf("out_num"));
    }
  }
};

}  // namespace oneflow

#endif  // ONEFLOW_CORE_OPERATOR_INNERPRODUCT_OP_H_
