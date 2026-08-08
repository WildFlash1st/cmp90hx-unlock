#include <cuda_runtime.h>
#include <cstdio>
#include <chrono>

// Independent FMA chains — proper throughput test
__global__ void fp32_throughput(float *out, int iters) {
    float x0 = threadIdx.x * 0.001f + 1.0f;
    float x1 = x0 + 1.0f, x2 = x1 + 1.0f, x3 = x2 + 1.0f;
    float x4 = x3 + 1.0f, x5 = x4 + 1.0f, x6 = x5 + 1.0f, x7 = x6 + 1.0f;
    float a = 0.5f, b = 0.25f, c = 0.125f, d = 0.0625f;
    float e = 0.5f, f = 0.25f, g = 0.125f, h = 0.0625f;
    float k = 1.000001f;
    // 8 independent chains to saturate FP32 units
    for (int i = 0; i < iters; i++) {
        a = fmaf(a, k, x0); b = fmaf(b, k, x1);
        c = fmaf(c, k, x2); d = fmaf(d, k, x3);
        e = fmaf(e, k, x4); f = fmaf(f, k, x5);
        g = fmaf(g, k, x6); h = fmaf(h, k, x7);
    }
    float acc = a+b+c+d+e+f+g+h;
    if (acc == 12345.0f) out[0] = acc;
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    int SMs = prop.multiProcessorCount;
    printf("Device: %s, %d SMs\n", prop.name, SMs);

    // Full occupancy: SMs * 1536 threads
    int threads = 512;
    int blocks = SMs * 3;  // 1536 threads/SM
    float *d_out;
    cudaMalloc(&d_out, 4);
    int iters = 20000000;

    // Warmup
    fp32_throughput<<<blocks, threads>>>(d_out, 1000);
    cudaDeviceSynchronize();

    auto t0 = std::chrono::high_resolution_clock::now();
    fp32_throughput<<<blocks, threads>>>(d_out, iters);
    cudaDeviceSynchronize();
    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();

    long total_fma = (long)blocks * threads * iters * 8;
    double tflops = total_fma * 2 / sec / 1e12;
    printf("FP32 throughput: %.3f s = %.2f TFLOPS\n", sec, tflops);
    printf("Theoretical (%d SM @ 1.8GHz): %.1f TFLOPS\n", SMs, SMs*128.0*2*1.8);
    printf("Efficiency: %.1f%%\n", tflops/(SMs*128.0*2*1.8)*100);
    return 0;
}
