#include <cuda_runtime.h>
#include <cstdio>
#include <chrono>

// Independent FMA chains — measure per-SM throughput
__global__ void fp32_sm_test(float *out, int iters) {
    float x0 = threadIdx.x * 0.001f + 1.0f;
    float a = 0.5f, b = 0.25f, c = 0.125f, d = 0.0625f;
    float k = 1.000001f;
    for (int i = 0; i < iters; i++) {
        a = fmaf(a, k, x0); b = fmaf(b, k, x0);
        c = fmaf(c, k, x0); d = fmaf(d, k, x0);
    }
    float acc = a+b+c+d;
    if (acc == 12345.0f) out[0] = acc;
}

double run_kernel(int blocks, int threads, int iters, cudaStream_t s) {
    float *d_out;
    cudaMalloc(&d_out, 4);
    fp32_sm_test<<<blocks, threads, 0, s>>>(d_out, 100);
    cudaDeviceSynchronize();
    auto t0 = std::chrono::high_resolution_clock::now();
    fp32_sm_test<<<blocks, threads, 0, s>>>(d_out, iters);
    cudaDeviceSynchronize();
    auto t1 = std::chrono::high_resolution_clock::now();
    cudaFree(d_out);
    return std::chrono::duration<double>(t1 - t0).count();
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    int SMs = prop.multiProcessorCount;
    printf("Device: %s, %d SMs reported\n", prop.name, SMs);

    int iters = 20000000;
    int threads = 512;

    // Test with increasing blocks to see throughput scaling
    for (int blocks : {1, 2, 4, 8, 16, 32, 50, 100, 150, 200}) {
        double sec = run_kernel(blocks, threads, iters, 0);
        long total_fma = (long)blocks * threads * iters * 4;
        double tflops = total_fma * 2 / sec / 1e12;
        printf("  blocks=%3d: %.2f s = %.2f TFLOPS\n", blocks, sec, tflops);
    }
    return 0;
}
