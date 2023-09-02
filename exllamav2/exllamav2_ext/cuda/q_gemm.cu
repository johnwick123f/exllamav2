#include "q_gemm.cuh"
#include "util.cuh"
#include "matrix_view.cuh"
#include "../config.h"
#include <cuda/barrier>
#include <cuda/pipeline>

#include "../config.h"

#include "quant/qdq_2.cuh"
#include "quant/qdq_3.cuh"
#include "quant/qdq_4.cuh"
#include "quant/qdq_5.cuh"
#include "quant/qdq_6.cuh"
#include "quant/qdq_8.cuh"

#define BLOCK_KN_SIZE 512
#define BLOCK_M_SIZE_MAX 8
#define MAX_GROUPS_IN_BLOCK (BLOCK_KN_SIZE / 32)
#define CLEAR_N_SIZE 256


__forceinline__ __device__ half2 dot22_8(half2(&dq)[4], const half* a_ptr, const half2 g_result, const half qs_h)
{
    half2 result = {};
    const half2* a2_ptr = (const half2*)a_ptr;
    for (int i = 0; i < 4; i++) result = __hfma2(dq[i], *a2_ptr++, result);
    return __hfma2(result, __halves2half2(qs_h, qs_h), g_result);
}

__forceinline__ __device__ half2 dot22_16(half2(&dq)[8], const half* a_ptr, const half2 g_result, const half qs_h)
{
    half2 result = {};
    const half2* a2_ptr = (const half2*)a_ptr;
    for (int i = 0; i < 8; i++) result = __hfma2(dq[i], *a2_ptr++, result);
    return __hfma2(result, __halves2half2(qs_h, qs_h), g_result);
}

__forceinline__ __device__ half2 dot22_32(half2(&dq)[16], const half* a_ptr, const half2 g_result, const half qs_h)
{
    half2 result = {};
    const half2* a2_ptr = (const half2*)a_ptr;
    for (int i = 0; i < 16; i += 1) result = __hfma2(dq[i], *a2_ptr++, result);
    return __hfma2(result, __halves2half2(qs_h, qs_h), g_result);
}


typedef void (*fp_gemm_half_q_half_kernel)
(
    const half*,
    const uint32_t*,
    const uint32_t*,
    const half*,
    half*,
    const int,
    const int,
    const int,
    const int,
    const int,
    const uint16_t*,
    const int,
    const int,
    const int,
    const int,
    const int,
    const int,
    const bool
);

template <bool first_block, int m_count>
__global__ void gemm_half_q_half_kernel
(
    const half*      __restrict__ a,
    const uint32_t*  __restrict__ b_q_weight,
    const uint32_t*  __restrict__ b_q_scale,
    const half*      __restrict__ b_q_scale_max,
    half*            __restrict__ c,
    const int size_m,
    const int size_n,
    const int size_k,
    const int groups,
    const int groupsize,
    const uint16_t* __restrict__ b_q_perm,
    const int rows_8,
    const int rows_6,
    const int rows_5,
    const int rows_4,
    const int rows_3,
    const int rows_2,
    const bool clear
)
{
    MatrixView_half a_(a, size_m, size_k);
    MatrixView_half_rw c_(c, size_m, size_n);
    MatrixView_q4_row b_q_scale_(b_q_scale, groups, size_n);

    int t = threadIdx.x;

    // Block

    int offset_n = blockIdx.x * BLOCK_KN_SIZE;
    int offset_m = blockIdx.y * m_count;
    int offset_k = blockIdx.z * BLOCK_KN_SIZE;

    int end_n = min(offset_n + BLOCK_KN_SIZE, size_n);
    int end_m = min(offset_m + m_count, size_m);
    int end_k = min(offset_k + BLOCK_KN_SIZE, size_k);
    int n = offset_n + t;

    // Preload block_a

    __shared__ half block_a[m_count][BLOCK_KN_SIZE];

    if (offset_k + t < end_k)
    {
        for (int m = 0; m < m_count; ++m)
        {
            const half* a_ptr = a_.item_ptr(offset_m + m, 0);
            half* block_a_ptr = block_a[m];
            half a0 = a_ptr[b_q_perm[offset_k + t]];
            block_a_ptr[t] = a0;
        }
    }

    // Compute 2-bit LUT if needed

    if (n >= size_n) return;

    if (clear && blockIdx.z == 0) // && (threadIdx.x & 1) == 0)
    {
        for (int m = 0; m < m_count; m++)
            *((uint16_t*) c_.item_ptr(offset_m + m, n)) = 0;
    }

    __syncthreads();

    // Find initial group

    int group = offset_k / groupsize;

    // Preload scales

    half scales[MAX_GROUPS_IN_BLOCK];

    int groups_in_block = DIVIDE((end_k - offset_k), groupsize);
    for (int g = 0; g < groups_in_block; g++)
    {
        half s = dq_scale(b_q_scale_.item(group + g, n), b_q_scale_max[group + g]);
        scales[g] = s;
    }

    // Find initial q row

    int pre_rows_8 = min(rows_8, offset_k);
    int pre_rows_6 = offset_k > rows_8 ? min(rows_6, offset_k) - rows_8 : 0;
    int pre_rows_5 = offset_k > rows_6 ? min(rows_5, offset_k) - rows_6 : 0;
    int pre_rows_4 = offset_k > rows_5 ? min(rows_4, offset_k) - rows_5 : 0;
    int pre_rows_3 = offset_k > rows_4 ? min(rows_3, offset_k) - rows_4 : 0;
    int pre_rows_2 = offset_k > rows_3 ? min(rows_2, offset_k) - rows_3 : 0;
    int qk = 0;
    qk += pre_rows_8 / 32 * 8;
    qk += pre_rows_6 / 32 * 6;
    qk += pre_rows_5 / 32 * 5;
    qk += pre_rows_4 / 32 * 4;
    qk += pre_rows_3 / 32 * 3;
    qk += pre_rows_2 / 32 * 2;

    const uint32_t* b_ptr = b_q_weight + qk * size_n + n;
    const half* a_ptr = &block_a[0][0];
    int a_stride = BLOCK_KN_SIZE;

    half qs_h = scales[0];
    int scales_idx = 0;
    int nextgroup = offset_k + groupsize;

    // Column result

    half2 block_c[m_count] = {};

    // Dequantize and process groups

    int k = offset_k;

    while (k < rows_8 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        #pragma unroll
        for (int j = 0; j < 4; j++)
        {
            half2 dq[4];
            dequant_8bit_8(b_ptr, dq, size_n); b_ptr += 2 * size_n;
            for (int m = 0; m < m_count; m++) block_c[m] = dot22_8(dq, a_ptr + m * a_stride, block_c[m], qs_h);
            a_ptr += 8;
        }
        k += 32;
    }

    while (k < rows_6 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        #pragma unroll
        for (int j = 0; j < 2; j++)
        {
            half2 dq[8];
            dequant_6bit_16(b_ptr, dq, size_n); b_ptr += size_n * 3;
            for (int m = 0; m < m_count; m++) block_c[m] = dot22_16(dq, a_ptr + m * a_stride, block_c[m], qs_h);
            a_ptr += 16;
        }
        k += 32;
    }

    while (k < rows_5 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        half2 dq[16];
        dequant_5bit_32(b_ptr, dq, size_n); b_ptr += 5 * size_n;
        for (int m = 0; m < m_count; m++) block_c[m] = dot22_32(dq, a_ptr + m * a_stride, block_c[m], qs_h);
        a_ptr += 32;
        k += 32;
    }

    while (k < rows_4 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        #pragma unroll
        for (int j = 0; j < 4; j++)
        {
            half2 dq[4];
            dequant_4bit_8(b_ptr, dq, size_n); b_ptr += size_n;
            for (int m = 0; m < m_count; m++) block_c[m] = dot22_8(dq, a_ptr + m * a_stride, block_c[m], qs_h);
            a_ptr += 8;
        }
        k += 32;
    }

    while (k < rows_3 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        half2 dq[16];
        dequant_3bit_32(b_ptr, dq, size_n); b_ptr += 3 * size_n;
        for (int m = 0; m < m_count; m++) block_c[m] = dot22_32(dq, a_ptr + m * a_stride, block_c[m], qs_h);
        a_ptr += 32;
        k += 32;
    }

    while (k < rows_2 && k < end_k)
    {
        if (k == nextgroup)
        {
            group++;
            scales_idx++;
            qs_h = scales[scales_idx];
            nextgroup += groupsize;
        }

        #pragma unroll
        for (int j = 0; j < 2; j++)
        {
            half2 dq[8];
            dequant_2bit_16(b_ptr, dq, size_n); b_ptr += size_n;
            for (int m = 0; m < m_count; m++) block_c[m] = dot22_16(dq, a_ptr + m * a_stride, block_c[m], qs_h);
            a_ptr += 16;
        }
        k += 32;
    }

    // Accumulate column sums in c

    for (int m = 0; m < m_count; m++) atomicAdd(c_.item_ptr(offset_m + m, n), __hadd(block_c[m].x, block_c[m].y));
//     for (int m = 0; m < m_count; m++) c_.set(offset_m + m, n, __hadd(block_c[m].x, block_c[m].y));
}

fp_gemm_half_q_half_kernel pick_gemm_half_q_half_kernel(bool first_block, const int m_count)
{
    #if BLOCK_M_SIZE_MAX >= 1
    if (m_count == 1) return gemm_half_q_half_kernel<true, 1>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 2
    if (m_count == 2) return gemm_half_q_half_kernel<true, 2>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 3
    if (m_count == 3) return gemm_half_q_half_kernel<true, 3>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 4
    if (m_count == 4) return gemm_half_q_half_kernel<true, 4>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 5
    if (m_count == 5) return gemm_half_q_half_kernel<true, 5>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 6
    if (m_count == 6) return gemm_half_q_half_kernel<true, 6>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 7
    if (m_count == 7) return gemm_half_q_half_kernel<true, 7>;
    #endif
    #if BLOCK_M_SIZE_MAX >= 8
    if (m_count == 8) return gemm_half_q_half_kernel<true, 8>;
    #endif
    return NULL;
}

void gemm_half_q_half_cuda_part
(
    const half* a,
    QMatrix* b,
    half* c,
    int size_m,
    int size_n,
    int size_k,
    int m_count,
    bool clear
)
{
    dim3 blockDim, gridDim;
    blockDim.x = BLOCK_KN_SIZE;
    blockDim.y = 1;
    blockDim.z = 1;
    gridDim.x = DIVIDE(size_n, BLOCK_KN_SIZE);
    gridDim.y = DIVIDE(size_m, m_count);
    gridDim.z = DIVIDE(size_k, BLOCK_KN_SIZE);

    fp_gemm_half_q_half_kernel kernel = pick_gemm_half_q_half_kernel(true, m_count);

    kernel<<<gridDim, blockDim>>>
    (
        a,
        b->cuda_q_weight,
        b->cuda_q_scale,
        b->cuda_q_scale_max,
        c,
        size_m,
        size_n,
        size_k,
        b->groups,
        b->groupsize,
        b->cuda_q_perm,
        b->rows_8,
        b->rows_6,
        b->rows_5,
        b->rows_4,
        b->rows_3,
        b->rows_2,
        clear
    );
}

void gemm_half_q_half_cuda
(
    cublasHandle_t cublas_handle,
    const half* a,
    QMatrix* b,
    half* c,
    int size_m,
    int size_n,
    int size_k,
    bool clear,
    half* temp_dq
)
{
    if (size_m >= MAX_Q_GEMM_ROWS)
    {
        // Reconstruct FP16 matrix, then cuBLAS

        if (!temp_dq) temp_dq = b->temp_dq;
        b->reconstruct(temp_dq);

        //cublasSetMathMode(cublas_handle, CUBLAS_TENSOR_OP_MATH);

        const half alpha = __float2half(1.0f);
        const half beta = clear ? __float2half(0.0f) : __float2half(1.0f);
        cublasHgemm(cublas_handle,
                    CUBLAS_OP_N,
                    CUBLAS_OP_N,
                    size_n,
                    size_m,
                    size_k,
                    &alpha,
                    temp_dq,
                    size_n,
                    a,
                    size_k,
                    &beta,
                    c,
                    size_n);

//         const float alpha = 1.0f;
//         const float beta = clear ? 0.0f : 1.0f;
//         cublasSgemmEx(cublas_handle,
//                       CUBLAS_OP_N,
//                       CUBLAS_OP_N,
//                       size_n,
//                       size_m,
//                       size_k,
//                       &alpha,
//                       temp_dq,
//                       CUDA_R_16F,
//                       size_n,
//                       a,
//                       CUDA_R_16F,
//                       size_k,
//                       &beta,
//                       c,
//                       CUDA_R_16F,
//                       size_n);
    }
    else
    {
        // Quantized matmul

        //if (clear) clear_tensor_cuda(c, size_m, size_n);

        int max_chunks = size_m / BLOCK_M_SIZE_MAX;
        int last_chunk = max_chunks * BLOCK_M_SIZE_MAX;
        int last_chunk_size = size_m - last_chunk;

        if (max_chunks)
        {
            gemm_half_q_half_cuda_part(a, b, c, last_chunk, size_n, size_k, BLOCK_M_SIZE_MAX, clear);
        }

        if (last_chunk_size)
        {
            gemm_half_q_half_cuda_part(a + last_chunk * size_k, b, c + last_chunk * size_n, last_chunk_size, size_n, size_k, last_chunk_size, clear);
        }
    }
}

__global__ void clear_kernel
(
    half* __restrict__ c,
    const int size_m,
    const int size_n
)
{
    int m = blockIdx.y;
    int n = (blockIdx.x * CLEAR_N_SIZE + threadIdx.x) * 8;
    if (n >= size_n) return;
    int4* c_ptr = (int4*)(c + m * size_n + n);
    *c_ptr = {};
}

void clear_tensor_cuda
(
    half* c,
    int size_m,
    int size_n
)
{
    return;
    dim3 blockDim, gridDim;
    blockDim.x = CLEAR_N_SIZE;
    blockDim.y = 1;
    gridDim.x = DIVIDE(size_n / 8, CLEAR_N_SIZE);
    gridDim.y = size_m;
    clear_kernel<<<gridDim, blockDim>>>(c, size_m, size_n);
}