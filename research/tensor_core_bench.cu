/**
 * Tensor Core Microbenchmark for CMP 90HX (GA102, sm_86)
 *
 * Tests all three Tensor Core instruction types:
 *   - IMMA: INT8 tensor cores (mma.sync.aligned.m16n8k16.row.col.s32.s8.s8.s32)
 *   - HMMA: FP16 tensor cores (mma.sync.aligned.m16n8k16.row.col.f16.f16.f16.f16)
 *   - TF32: TensorFloat-32 (mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32)
 *
 * Expected peak throughput on GA102 (68 SMs @ 1.8 GHz):
 *   - IMMA INT8:  272 TOPS (4 ops/core/cycle * 4 TCs/SM * 68 * 1.8e9)
 *   - HMMA FP16:  272 TFLOPS
 *   - TF32:       136 TFLOPS (half the throughput)
 *
 * CMP 90HX (50 SMs) expected after SS0/SS1 unlock:
 *   - IMMA INT8:  ~200 TOPS
 *   - HMMA FP16:  ~200 TFLOPS
 *   - TF32:       ~100 TFLOPS
 *
 * Compile: nvcc -arch=sm_86 -O3 tensor_core_bench.cu -o tensor_core_bench
 * Run:     ./tensor_core_bench
 *
 * Reference: https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#matrix-multiply-accumulate-operation-using-mma-instruction
 */

#include <cuda_runtime.h>
#include <cuda_fp16.h>
#include <mma.h>
#include <cstdio>
#include <chrono>

using namespace nvcuda;

// ============================================================================
// Direct PTX IMMA benchmark (INT8 -> INT32, bypasses WMMA API)
// ============================================================================
__global__ void imma_m16n8k16_kernel(int *dummy, int iters) {
    // Each warp executes iters MMA operations
    // m16n8k16: 16*8*16*2 = 4096 INT8 ops per instruction

    int a0 = 0x01010101, a1 = 0x01010101;  // A matrix (2 registers, packed INT8)
    int b0 = 0x01010101;                    // B matrix (1 register, packed INT8)
    int c0 = 0, c1 = 0, c2 = 0, c3 = 0;     // C/D matrix (4 registers, INT32)

    for (int i = 0; i < iters; i++) {
        asm volatile(
            "mma.sync.aligned.m16n8k16.row.col.s32.s8.s8.s32 "
            "{%0, %1, %2, %3}, {%4, %5}, {%6}, {%0, %1, %2, %3};"
            : "+r"(c0), "+r"(c1), "+r"(c2), "+r"(c3)
            : "r"(a0), "r"(a1), "r"(b0)
        );
    }

    // Prevent optimization
    if (c0 == 0xDEADBEEF && c1 == 0xCAFEBABE) {
        dummy[threadIdx.x] = c0 + c1 + c2 + c3;
    }
}

// ============================================================================
// Direct PTX HMMA benchmark (FP16 -> FP16)
// ============================================================================
__global__ void hmma_m16n8k16_kernel(int *dummy, int iters) {
    // m16n8k16 FP16: 16*8*16*2 = 4096 FP16 ops per instruction

    int a0 = 0x3C003C00;  // 1.0 in FP16, packed
    int a1 = 0x3C003C00;
    int a2 = 0x3C003C00;
    int a3 = 0x3C003C00;
    int b0 = 0x3C003C00;
    int b1 = 0x3C003C00;
    int d0 = 0, d1 = 0;   // D matrix (FP16 output)

    for (int i = 0; i < iters; i++) {
        asm volatile(
            "mma.sync.aligned.m16n8k16.row.col.f16.f16.f16.f16 "
            "{%0, %1}, {%2, %3, %4, %5}, {%6, %7}, {%0, %1};"
            : "+r"(d0), "+r"(d1)
            : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1)
        );
    }

    if (d0 == 0xDEADBEEF) {
        dummy[threadIdx.x] = d0 + d1;
    }
}

// ============================================================================
// Direct PTX TF32 benchmark (TF32 -> FP32)
// ============================================================================
__global__ void tf32_m16n8k8_kernel(int *dummy, int iters) {
    // m16n8k8 TF32: 16*8*8*2 = 2048 ops per instruction

    int a0 = 0x3F800000;  // 1.0 in FP32/TF32
    int a1 = 0x3F800000;
    int a2 = 0x3F800000;
    int a3 = 0x3F800000;
    int b0 = 0x3F800000;
    int b1 = 0x3F800000;
    int d0 = 0, d1 = 0, d2 = 0, d3 = 0;

    for (int i = 0; i < iters; i++) {
        asm volatile(
            "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32 "
            "{%0, %1, %2, %3}, {%4, %5, %6, %7}, {%8, %9}, {%0, %1, %2, %3};"
            : "+r"(d0), "+r"(d1), "+r"(d2), "+r"(d3)
            : "r"(a0), "r"(a1), "r"(a2), "r"(a3), "r"(b0), "r"(b1)
        );
    }

    if (d0 == 0xDEADBEEF) {
        dummy[threadIdx.x] = d0 + d1 + d2 + d3;
    }
}

// ============================================================================
// WMMA-based benchmark for comparison (uses NVIDIA's official API)
// ============================================================================
__global__ void wmma_fp16_kernel(half *a, half *b, float *c, int iters) {
    wmma::fragment<wmma::matrix_a, 16, 16, 16, half, wmma::row_major> a_frag;
    wmma::fragment<wmma::matrix_b, 16, 16, 16, half, wmma::col_major> b_frag;
    wmma::fragment<wmma::accumulator, 16, 16, 16, float> c_frag;

    wmma::fill_fragment(c_frag, 0.0f);
    wmma::load_matrix_sync(a_frag, a, 16);
    wmma::load_matrix_sync(b_frag, b, 16);

    for (int i = 0; i < iters; i++) {
        wmma::mma_sync(c_frag, a_frag, b_frag, c_frag);
    }

    wmma::store_matrix_sync(c, c_frag, 16, wmma::mem_row_major);
}

// ============================================================================
// Utility functions
// ============================================================================
void print_device_info() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("=== Tensor Core Microbenchmark ===\n");
    printf("Device: %s\n", prop.name);
    printf("Compute Capability: sm_%d%d\n", prop.major, prop.minor);
    printf("SMs: %d\n", prop.multiProcessorCount);
    printf("Clock: %.2f GHz\n", prop.clockRate / 1e6);
    printf("Memory: %.1f GB\n", prop.totalGlobalMem / 1e9);
    printf("\n");

    // Print expected theoretical peaks
    int SMs = prop.multiProcessorCount;
    float clock_ghz = prop.clockRate / 1e6;
    // GA102: 4 Tensor Cores per SM, each does 256 INT8 ops/cycle or 256 FP16 ops/cycle
    float imma_tops = SMs * 4 * 256 * clock_ghz * 2 / 1000;  // 2 ops per element (multiply-add)
    float hmma_tflops = SMs * 4 * 256 * clock_ghz * 2 / 1000;
    float tf32_tflops = SMs * 4 * 128 * clock_ghz * 2 / 1000;  // Half rate for TF32

    printf("Theoretical Peak (GA102 formula):\n");
    printf("  IMMA INT8:  %.1f TOPS\n", imma_tops);
    printf("  HMMA FP16:  %.1f TFLOPS\n", hmma_tflops);
    printf("  TF32:       %.1f TFLOPS\n", tf32_tflops);
    printf("\n");
}

template<typename KernelFunc>
double benchmark_kernel(KernelFunc kernel, int blocks, int threads, int iters,
                        int ops_per_iter, const char* name) {
    int *d_dummy;
    cudaMalloc(&d_dummy, 4);

    // Warmup
    kernel<<<blocks, threads>>>(d_dummy, 1000);
    cudaDeviceSynchronize();

    // Timed run
    auto t0 = std::chrono::high_resolution_clock::now();
    kernel<<<blocks, threads>>>(d_dummy, iters);
    cudaDeviceSynchronize();
    auto t1 = std::chrono::high_resolution_clock::now();

    double sec = std::chrono::duration<double>(t1 - t0).count();
    int warps = blocks * (threads / 32);
    long long total_ops = (long long)warps * iters * ops_per_iter;
    double tops = total_ops / sec / 1e12;

    printf("%s: %.3f s, %.2f T[FL]OPS (%.2f%% of peak)\n",
           name, sec, tops, 0.0);  // Peak percentage filled in by caller

    cudaFree(d_dummy);
    return tops;
}

int main() {
    print_device_info();

    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    int SMs = prop.multiProcessorCount;
    float clock_ghz = prop.clockRate / 1e6;

    // Launch config: maximize warp occupancy
    // Each SM can run up to 48 warps (1536 threads) on GA102
    // We use 32 warps per SM (1024 threads) for good occupancy
    int threads = 256;  // 8 warps per block
    int blocks = SMs * 4;  // 32 warps per SM total
    int iters = 10000000;

    printf("Launch config: %d blocks x %d threads = %d warps\n\n",
           blocks, threads, blocks * threads / 32);

    // Calculate theoretical peaks for this GPU
    float imma_peak = SMs * 4 * 256 * clock_ghz * 2 / 1000;
    float hmma_peak = imma_peak;
    float tf32_peak = imma_peak / 2;

    // ========================================================================
    // Test 1: IMMA (INT8 Tensor Cores)
    // m16n8k16: 16*8*16 = 2048 multiply-accumulates = 4096 INT8 ops per MMA
    // ========================================================================
    printf("=== IMMA INT8 Tensor Core Test ===\n");
    {
        int *d_dummy;
        cudaMalloc(&d_dummy, 4);

        // Warmup
        imma_m16n8k16_kernel<<<blocks, threads>>>(d_dummy, 1000);
        cudaDeviceSynchronize();

        auto t0 = std::chrono::high_resolution_clock::now();
        imma_m16n8k16_kernel<<<blocks, threads>>>(d_dummy, iters);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        int warps = blocks * (threads / 32);
        long long ops = (long long)warps * iters * 4096;  // 4096 ops per MMA
        double tops = ops / sec / 1e12;

        printf("  Time: %.3f s\n", sec);
        printf("  Throughput: %.2f TOPS\n", tops);
        printf("  Efficiency: %.1f%% of peak (%.1f TOPS)\n",
               tops / imma_peak * 100, imma_peak);
        printf("\n");

        cudaFree(d_dummy);
    }

    // ========================================================================
    // Test 2: HMMA (FP16 Tensor Cores)
    // m16n8k16: 16*8*16 = 2048 multiply-accumulates = 4096 FP16 ops per MMA
    // ========================================================================
    printf("=== HMMA FP16 Tensor Core Test ===\n");
    {
        int *d_dummy;
        cudaMalloc(&d_dummy, 4);

        // Warmup
        hmma_m16n8k16_kernel<<<blocks, threads>>>(d_dummy, 1000);
        cudaDeviceSynchronize();

        auto t0 = std::chrono::high_resolution_clock::now();
        hmma_m16n8k16_kernel<<<blocks, threads>>>(d_dummy, iters);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        int warps = blocks * (threads / 32);
        long long ops = (long long)warps * iters * 4096;
        double tflops = ops / sec / 1e12;

        printf("  Time: %.3f s\n", sec);
        printf("  Throughput: %.2f TFLOPS\n", tflops);
        printf("  Efficiency: %.1f%% of peak (%.1f TFLOPS)\n",
               tflops / hmma_peak * 100, hmma_peak);
        printf("\n");

        cudaFree(d_dummy);
    }

    // ========================================================================
    // Test 3: TF32 (TensorFloat-32)
    // m16n8k8: 16*8*8 = 1024 multiply-accumulates = 2048 ops per MMA
    // ========================================================================
    printf("=== TF32 Tensor Core Test ===\n");
    {
        int *d_dummy;
        cudaMalloc(&d_dummy, 4);

        // Warmup
        tf32_m16n8k8_kernel<<<blocks, threads>>>(d_dummy, 1000);
        cudaDeviceSynchronize();

        auto t0 = std::chrono::high_resolution_clock::now();
        tf32_m16n8k8_kernel<<<blocks, threads>>>(d_dummy, iters);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        int warps = blocks * (threads / 32);
        long long ops = (long long)warps * iters * 2048;  // 2048 ops per MMA
        double tflops = ops / sec / 1e12;

        printf("  Time: %.3f s\n", sec);
        printf("  Throughput: %.2f TFLOPS\n", tflops);
        printf("  Efficiency: %.1f%% of peak (%.1f TFLOPS)\n",
               tflops / tf32_peak * 100, tf32_peak);
        printf("\n");

        cudaFree(d_dummy);
    }

    // ========================================================================
    // Test 4: WMMA API (for comparison with PTX)
    // ========================================================================
    printf("=== WMMA FP16 API Test ===\n");
    {
        half *d_a, *d_b;
        float *d_c;
        cudaMalloc(&d_a, 16*16*sizeof(half));
        cudaMalloc(&d_b, 16*16*sizeof(half));
        cudaMalloc(&d_c, 16*16*sizeof(float));

        // Initialize with 1.0
        std::vector<half> ones(16*16, __float2half(1.0f));
        cudaMemcpy(d_a, ones.data(), 16*16*sizeof(half), cudaMemcpyHostToDevice);
        cudaMemcpy(d_b, ones.data(), 16*16*sizeof(half), cudaMemcpyHostToDevice);

        // WMMA uses 1 warp per 16x16x16 tile
        int wmma_blocks = SMs;
        int wmma_threads = 32;  // 1 warp

        // Warmup
        wmma_fp16_kernel<<<wmma_blocks, wmma_threads>>>(d_a, d_b, d_c, 1000);
        cudaDeviceSynchronize();

        auto t0 = std::chrono::high_resolution_clock::now();
        wmma_fp16_kernel<<<wmma_blocks, wmma_threads>>>(d_a, d_b, d_c, iters);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();

        double sec = std::chrono::duration<double>(t1 - t0).count();
        // 16x16x16 = 4096 multiply-adds = 8192 FP16 ops per MMA
        long long ops = (long long)wmma_blocks * iters * 8192;
        double tflops = ops / sec / 1e12;

        printf("  Time: %.3f s\n", sec);
        printf("  Throughput: %.2f TFLOPS\n", tflops);
        printf("  Note: Lower than PTX due to memory access overhead\n");
        printf("\n");

        cudaFree(d_a);
        cudaFree(d_b);
        cudaFree(d_c);
    }

    // ========================================================================
    // Summary
    // ========================================================================
    printf("=== Summary ===\n");
    printf("If Tensor Cores are ENABLED (SS0=0x88888888, SS1=0x00000008):\n");
    printf("  - IMMA should show >50%% efficiency (~100+ TOPS on 50 SMs)\n");
    printf("  - HMMA should show >50%% efficiency (~100+ TFLOPS on 50 SMs)\n");
    printf("  - TF32 should show >50%% efficiency (~50+ TFLOPS on 50 SMs)\n");
    printf("\n");
    printf("If Tensor Cores are THROTTLED (before unlock):\n");
    printf("  - IMMA will show ~7%% efficiency (1/13.4x, ~7 TOPS)\n");
    printf("  - HMMA/TF32 may show similar throttling\n");
    printf("\n");
    printf("SS0/SS1 control SM issue-rate modifiers in FEAT_OVR block:\n");
    printf("  - SS0 @ 0x0082381C: 0x88888888 = all speed selectors at FULL (8)\n");
    printf("  - SS1 @ 0x00823820: 0x00000008 = additional FULL selector\n");
    printf("  - Stock CMP 90HX: SS0=0x16122002, SS1=0x00000006 (throttled)\n");

    return 0;
}
