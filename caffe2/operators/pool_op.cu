// TODO(ataei): reduce the apparent redundancy of all the code below.
#include "caffe2/operators/pool_op.h"

#include <cfloat>
#include <functional>
#include <numeric>

#include "caffe2/core/context_gpu.h"

namespace caffe2 {

namespace {

struct AveragePool {
  explicit AveragePool(const OperatorBase& /* op */) {}
};

struct MaxPool {
  explicit MaxPool(const OperatorBase& /* op */) {}
};

template <typename T>
__global__ void AveragePool1DForwardNCHWCUDAKernel(
    const int K,
    const int X_size,
    const int Y_size,
    const int kernel,
    const int stride,
    const int pad,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int nc = blockIdx.x / K;
  const int block = blockIdx.x % K;
  const T* X_ptr = X + nc * X_size;
  T* Y_ptr = Y + nc * Y_size;
  const int y = threadIdx.x + block * CAFFE_CUDA_NUM_THREADS;
  if (y < Y_size) {
    const int x = y * stride;
    const int l = max(x - pad, 0);
    const int r = min(x - pad + kernel, X_size);
    const T scale = T(1) / static_cast<T>(count_include_pad ? kernel : r - l);
    T sum = 0;
    for (int i = l; i < r; ++i) {
      sum += X_ptr[i];
    }
    Y_ptr[y] = sum * scale;
  }
}

template <typename T>
__global__ void AveragePool1DForwardNHWCCUDAKernel(
    const int C,
    const int X_size,
    const int Y_size,
    const int kernel,
    const int stride,
    const int pad,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int n = blockIdx.x / Y_size;
  const int y = blockIdx.x % Y_size;
  const int x = y * stride;
  const int l = max(x - pad, 0);
  const int r = min(x - pad + kernel, X_size);
  const T scale = T(1) / static_cast<T>(count_include_pad ? kernel : r - l);
  const T* X_ptr = X + n * X_size * C;
  T* Y_ptr = Y + n * Y_size * C;
  for (int c = threadIdx.x; c < C; c += blockDim.x) {
    T sum = 0;
    for (int i = l; i < r; ++i) {
      sum += X_ptr[i * C + c];
    }
    Y_ptr[y * C + c] = sum * scale;
  }
}

template <typename T>
__global__ void AveragePool2DForwardNCHWCUDAKernel(
    const int K,
    const int X_H,
    const int X_W,
    const int Y_H,
    const int Y_W,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int X_HxW = X_H * X_W;
  const int Y_HxW = Y_H * Y_W;
  const int nc = blockIdx.x / K;
  const int block = blockIdx.x % K;
  const T* X_ptr = X + nc * X_HxW;
  T* Y_ptr = Y + nc * Y_HxW;
  const int y = threadIdx.x + block * CAFFE_CUDA_NUM_THREADS;
  if (y < Y_HxW) {
    const int yh = y / Y_W;
    const int yw = y % Y_W;
    const int xh = yh * stride_h;
    const int xw = yw * stride_w;
    const int t = max(xh - pad_t, 0);
    const int b = min(xh - pad_t + kernel_h, X_H);
    const int l = max(xw - pad_l, 0);
    const int r = min(xw - pad_l + kernel_w, X_W);
    const T scale = T(1) /
        static_cast<T>(count_include_pad ? kernel_h * kernel_w
                                         : (b - t) * (r - l));
    T sum = 0;
    for (int i = t; i < b; ++i) {
      for (int j = l; j < r; ++j) {
        sum += X_ptr[i * X_W + j];
      }
    }
    Y_ptr[y] = sum * scale;
  }
}

template <typename T>
__global__ void AveragePool2DForwardNHWCCUDAKernel(
    const int C,
    const int X_H,
    const int X_W,
    const int Y_H,
    const int Y_W,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int X_HxW = X_H * X_W;
  const int Y_HxW = Y_H * Y_W;
  const int n = blockIdx.x / Y_HxW;
  const int y = blockIdx.x % Y_HxW;
  const int yh = y / Y_W;
  const int yw = y % Y_W;
  const int xh = yh * stride_h;
  const int xw = yw * stride_w;
  const int t = max(xh - pad_t, 0);
  const int b = min(xh - pad_t + kernel_h, X_H);
  const int l = max(xw - pad_l, 0);
  const int r = min(xw - pad_l + kernel_w, X_W);
  const T scale = T(1) /
      static_cast<T>(count_include_pad ? kernel_h * kernel_w
                                       : (b - t) * (r - l));
  const T* X_ptr = X + n * X_HxW * C;
  T* Y_ptr = Y + n * Y_HxW * C;
  for (int c = threadIdx.x; c < C; c += blockDim.x) {
    T sum = 0;
    for (int i = t; i < b; ++i) {
      for (int j = l; j < r; ++j) {
        sum += X_ptr[(i * X_W + j) * C + c];
      }
    }
    Y_ptr[y * C + c] = sum * scale;
  }
}

template <typename T>
__global__ void AveragePool3DForwardNCHWCUDAKernel(
    const int K,
    const int X_D,
    const int X_H,
    const int X_W,
    const int Y_D,
    const int Y_H,
    const int Y_W,
    const int kernel_d,
    const int kernel_h,
    const int kernel_w,
    const int stride_d,
    const int stride_h,
    const int stride_w,
    const int pad_p,
    const int pad_t,
    const int pad_l,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int X_HxW = X_D * X_H * X_W;
  const int Y_HxW = Y_D * Y_H * Y_W;
  const int nc = blockIdx.x / K;
  const int block = blockIdx.x % K;
  const T* X_ptr = X + nc * X_HxW;
  T* Y_ptr = Y + nc * Y_HxW;
  const int y = threadIdx.x + block * CAFFE_CUDA_NUM_THREADS;
  if (y < Y_HxW) {
    const int yy = y / Y_W;
    const int yw = y % Y_W;
    const int yh = yy % Y_H;
    const int yd = yy / Y_H;
    const int xd = yd * stride_d;
    const int xh = yh * stride_h;
    const int xw = yw * stride_w;
    const int p = max(xd - pad_p, 0);
    const int a = min(xd - pad_p + kernel_d, X_D);
    const int t = max(xh - pad_t, 0);
    const int b = min(xh - pad_t + kernel_h, X_H);
    const int l = max(xw - pad_l, 0);
    const int r = min(xw - pad_l + kernel_w, X_W);
    const T scale = T(1) /
        static_cast<T>(count_include_pad ? kernel_d * kernel_h * kernel_w
                                         : (a - p) * (b - t) * (r - l));
    T sum = 0;
    for (int i = p; i < a; ++i) {
      for (int j = t; j < b; ++j) {
        for (int k = l; k < r; ++k) {
          sum += X_ptr[(i * X_H + j) * X_W + k];
        }
      }
    }
    Y_ptr[y] = sum * scale;
  }
}

template <typename T>
__global__ void AveragePool3DForwardNHWCCUDAKernel(
    const int C,
    const int X_D,
    const int X_H,
    const int X_W,
    const int Y_D,
    const int Y_H,
    const int Y_W,
    const int kernel_d,
    const int kernel_h,
    const int kernel_w,
    const int stride_d,
    const int stride_h,
    const int stride_w,
    const int pad_p,
    const int pad_t,
    const int pad_l,
    const bool count_include_pad,
    const T* X,
    T* Y) {
  const int X_HxW = X_D * X_H * X_W;
  const int Y_HxW = Y_D * Y_H * Y_W;
  const int n = blockIdx.x / Y_HxW;
  const int y = blockIdx.x % Y_HxW;
  const int yy = y / Y_W;
  const int yw = y % Y_W;
  const int yh = yy % Y_H;
  const int yd = yy / Y_H;
  const int xd = yd * stride_d;
  const int xh = yh * stride_h;
  const int xw = yw * stride_w;
  const int p = max(xd - pad_p, 0);
  const int a = min(xd - pad_p + kernel_d, X_D);
  const int t = max(xh - pad_t, 0);
  const int b = min(xh - pad_t + kernel_h, X_H);
  const int l = max(xw - pad_l, 0);
  const int r = min(xw - pad_l + kernel_w, X_W);
  const T scale = T(1) /
      static_cast<T>(count_include_pad ? kernel_d * kernel_h * kernel_w
                                       : (a - p) * (b - t) * (r - l));
  const T* X_ptr = X + n * X_HxW * C;
  T* Y_ptr = Y + n * Y_HxW * C;
  for (int c = threadIdx.x; c < C; c += blockDim.x) {
    T sum = 0;
    for (int i = p; i < a; ++i) {
      for (int j = t; j < b; ++j) {
        for (int k = l; k < r; ++k) {
          sum += X_ptr[((i * X_H + j) * X_W + k) * C + c];
        }
      }
    }
    Y_ptr[y * C + c] = sum * scale;
  }
}

template <typename T>
__global__ void Ave1DPoolBackwardNCHW(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int h = index % height + pad_t;
    const int c = (index / height) % channels;
    const int n = index / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    T gradient = 0;
    const T* const top_diff_slice =
        top_diff + (n * channels + c) * pooled_height;
    for (int ph = phstart; ph < phend; ++ph) {
      // figure out the pooling size
      int hstart = ph * stride_h - pad_t;
      int hend = min(hstart + kernel_h, height);
      hstart = max(hstart, 0);
      int pool_size = (hend - hstart);
      gradient += top_diff_slice[ph] / pool_size;
    }
    bottom_diff[index] = gradient;
  }
}

template <typename T>
__global__ void Ave2DPoolBackwardNCHW(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int width,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int w = index % width + pad_l;
    const int h = (index / width) % height + pad_t;
    const int c = (index / width / height) % channels;
    const int n = index / width / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    T gradient = 0;
    const T* const top_diff_slice =
        top_diff + (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        // figure out the pooling size
        int hstart = ph * stride_h - pad_t;
        int wstart = pw * stride_w - pad_l;
        int hend = min(hstart + kernel_h, height);
        int wend = min(wstart + kernel_w, width);
        hstart = max(hstart, 0);
        wstart = max(wstart, 0);
        int pool_size = (hend - hstart) * (wend - wstart);
        gradient += top_diff_slice[ph * pooled_width + pw] / pool_size;
      }
    }
    bottom_diff[index] = gradient;
  }
}

template <typename T>
__global__ void Ave3DPoolBackwardNCHW(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int width,
    const int depth,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int d = index % depth + pad_f;
    const int w = (index / depth) % width + pad_l;
    const int h = (index / depth / width) % height + pad_t;
    const int c = (index / depth / width / height) % channels;
    const int n = index / depth / width / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int pdstart = (d < kernel_d) ? 0 : (d - kernel_d) / stride_d + 1;
    const int pdend = min(d / stride_d + 1, pooled_depth);
    T gradient = 0;
    const T* const top_diff_slice = top_diff +
        (n * channels + c) * pooled_height * pooled_width * pooled_depth;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        for (int pd = pdstart; pd < pdend; ++pd) {
          // figure out the pooling size
          int hstart = ph * stride_h - pad_t;
          int wstart = pw * stride_w - pad_l;
          int dstart = pd * stride_d - pad_f;
          int hend = min(hstart + kernel_h, height);
          int wend = min(wstart + kernel_w, width);
          int dend = min(dstart + kernel_d, depth);
          hstart = max(hstart, 0);
          wstart = max(wstart, 0);
          dstart = max(dstart, 0);
          int pool_size = (hend - hstart) * (wend - wstart) * (dend - dstart);
          const int pooled_index =
              ph * pooled_depth * pooled_width + pooled_depth * pw + pd;
          gradient += top_diff_slice[pooled_index] / pool_size;
        }
      }
    }
    bottom_diff[index] = gradient;
  }
}

template <typename T>
__global__ void Ave1DPoolBackwardNHWC(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int height,
    const int channels,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int h = (index / channels) % height + pad_t;
    const int n = index / channels / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    T gradient = 0;
    const T* const top_diff_slice = top_diff + n * pooled_height * channels + c;
    for (int ph = phstart; ph < phend; ++ph) {
      // figure out the pooling size
      int hstart = ph * stride_h - pad_t;
      int hend = min(hstart + kernel_h, height);
      hstart = max(hstart, 0);
      int pool_size = (hend - hstart);
      gradient += top_diff_slice[ph * channels] / pool_size;
    }
    bottom_diff[index] = gradient;
  }
}

template <typename T>
__global__ void Ave2DPoolBackwardNHWC(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int height,
    const int width,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int w = index / channels % width + pad_l;
    const int h = (index / channels / width) % height + pad_t;
    const int n = index / channels / width / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    T gradient = 0;
    const T* const top_diff_slice =
        top_diff + n * pooled_height * pooled_width * channels + c;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        // figure out the pooling size
        int hstart = ph * stride_h - pad_t;
        int wstart = pw * stride_w - pad_l;
        int hend = min(hstart + kernel_h, height);
        int wend = min(wstart + kernel_w, width);
        hstart = max(hstart, 0);
        wstart = max(wstart, 0);
        int pool_size = (hend - hstart) * (wend - wstart);
        gradient +=
            top_diff_slice[(ph * pooled_width + pw) * channels] / pool_size;
      }
    }
    bottom_diff[index] = gradient;
  }
}

template <typename T>
__global__ void Ave3DPoolBackwardNHWC(
    const int nthreads,
    const T* const top_diff,
    const int num,
    const int height,
    const int width,
    const int depth,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int d = index / channels % depth + pad_f;
    const int w = (index / channels / depth) % width + pad_l;
    const int h = (index / channels / depth / width) % height + pad_t;
    const int n = index / channels / depth / width / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int pdstart = (d < kernel_d) ? 0 : (d - kernel_d) / stride_d + 1;
    const int pdend = min(d / stride_d + 1, pooled_depth);
    T gradient = 0;
    const T* const top_diff_slice = top_diff +
        n * pooled_height * pooled_width * pooled_depth * channels + c;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        for (int pd = pdstart; pd < pdend; ++pd) {
          // figure out the pooling size
          int hstart = ph * stride_h - pad_t;
          int wstart = pw * stride_w - pad_l;
          int dstart = pd * stride_d - pad_f;
          int hend = min(hstart + kernel_h, height);
          int wend = min(wstart + kernel_w, width);
          int dend = min(dstart + kernel_d, depth);
          hstart = max(hstart, 0);
          wstart = max(wstart, 0);
          dstart = max(dstart, 0);
          int pool_size = (hend - hstart) * (wend - wstart) * (dend - dstart);
          const int pooled_index =
              (ph * pooled_depth * pooled_width + pw * pooled_depth + pd) *
              channels;
          gradient += top_diff_slice[pooled_index] / pool_size;
        }
      }
    }
    bottom_diff[index] = gradient;
  }
}

} // namespace

template <>
template <>
bool AveragePoolFunctor<CUDAContext>::Forward<float, StorageOrder::NCHW>(
    const int N,
    const int C,
    const std::vector<int>& X_dims,
    const std::vector<int>& Y_dims,
    const std::vector<int>& kernel,
    const std::vector<int>& /* dilation */,
    const std::vector<int>& stride,
    const std::vector<int>& pads,
    const float* X,
    float* Y,
    CUDAContext* context) const {
  const int ndim = X_dims.size();
  const int Y_HxW = std::accumulate(
      Y_dims.cbegin(), Y_dims.cend(), 1, std::multiplies<int>());
  const int K = (Y_HxW + CAFFE_CUDA_NUM_THREADS - 1) / CAFFE_CUDA_NUM_THREADS;
  switch (ndim) {
    case 1: {
      AveragePool1DForwardNCHWCUDAKernel<float>
          <<<N * C * K, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              K,
              X_dims[0],
              Y_dims[0],
              kernel[0],
              stride[0],
              pads[0],
              count_include_pad,
              X,
              Y);
      return true;
    }
    case 2: {
      AveragePool2DForwardNCHWCUDAKernel<float>
          <<<N * C * K, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              K,
              X_dims[0],
              X_dims[1],
              Y_dims[0],
              Y_dims[1],
              kernel[0],
              kernel[1],
              stride[0],
              stride[1],
              pads[0],
              pads[1],
              count_include_pad,
              X,
              Y);
      return true;
    }
    case 3: {
      AveragePool3DForwardNCHWCUDAKernel<float>
          <<<N * C * K, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              K,
              X_dims[0],
              X_dims[1],
              X_dims[2],
              Y_dims[0],
              Y_dims[1],
              Y_dims[2],
              kernel[0],
              kernel[1],
              kernel[2],
              stride[0],
              stride[1],
              stride[2],
              pads[0],
              pads[1],
              pads[2],
              count_include_pad,
              X,
              Y);
      return true;
    }
    default: {
      CAFFE_THROW("Unsupported pooling dim: ", ndim);
      return false;
    }
  }
}

template <>
template <>
bool AveragePoolFunctor<CUDAContext>::Forward<float, StorageOrder::NHWC>(
    const int N,
    const int C,
    const std::vector<int>& X_dims,
    const std::vector<int>& Y_dims,
    const std::vector<int>& kernel,
    const std::vector<int>& /* dilation */,
    const std::vector<int>& stride,
    const std::vector<int>& pads,
    const float* X,
    float* Y,
    CUDAContext* context) const {
  const int ndim = X_dims.size();
  const int Y_HxW = std::accumulate(
      Y_dims.cbegin(), Y_dims.cend(), 1, std::multiplies<int>());
  switch (ndim) {
    case 1: {
      AveragePool1DForwardNHWCCUDAKernel<float>
          <<<N * Y_HxW, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              C,
              X_dims[0],
              Y_dims[0],
              kernel[0],
              stride[0],
              pads[0],
              count_include_pad,
              X,
              Y);
      return true;
    }
    case 2: {
      AveragePool2DForwardNHWCCUDAKernel<float>
          <<<N * Y_HxW, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              C,
              X_dims[0],
              X_dims[1],
              Y_dims[0],
              Y_dims[1],
              kernel[0],
              kernel[1],
              stride[0],
              stride[1],
              pads[0],
              pads[1],
              count_include_pad,
              X,
              Y);
      return true;
    }
    case 3: {
      AveragePool3DForwardNHWCCUDAKernel<float>
          <<<N * Y_HxW, CAFFE_CUDA_NUM_THREADS, 0, context->cuda_stream()>>>(
              C,
              X_dims[0],
              X_dims[1],
              X_dims[2],
              Y_dims[0],
              Y_dims[1],
              Y_dims[2],
              kernel[0],
              kernel[1],
              kernel[2],
              stride[0],
              stride[1],
              stride[2],
              pads[0],
              pads[1],
              pads[2],
              count_include_pad,
              X,
              Y);
      return true;
    }
    default: {
      CAFFE_THROW("Unsupported pooling dim: ", ndim);
      return false;
    }
  }
}

template <>
bool PoolGradientOp<float, CUDAContext, AveragePool>::
    RunOnDeviceWithOrderNCHW() {
  auto& X = Input(0);
  auto& dY = Input(2);
  CAFFE_ENFORCE_EQ(dY.dim32(1), X.dim32(1));
  auto* dX = Output(0);
  dX->ResizeLike(X);
  vector<int> dims(X.sizes().begin() + 2, X.sizes().end());
  ConvPoolOpBase<CUDAContext>::ComputePads(dims);
  switch (kernel_.size()) {
    case 1:
      Ave1DPoolBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              dY.dim32(2),
              kernel_h(),
              stride_h(),
              pad_t(),
              dX->template mutable_data<float>());
      break;
    case 2:
      Ave2DPoolBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              dY.dim32(2),
              dY.dim32(3),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              dX->template mutable_data<float>());
      break;
    case 3:
      Ave3DPoolBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              dY.dim32(2),
              dY.dim32(3),
              dY.dim32(4),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              dX->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

template <>
bool PoolGradientOp<float, CUDAContext, AveragePool>::
    RunOnDeviceWithOrderNHWC() {
  auto& X = Input(0);
  auto& dY = Input(2);
  CAFFE_ENFORCE_EQ(X.ndim(), dY.ndim());
  CAFFE_ENFORCE_EQ(X.dim32(X.ndim() - 1), dY.dim32(dY.ndim() - 1));
  auto* dX = Output(0);
  dX->ResizeLike(X);
  vector<int> dims(X.sizes().begin() + 1, X.sizes().end() - 1);
  ConvPoolOpBase<CUDAContext>::ComputePads(dims);
  switch (kernel_.size()) {
    case 1:
      Ave1DPoolBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              dY.dim32(1),
              kernel_h(),
              stride_h(),
              pad_t(),
              dX->template mutable_data<float>());
      break;
    case 2:
      Ave2DPoolBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              dY.dim32(1),
              dY.dim32(2),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              dX->template mutable_data<float>());
      break;
    case 3:
      Ave3DPoolBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              dY.dim32(1),
              dY.dim32(2),
              dY.dim32(3),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              dX->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

namespace {

template <typename T>
__global__ void MaxPool1DForwardNCHW(
    const int nthreads,
    const T* bottom_data,
    const int channels,
    const int height,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int ph = index % pooled_height;
    int c = (index / pooled_height) % channels;
    int n = index / pooled_height / channels;
    int hstart = ph * stride_h - pad_t;
    int hend = min(hstart + kernel_h, height);
    hstart = max(hstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * channels * height;
    for (int h = hstart; h < hend; ++h) {
      int idx = c * height + h;
      if (bdata_offset[idx] > maxval) {
        maxval = bdata_offset[idx];
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool2DForwardNCHW(
    const int nthreads,
    const T* bottom_data,
    const int channels,
    const int height,
    const int width,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_t;
    int wstart = pw * stride_w - pad_l;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * channels * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        int idx = c * height * width + h * width + w;
        if (bdata_offset[idx] > maxval) {
          maxval = bdata_offset[idx];
        }
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool3DForwardNCHW(
    const int nthreads,
    const T* bottom_data,
    const int channels,
    const int height,
    const int width,
    const int depth,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int pd = index % pooled_depth;
    int pw = (index / pooled_depth) % pooled_width;
    int ph = (index / pooled_depth / pooled_width) % pooled_height;
    int c = (index / pooled_depth / pooled_width / pooled_height) % channels;
    int n = index / pooled_depth / pooled_width / pooled_height / channels;
    int hstart = ph * stride_h - pad_t;
    int wstart = pw * stride_w - pad_l;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    int dstart = pd * stride_d - pad_f;
    int dend = min(dstart + kernel_d, depth);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    dstart = max(dstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * channels * height * width * depth;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        for (int d = dstart; d < dend; ++d) {
          int idx = ((c * height + h) * width + w) * depth + d;
          if (bdata_offset[idx] > maxval) {
            maxval = bdata_offset[idx];
          }
        }
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool1DForwardNHWC(
    const int nthreads,
    const T* bottom_data,
    const int height,
    const int channels,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int n = index;
    int c = n % channels;
    n /= channels;
    int hstart = (n % pooled_height) * stride_h - pad_t;
    n /= pooled_height;
    int hend = min(hstart + kernel_h, height);
    hstart = max(hstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * height * channels;
    for (int h = hstart; h < hend; ++h) {
      int idx = h * channels + c;
      if (bdata_offset[idx] > maxval) {
        maxval = bdata_offset[idx];
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool2DForwardNHWC(
    const int nthreads,
    const T* bottom_data,
    const int height,
    const int width,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int n = index;
    int c = n % channels;
    n /= channels;
    int wstart = (n % pooled_width) * stride_w - pad_l;
    n /= pooled_width;
    int hstart = (n % pooled_height) * stride_h - pad_t;
    n /= pooled_height;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * height * width * channels;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        int idx = (h * width + w) * channels + c;
        if (bdata_offset[idx] > maxval) {
          maxval = bdata_offset[idx];
        }
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool3DForwardNHWC(
    const int nthreads,
    const T* bottom_data,
    const int height,
    const int width,
    const int depth,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* top_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    int n = index;
    int c = n % channels;
    n /= channels;
    int dstart = (n % pooled_depth) * stride_d - pad_f;
    n /= pooled_depth;
    int wstart = (n % pooled_width) * stride_w - pad_l;
    n /= pooled_width;
    int hstart = (n % pooled_height) * stride_h - pad_t;
    n /= pooled_height;
    int hend = min(hstart + kernel_h, height);
    int wend = min(wstart + kernel_w, width);
    int dend = min(dstart + kernel_d, depth);
    hstart = max(hstart, 0);
    wstart = max(wstart, 0);
    dstart = max(dstart, 0);
    T maxval = -FLT_MAX;
    const T* bdata_offset = bottom_data + n * height * width * depth * channels;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        for (int d = dstart; d < dend; ++d) {
          int idx = ((h * width + w) * depth + d) * channels + c;
          if (bdata_offset[idx] > maxval) {
            maxval = bdata_offset[idx];
          }
        }
      }
    }
    top_data[index] = maxval;
  }
}

template <typename T>
__global__ void MaxPool1DBackwardNCHW(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int h = index % height + pad_t;
    const int c = (index / height) % channels;
    const int n = index / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int top_offset = (n * channels + c) * pooled_height;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      int top_local_offset = top_offset + ph;
      if (bottom_data[index] == top_data[top_local_offset]) {
        bottom_diff[index] += top_diff[top_local_offset];
      }
    }
  }
}

template <typename T>
__global__ void MaxPool2DBackwardNCHW(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int width,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int w = index % width + pad_l;
    const int h = (index / width) % height + pad_t;
    const int c = (index / width / height) % channels;
    const int n = index / width / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int top_offset = (n * channels + c) * pooled_height * pooled_width;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        int top_local_offset = top_offset + ph * pooled_width + pw;
        if (bottom_data[index] == top_data[top_local_offset]) {
          bottom_diff[index] += top_diff[top_local_offset];
        }
      }
    }
  }
}

template <typename T>
__global__ void MaxPool3DBackwardNCHW(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int channels,
    const int height,
    const int width,
    const int depth,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int d = index % depth + pad_f;
    const int w = (index / depth) % width + pad_l;
    const int h = (index / depth / width) % height + pad_t;
    const int c = (index / depth / width / height) % channels;
    const int n = index / depth / width / height / channels;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int pdstart = (d < kernel_d) ? 0 : (d - kernel_d) / stride_d + 1;
    const int pdend = min(d / stride_d + 1, pooled_depth);
    const int top_offset =
        (n * channels + c) * pooled_height * pooled_width * pooled_depth;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        for (int pd = pdstart; pd < pdend; ++pd) {
          int top_local_offset =
              top_offset + (ph * pooled_width + pw) * pooled_depth + pd;
          if (bottom_data[index] == top_data[top_local_offset]) {
            bottom_diff[index] += top_diff[top_local_offset];
          }
        }
      }
    }
  }
}

template <typename T>
__global__ void MaxPool1DBackwardNHWC(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int height,
    const int channels,
    const int pooled_height,
    const int kernel_h,
    const int stride_h,
    const int pad_t,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int h = (index / channels) % height + pad_t;
    const int n = index / channels / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int top_offset = n * pooled_height * channels + c;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      int top_local_offset = top_offset + ph * channels;
      if (bottom_data[index] == top_data[top_local_offset]) {
        bottom_diff[index] += top_diff[top_local_offset];
      }
    }
  }
}

template <typename T>
__global__ void MaxPool2DBackwardNHWC(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int height,
    const int width,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int kernel_h,
    const int kernel_w,
    const int stride_h,
    const int stride_w,
    const int pad_t,
    const int pad_l,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int w = index / channels % width + pad_l;
    const int h = (index / channels / width) % height + pad_t;
    const int n = index / channels / width / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int top_offset = n * pooled_height * pooled_width * channels + c;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        int top_local_offset = top_offset + (ph * pooled_width + pw) * channels;
        if (bottom_data[index] == top_data[top_local_offset]) {
          bottom_diff[index] += top_diff[top_local_offset];
        }
      }
    }
  }
}

template <typename T>
__global__ void MaxPool3DBackwardNHWC(
    const int nthreads,
    const T* const bottom_data,
    const T* const top_data,
    const T* const top_diff,
    const int num,
    const int height,
    const int width,
    const int depth,
    const int channels,
    const int pooled_height,
    const int pooled_width,
    const int pooled_depth,
    const int kernel_h,
    const int kernel_w,
    const int kernel_d,
    const int stride_h,
    const int stride_w,
    const int stride_d,
    const int pad_t,
    const int pad_l,
    const int pad_f,
    T* const bottom_diff) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // find out the local index
    // find out the local offset
    const int c = index % channels;
    const int d = index / channels % depth + pad_f;
    const int w = (index / depth / channels) % width + pad_l;
    const int h = (index / channels / depth / width) % height + pad_t;
    const int n = index / channels / depth / width / height;
    const int phstart = (h < kernel_h) ? 0 : (h - kernel_h) / stride_h + 1;
    const int phend = min(h / stride_h + 1, pooled_height);
    const int pwstart = (w < kernel_w) ? 0 : (w - kernel_w) / stride_w + 1;
    const int pwend = min(w / stride_w + 1, pooled_width);
    const int pdstart = (d < kernel_d) ? 0 : (d - kernel_d) / stride_d + 1;
    const int pdend = min(d / stride_d + 1, pooled_depth);
    const int top_offset =
        n * pooled_height * pooled_width * pooled_depth * channels + c;
    bottom_diff[index] = 0;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        for (int pd = pdstart; pd < pdend; ++pd) {
          int top_local_offset = top_offset +
              ((ph * pooled_width + pw) * pooled_depth + d) * channels;
          if (bottom_data[index] == top_data[top_local_offset]) {
            bottom_diff[index] += top_diff[top_local_offset];
          }
        }
      }
    }
  }
}
} // namespace

template <>
bool PoolOp<float, CUDAContext, MaxPool>::RunOnDeviceWithOrderNCHW() {
  auto& X = Input(0);
  auto* Y = Output(0);
  ConvPoolOpBase<CUDAContext>::SetOutputSize(X, Y, X.dim32(1));
  int output_size = Y->size();
  switch (kernel_.size()) {
    case 1:
      MaxPool1DForwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              Y->dim32(2),
              kernel_h(),
              stride_h(),
              pad_t(),
              Y->template mutable_data<float>());
      break;
    case 2:
      MaxPool2DForwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              Y->dim32(2),
              Y->dim32(3),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              Y->template mutable_data<float>());
      break;
    case 3:
      MaxPool3DForwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              Y->dim32(2),
              Y->dim32(3),
              Y->dim32(4),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              Y->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

template <>
bool PoolOp<float, CUDAContext, MaxPool>::RunOnDeviceWithOrderNHWC() {
  auto& X = Input(0);
  auto* Y = Output(0);
  ConvPoolOpBase<CUDAContext>::SetOutputSize(X, Y, X.dim32(X.ndim() - 1));
  int output_size = Y->size();
  switch (kernel_.size()) {
    case 1:
      MaxPool1DForwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              Y->dim32(1),
              kernel_h(),
              stride_h(),
              pad_t(),
              Y->template mutable_data<float>());
      break;
    case 2:
      MaxPool2DForwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              Y->dim32(1),
              Y->dim32(2),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              Y->template mutable_data<float>());
      break;
    case 3:
      MaxPool3DForwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(output_size),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              output_size,
              X.data<float>(),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              Y->dim32(1),
              Y->dim32(2),
              Y->dim32(3),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              Y->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

template <>
bool PoolGradientOp<float, CUDAContext, MaxPool>::RunOnDeviceWithOrderNCHW() {
  auto& X = Input(0);
  auto& Y = Input(1);
  auto& dY = Input(2);
  CAFFE_ENFORCE_EQ(dY.ndim(), X.ndim());
  auto* dX = Output(0);
  dX->ResizeLike(X);
  vector<int> dims(X.sizes().begin() + 2, X.sizes().end());
  ConvPoolOpBase<CUDAContext>::ComputePads(dims);
  switch (kernel_.size()) {
    case 1:
      MaxPool1DBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              dY.dim32(2),
              kernel_h(),
              stride_h(),
              pad_t(),
              dX->template mutable_data<float>());
      break;
    case 2:
      MaxPool2DBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              dY.dim32(2),
              dY.dim32(3),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              dX->template mutable_data<float>());
      break;
    case 3:
      MaxPool3DBackwardNCHW<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              dY.dim32(2),
              dY.dim32(3),
              dY.dim32(4),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              dX->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

template <>
bool PoolGradientOp<float, CUDAContext, MaxPool>::RunOnDeviceWithOrderNHWC() {
  auto& X = Input(0);
  auto& Y = Input(1);
  auto& dY = Input(2);
  CAFFE_ENFORCE_EQ(dY.ndim(), X.ndim());
  auto* dX = Output(0);
  dX->ResizeLike(X);
  vector<int> dims(X.sizes().begin() + 1, X.sizes().end() - 1);
  ConvPoolOpBase<CUDAContext>::ComputePads(dims);
  switch (kernel_.size()) {
    case 1:
      MaxPool1DBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              dY.dim32(1),
              kernel_h(),
              stride_h(),
              pad_t(),
              dX->template mutable_data<float>());
      break;
    case 2:
      MaxPool2DBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              dY.dim32(1),
              dY.dim32(2),
              kernel_h(),
              kernel_w(),
              stride_h(),
              stride_w(),
              pad_t(),
              pad_l(),
              dX->template mutable_data<float>());
      break;
    case 3:
      MaxPool3DBackwardNHWC<float>
          <<<CAFFE_GET_BLOCKS(X.size()),
             CAFFE_CUDA_NUM_THREADS,
             0,
             context_.cuda_stream()>>>(
              X.size(),
              X.data<float>(),
              Y.data<float>(),
              dY.data<float>(),
              X.dim32(0),
              X.dim32(1),
              X.dim32(2),
              X.dim32(3),
              X.dim32(4),
              dY.dim32(1),
              dY.dim32(2),
              dY.dim32(3),
              kernel_h(),
              kernel_w(),
              kernel_[2],
              stride_h(),
              stride_w(),
              stride_[2],
              pad_t(),
              pad_l(),
              pads_[2],
              dX->template mutable_data<float>());
      break;
    default:
      CAFFE_THROW("Unsupported pooling size : ", kernel_.size());
  }
  return true;
}

REGISTER_CUDA_OPERATOR(
    AveragePool,
    PoolOp<float, CUDAContext, AveragePoolFunctor<CUDAContext>>);
REGISTER_CUDA_OPERATOR(
    AveragePoolGradient,
    PoolGradientOp<float, CUDAContext, AveragePool>);

REGISTER_CUDA_OPERATOR(
    AveragePool1D,
    PoolOp<float, CUDAContext, AveragePoolFunctor<CUDAContext>>);
REGISTER_CUDA_OPERATOR(
    AveragePool1DGradient,
    PoolGradientOp<float, CUDAContext, AveragePool>);

REGISTER_CUDA_OPERATOR(
    AveragePool2D,
    PoolOp<float, CUDAContext, AveragePoolFunctor<CUDAContext>>);
REGISTER_CUDA_OPERATOR(
    AveragePool2DGradient,
    PoolGradientOp<float, CUDAContext, AveragePool>);

REGISTER_CUDA_OPERATOR(
    AveragePool3D,
    PoolOp<float, CUDAContext, AveragePoolFunctor<CUDAContext>>);
REGISTER_CUDA_OPERATOR(
    AveragePool3DGradient,
    PoolGradientOp<float, CUDAContext, AveragePool>);

REGISTER_CUDA_OPERATOR(MaxPool, PoolOp<float, CUDAContext, MaxPool>);
REGISTER_CUDA_OPERATOR(
    MaxPoolGradient,
    PoolGradientOp<float, CUDAContext, MaxPool>);

REGISTER_CUDA_OPERATOR(MaxPool1D, PoolOp<float, CUDAContext, MaxPool>);
REGISTER_CUDA_OPERATOR(
    MaxPool1DGradient,
    PoolGradientOp<float, CUDAContext, MaxPool>);

REGISTER_CUDA_OPERATOR(MaxPool2D, PoolOp<float, CUDAContext, MaxPool>);
REGISTER_CUDA_OPERATOR(
    MaxPool2DGradient,
    PoolGradientOp<float, CUDAContext, MaxPool>);

REGISTER_CUDA_OPERATOR(MaxPool3D, PoolOp<float, CUDAContext, MaxPool>);
REGISTER_CUDA_OPERATOR(
    MaxPool3DGradient,
    PoolGradientOp<float, CUDAContext, MaxPool>);
} // namespace caffe2
