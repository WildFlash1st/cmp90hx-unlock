#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <vector>

// cuBLAS GEMM test — uses Tensor Cores on GA102
int main() {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("Device: %s (CC %d.%d, %d SMs)\n", prop.name, prop.major, prop.minor, prop.multiProcessorCount);

    const int N = 4096;
    float *A, *B, *C;
    cudaMalloc(&A, N*N*sizeof(float));
    cudaMalloc(&B, N*N*sizeof(float));
    cudaMalloc(&C, N*N*sizeof(float));
    cudaMemset(A, 1, N*N*sizeof(float));
    cudaMemset(B, 1, N*N*sizeof(float));

    cublasHandle_t h;
    cublasCreate(&h);
    float alpha = 1.0f, beta = 0.0f;

    // Warmup
    cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, A, N, B, N, &beta, C, N);
    cudaDeviceSynchronize();

    // Timed runs
    const int ITERS = 10;
    double best = 1e18;
    for (int i = 0; i < ITERS; i++) {
        auto t0 = std::chrono::high_resolution_clock::now();
        cublasSgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &alpha, A, N, B, N, &beta, C, N);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (ms < best) best = ms;
    }

    double flops = 2.0 * N * N * N;
    double tflops = flops / (best / 1000.0) / 1e12;
    printf("SGEMM 4096^3: best %.2f ms = %.2f TFLOPS (FP32)\n", best, tflops);

    // FP16 tensor core test
    __half *hA, *hB, *hC;
    cudaMalloc(&hA, N*N*sizeof(__half));
    cudaMalloc(&hB, N*N*sizeof(__half));
    cudaMalloc(&hC, N*N*sizeof(__half));
    cudaMemset(hA, 0, N*N*sizeof(__half));
    cudaMemset(hB, 0, N*N*sizeof(__half));

    // Fill with 1.0 half
    std::vector<__half> ones(N*N, __float2half(1.0f));
    cudaMemcpy(hA, ones.data(), N*N*sizeof(__half), cudaMemcpyHostToDevice);
    cudaMemcpy(hB, ones.data(), N*N*sizeof(__half), cudaMemcpyHostToDevice);

    __half half_alpha = __float2half(1.0f), half_beta = __float2half(0.0f);
    best = 1e18;
    for (int i = 0; i < ITERS; i++) {
        auto t0 = std::chrono::high_resolution_clock::now();
        cublasHgemm(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &half_alpha, hA, N, hB, N, &half_beta, hC, N);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (ms < best) best = ms;
    }
    tflops = flops / (best / 1000.0) / 1e12;
    printf("HGEMM 4096^3: best %.2f ms = %.2f TFLOPS (FP16 tensor cores)\n", best, tflops);

    // Integer tensor core test (IMMA)
    // cublasGemmEx with CUDA_R_8I
    int8_t *iA, *iB, *iC;
    cudaMalloc(&iA, N*N);
    cudaMalloc(&iB, N*N);
    cudaMalloc(&iC, N*N*4);
    cudaMemset(iA, 1, N*N);
    cudaMemset(iB, 1, N*N);
    int int_alpha = 1, int_beta = 0;
    best = 1e18;
    for (int i = 0; i < ITERS; i++) {
        auto t0 = std::chrono::high_resolution_clock::now();
        cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, N, N, N, &int_alpha,
                     iA, CUDA_R_8I, N, iB, CUDA_R_8I, N, &int_beta,
                     iC, CUDA_R_32I, N, CUBLAS_COMPUTE_32I, CUBLAS_GEMM_DEFAULT_TENSOR_OP);
        cudaDeviceSynchronize();
        auto t1 = std::chrono::high_resolution_clock::now();
        double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
        if (ms < best) best = ms;
    }
    tflops = flops / (best / 1000.0) / 1e12;
    printf("IMMA 4096^3: best %.2f ms = %.2f TOPS (INT8 tensor cores)\n", best, tflops);

    return 0;
}
