// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "complex_mul.h"
#include "complex_mul_impl.h"
#include "core/providers/cuda/cu_inc/common.cuh"
#include "core/providers/cuda/math/binary_elementwise_ops.h"

namespace onnxruntime {
namespace contrib {
namespace cuda {
template <typename T>
__device__ __inline__ void _ComplexMul(T a0, T a1, T b0, T b1, T* output_data) {
  T out_real = a0 * b0 - a1 * b1;
  T out_imag = a0 * b1 + a1 * b0;
  output_data[0] = out_real;
  output_data[1] = out_imag;
};

// broadcast by computing output coordinate from offset, using fast_divmod
template <typename T, bool lhs_need_compute, bool rhs_need_compute, int NumThreadsPerBlock, int NumElementsPerThread>
__global__ void _ElementWiseWithStrideTwo(
    int32_t output_rank,
    const TArray<int64_t> lhs_padded_strides,
    const T* lhs_data,
    const TArray<int64_t> rhs_padded_strides,
    const T* rhs_data,
    const TArray<fast_divmod> fdm_output_strides,
    T* output_data,
    CUDA_LONG N) {
  CUDA_LONG start = NumElementsPerThread * NumThreadsPerBlock * blockIdx.x + threadIdx.x;
  T a[NumElementsPerThread];
  T b[NumElementsPerThread];
  T c[NumElementsPerThread];
  T d[NumElementsPerThread];

  CUDA_LONG id = start;
#pragma unroll
  for (int i = 0; i < NumElementsPerThread; i++) {
    if (id < N / 2) {
      CUDA_LONG lhs_index = (lhs_need_compute ? 0 : id);
      CUDA_LONG rhs_index = (rhs_need_compute ? 0 : id);
      // compute indexes with broadcasting rules: https://github.com/onnx/onnx/blob/master/docs/Broadcasting.md
      CUDA_LONG offset = id;
#pragma unroll
      for (auto dim = 0; dim < fdm_output_strides.GetCapacity(); dim++) {
        if (dim >= output_rank) {
          break;
        }
        int q, r;
        fdm_output_strides.data_[dim].divmod(offset, q, r);
        if (lhs_need_compute) {
          lhs_index += static_cast<int>(lhs_padded_strides.data_[dim]) * q;
        }

        if (rhs_need_compute) {
          rhs_index += static_cast<int>(rhs_padded_strides.data_[dim]) * q;
        }
        offset = r;
      }
      a[i] = lhs_data[2 * lhs_index];
      b[i] = lhs_data[2 * lhs_index + 1];
      c[i] = rhs_data[2 * rhs_index];
      d[i] = rhs_data[2 * rhs_index + 1];

      id += NumThreadsPerBlock;
    }
  }

  id = start;
#pragma unroll
  for (int i = 0; i < NumElementsPerThread; i++) {
    if (id < N / 2) {
      _ComplexMul(a[i], b[i], c[i], d[i], &output_data[2 * id]);
      id += NumThreadsPerBlock;
    }
  }
};

template <typename T>
void StackedComplexMul_Impl(
    int32_t output_rank_or_simple_broadcast,
    const TArray<int64_t>* lhs_padded_strides,
    const T* lhs_data,
    const TArray<int64_t>* rhs_padded_strides,
    const T* rhs_data,
    const TArray<onnxruntime::cuda::fast_divmod>* fdm_output_strides,
    const onnxruntime::cuda::fast_divmod& fdm_H,
    const onnxruntime::cuda::fast_divmod& fdm_C,
    T* output_data,
    int64_t count) {
  if (count == 0)  // special case where there's a dim value of 0 in the output shape
    return;

  int blocksPerGrid = static_cast<int>(CeilDiv(count, GridDim::maxThreadsPerBlock * GridDim::maxElementsPerThread));
  CUDA_LONG N = static_cast<CUDA_LONG>(count);

  if (lhs_padded_strides && rhs_padded_strides && lhs_padded_strides->size_ && rhs_padded_strides->size_)
    _ElementWiseWithStrideTwo<T, true, true, GridDim::maxThreadsPerBlock, GridDim::maxElementsPerThread><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
        output_rank_or_simple_broadcast,
        *lhs_padded_strides,
        lhs_data,
        *rhs_padded_strides,
        rhs_data,
        *fdm_output_strides,
        output_data,
        N);
  else if (lhs_padded_strides && lhs_padded_strides->size_)
    _ElementWiseWithStrideTwo<T, true, false, GridDim::maxThreadsPerBlock, GridDim::maxElementsPerThread><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
        output_rank_or_simple_broadcast,
        *lhs_padded_strides,
        lhs_data,
        *rhs_padded_strides,
        rhs_data,
        *fdm_output_strides,
        output_data,
        N);
  else
    _ElementWiseWithStrideTwo<T, false, true, GridDim::maxThreadsPerBlock, GridDim::maxElementsPerThread><<<blocksPerGrid, GridDim::maxThreadsPerBlock, 0>>>(
        output_rank_or_simple_broadcast,
        *lhs_padded_strides,
        lhs_data,
        *rhs_padded_strides,
        rhs_data,
        *fdm_output_strides,
        output_data,
        N);
};

#define SPECIALIZE_STACKEDCOMPLEXMUL_IMPL(T)                            \
  template void StackedComplexMul_Impl<T>(                              \
      int32_t output_rank_or_simple_broadcast,                          \
      const TArray<int64_t>* lhs_padded_strides,                        \
      const T* lhs_data,                                                \
      const TArray<int64_t>* rhs_padded_strides,                        \
      const T* rhs_data,                                                \
      const TArray<onnxruntime::cuda::fast_divmod>* fdm_output_strides, \
      const onnxruntime::cuda::fast_divmod& fdm_H,                      \
      const onnxruntime::cuda::fast_divmod& fdm_C,                      \
      T* output_data,                                                   \
      int64_t count);

SPECIALIZE_STACKEDCOMPLEXMUL_IMPL(float)
SPECIALIZE_STACKEDCOMPLEXMUL_IMPL(double)
SPECIALIZE_STACKEDCOMPLEXMUL_IMPL(half)

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime
