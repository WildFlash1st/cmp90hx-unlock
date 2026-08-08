#include <cuda_runtime.h>
#include <cstdio>
#include <chrono>

__global__ void copy_kernel(float *dst, const float *src, int n) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) dst[idx] = src[idx];
}

int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Device: %s, %d SMs\n", prop.name, prop.multiProcessorCount);
    printf("Mem clock: %d MHz\n", prop.memoryClockRate / 1000);
    printf("Mem bus: %d bits\n", prop.memoryBusWidth);

    // Memory bandwidth test: 1GB copy
    int n = 256 * 1024 * 1024; // 1GB floats
    float *d_src, *d_dst;
    cudaMalloc(&d_src, n * sizeof(float));
    cudaMalloc(&d_dst, n * sizeof(float));
    cudaMemset(d_src, 1, n * sizeof(float));

    copy_kernel<<<n/1024, 1024>>>(d_dst, d_src, n);
    cudaDeviceSynchronize();

    const int ITERS = 10;
    double best = 1e18;
    for (int i = 0; i < ITERS; i++) {
        auto t0 = std::chrono::high_resolution_clock::now();
        copy_kernel<<<n/1024, 1024>>>(d_dst, d_src, n);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (ms < best) best = ms;
    }

    double bytes = (double)n * sizeof(float) * 2; // read + write
    double gbps = bytes / (best / 1000.0) / 1e9;
    printf("Memory copy 1GB: %.2f ms = %.2f GB/s\n", best, gbps);
    printf("RTX 3080 reference: ~760 GB/s (19 Gbps GDDR6X)\n");
    return 0;
}
