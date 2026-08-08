#include <cuda_runtime.h>
#include <cstdio>
#include <chrono>

// INT32 compute test — measure if INT units work at full speed
__global__ void int32_kernel(int *out, int iters) {
    int a = threadIdx.x + blockIdx.x;
    int b = a * 7 + 1;
    int c = b * 13 + 3;
    int d = c * 17 + 5;
    for (int i = 0; i < iters; i++) {
        a = a * 3 + b;
        b = b * 5 + c;
        c = c * 7 + d;
        d = d * 11 + a;
    }
    if (a == 12345 && b == 54321) out[0] = a + b + c + d;
}

// FP32 with memory (bandwidth test) — different bottleneck
__global__ void fp32_mem_kernel(float *out, const float *in, int n, int iters) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    float acc = in[idx % 65536];
    for (int i = 0; i < iters; i++) {
        acc = fmaf(acc, 1.000001f, 0.5f);
    }
    if (idx < n) out[idx] = acc;
}

double time_kernel(void (*launch)(int,int,int), int blocks, int threads, int iters) {
    (void)launch; (void)blocks; (void)threads; (void)iters; return 0;
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Device: %s, %d SMs\n", prop.name, prop.multiProcessorCount);

    int iters = 20000000;
    int threads = 512;
    int blocks = 50 * 3; // full occupancy 3*512=1536 threads/SM
    int *d_out;
    cudaMalloc(&d_out, 4);

    // INT32
    int32_kernel<<<blocks, threads>>>(d_out, 1000);
    cudaDeviceSynchronize();
    auto t0 = std::chrono::high_resolution_clock::now();
    int32_kernel<<<blocks, threads>>>(d_out, iters);
    cudaDeviceSynchronize();
    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    long ops = (long)blocks * threads * iters * 4; // 4 INT ops per iter
    printf("INT32: %.3f s = %.2f GOPS\n", sec, ops/sec/1e9);

    // FP32 with memory access (reduce latency sensitivity)
    float *d_in, *d_out2;
    cudaMalloc(&d_in, 65536 * sizeof(float));
    cudaMalloc(&d_out2, blocks*threads*sizeof(float));
    cudaMemset(d_in, 1, 65536 * sizeof(float));
    fp32_mem_kernel<<<blocks, threads>>>(d_out2, d_in, blocks*threads, 1000);
    cudaDeviceSynchronize();
    auto s0 = std::chrono::high_resolution_clock::now();
    fp32_mem_kernel<<<blocks, threads>>>(d_out2, d_in, blocks*threads, iters);
    cudaDeviceSynchronize();
    auto s1 = std::chrono::high_resolution_clock::now();
    sec = std::chrono::duration<double>(s1 - s0).count();
    long flops = (long)blocks * threads * iters * 2;
    printf("FP32+mem: %.3f s = %.2f TFLOPS\n", sec, flops/sec/1e12);

    cudaFree(d_out); cudaFree(d_in); cudaFree(d_out2);
    return 0;
}
