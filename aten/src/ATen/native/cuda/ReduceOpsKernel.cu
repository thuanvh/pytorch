#include <ATen/native/SharedReduceOps.h>
#include <ATen/AccumulateType.h>
#include <ATen/Context.h>
#include <ATen/Dispatch.h>
#include <ATen/native/cuda/DeviceSqrt.cuh>
#include <ATen/native/cuda/Loops.cuh>
#include <ATen/native/cuda/Reduce.cuh>
#include <ATen/native/DispatchStub.h>
#include <ATen/native/TensorIterator.h>
#include <ATen/native/ReduceOps.h>
#include <limits>
#include <tuple>


namespace at { namespace native {

namespace {

template <typename scalar_t>
struct SimpleCopy {
  __device__ __forceinline__ scalar_t operator() (const scalar_t a) const {
    return a;
  }
};

} // namespace

template <typename scalar_t, typename acc_t=scalar_t, typename out_t=scalar_t>
void sum_kernel_impl(TensorIterator& iter) {
  gpu_reduce_kernel<scalar_t, out_t>(iter, func_wrapper<out_t> ([]GPU_LAMBDA(acc_t a, acc_t b) -> acc_t {
    return a + b;
  }));
}

template <typename scalar_t>
void std_kernel_impl(TensorIterator& iter, bool unbiased) {
  gpu_reduce_kernel<scalar_t, scalar_t>(iter, WelfordOps<scalar_t, scalar_t> { unbiased }, WelfordData<scalar_t> {});
}

template <>
void std_kernel_impl<at::Half>(TensorIterator& iter, bool unbiased) {
  gpu_reduce_kernel<at::Half, at::Half>(iter, WelfordOps<at::Half, float> { unbiased }, WelfordData<float> {});
}

#ifdef __HIPCC__
template <>
void sum_kernel_impl<int16_t, int16_t>(TensorIterator& iter) {
  // There is a Register Coalescing bug in LLVM causing the hcc
  // compiler segfaults:
  // https://bugs.llvm.org/show_bug.cgi?id=39602
  // To work around it, use int32 as the accumulate type.
  gpu_reduce_kernel<int16_t, int16_t>(iter, func_wrapper<int16_t> ([]GPU_LAMBDA(int32_t a, int32_t b) -> int32_t {
    return a + b;
  }));
}
#endif

template <typename scalar_t, typename acc_t=scalar_t>
void prod_kernel_impl(TensorIterator& iter) {
  gpu_reduce_kernel<scalar_t, scalar_t>(iter, func_wrapper<scalar_t> ([]GPU_LAMBDA(acc_t a, acc_t b) -> acc_t {
    return a * b;
  }), 1);
}

static void std_kernel_cuda(TensorIterator& iter, bool unbiased) {
  AT_DISPATCH_FLOATING_TYPES_AND_HALF(iter.type(), "std", [&]() {
    std_kernel_impl<scalar_t>(iter, unbiased);
  });
}

template <typename scalar_t, typename acc_t=scalar_t, typename out_t=scalar_t>
void mean_kernel_impl(TensorIterator& iter) {
  float factor = float(iter.num_output_elements()) / iter.numel();
  gpu_reduce_kernel<scalar_t, out_t>(iter, MeanOps<acc_t, float> {factor});
}

#ifdef __HIPCC__
template <>
void mean_kernel_impl<int16_t, int16_t, int16_t>(TensorIterator& iter) {
  // There is a Register Coalescing bug in LLVM causing the hcc
  // compiler segfaults:
  // https://bugs.llvm.org/show_bug.cgi?id=39602
  // To work around it, use int32 as the accumulate type.
  float factor = float(iter.num_output_elements()) / iter.numel();
  gpu_reduce_kernel<int16_t, int16_t>(iter, MeanOps<int32_t, float> {factor});
}
#endif // __HIPCC__

static void sum_kernel_cuda(TensorIterator& iter) {
  if (iter.type().scalarType() == kHalf) {
    return sum_kernel_impl<at::Half, float>(iter);
  } else if (iter.type(1).scalarType() == kHalf && iter.type().scalarType() == kFloat) {
    // type promotion that does cast and reduction in a single kernel
    return sum_kernel_impl<at::Half, float, float>(iter);
  }
  AT_DISPATCH_ALL_TYPES(iter.type(), "sum", [&]() {
    sum_kernel_impl<scalar_t>(iter);
  });
}

static void prod_kernel_cuda(TensorIterator& iter) {
  if (iter.type().scalarType() == kHalf) {
    return prod_kernel_impl<at::Half, float>(iter);
  }
  AT_DISPATCH_ALL_TYPES(iter.type(), "prod", [&]() {
    prod_kernel_impl<scalar_t>(iter);
  });
}

static void mean_kernel_cuda(TensorIterator& iter) {
  if (iter.type().scalarType() == kHalf) {
    return mean_kernel_impl<at::Half, float>(iter);
  } else if (iter.type(1).scalarType() == kHalf && iter.type().scalarType() == kFloat) {
    // type promotion that does cast and reduction in a single kernel
    return mean_kernel_impl<at::Half, float, float>(iter);
  }
  AT_DISPATCH_ALL_TYPES(iter.type(), "mean", [&]() {
    mean_kernel_impl<scalar_t>(iter);
  });
}

REGISTER_DISPATCH(std_stub, &std_kernel_cuda);
REGISTER_DISPATCH(sum_stub, &sum_kernel_cuda);
REGISTER_DISPATCH(prod_stub, &prod_kernel_cuda);
REGISTER_DISPATCH(mean_stub, &mean_kernel_cuda);

}} // namespace at::native
