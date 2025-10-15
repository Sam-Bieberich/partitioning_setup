#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <iostream>
#include <vector>
#include <chrono>

// From Cody

// Set default precision type
using Real = float; // Change to double for double precision
#define GEMM cublasSgemm // Change to cublasDgemm for double precision

double elapsed_sec(cudaEvent_t start, cudaEvent_t stop) {
    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);
    return ms / 1000.0;
}

int main(int argc, char** argv) {
    // Allow matrix size configuration
    int size = 4096; // Default: 4096x4096
    int iters = 10;  // Default: 10 iterations
    
    if (argc > 1) size = atoi(argv[1]);
    if (argc > 2) iters = atoi(argv[2]);
    
    int m = size, n = size, k = size;
    Real alpha = 1.0, beta = 0.0;
    
    std::cout << "=== GEMM Benchmark ===" << std::endl;
    std::cout << "Matrix size: " << m << "x" << n << "x" << k << std::endl;
    std::cout << "Iterations: " << iters << std::endl;
    std::cout << "Precision: " << (sizeof(Real) == 4 ? "Single (FP32)" : "Double (FP64)") << std::endl;
    
    // Check CUDA device
    int device;
    cudaGetDevice(&device);
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, device);
    std::cout << "GPU: " << prop.name << std::endl;
    std::cout << "Memory: " << prop.totalGlobalMem / (1024*1024) << " MB" << std::endl;
    std::cout << std::endl;
    
    // Allocate host memory
    std::vector<Real> h_A(m * k, 1.0);
    std::vector<Real> h_B(k * n, 2.0);
    std::vector<Real> h_C(m * n, 0.0);
    
    // Allocate device memory
    Real *d_A, *d_B, *d_C;
    cudaMalloc((void**)&d_A, m * k * sizeof(Real));
    cudaMalloc((void**)&d_B, k * n * sizeof(Real));
    cudaMalloc((void**)&d_C, m * n * sizeof(Real));
    
    // Copy data to device
    cudaMemcpy(d_A, h_A.data(), m * k * sizeof(Real), cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, h_B.data(), k * n * sizeof(Real), cudaMemcpyHostToDevice);
    
    // Create cuBLAS handle
    cublasHandle_t handle;
    cublasCreate(&handle);
    
    // Warmup run
    std::cout << "Warming up..." << std::endl;
    GEMM(handle, CUBLAS_OP_N, CUBLAS_OP_N,
         m, n, k, &alpha, d_A, m, d_B, k, &beta, d_C, m);
    cudaDeviceSynchronize();
    
    // Timed runs
    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    
    std::cout << "Running benchmark..." << std::endl;
    cudaEventRecord(start);
    
    for (int i = 0; i < iters; i++) {
        // GEMM: C = alpha*A*B + beta*C
        // A: (m x k), B: (k x n), C: (m x n)
        GEMM(
            handle,
            CUBLAS_OP_N, CUBLAS_OP_N, // no transpose for A and B
            m, n, k,
            &alpha,
            d_A, m,
            d_B, k,
            &beta,
            d_C, m
        );
    }
    
    cudaEventRecord(stop);
    cudaEventSynchronize(stop);
    
    double seconds = elapsed_sec(start, stop);
    
    // Copy result back
    cudaMemcpy(h_C.data(), d_C, m * n * sizeof(Real), cudaMemcpyDeviceToHost);
    
    // Compute and print FLOPS
    double flops = iters * 2.0 * m * n * k; // GEMM FLOPS formula
    double gflops = flops / seconds / 1e9;
    double avg_time_ms = (seconds / iters) * 1000.0;
    
    std::cout << std::endl;
    std::cout << "=== Results ===" << std::endl;
    std::cout << "Total time: " << seconds << " seconds" << std::endl;
    std::cout << "Avg time per iteration: " << avg_time_ms << " ms" << std::endl;
    std::cout << "Performance: " << gflops << " GFLOPS" << std::endl;
    std::cout << "Verification C[0] = " << h_C[0] << " (expected: " << (2.0 * k) << ")" << std::endl;
    
    // Cleanup
    cublasDestroy(handle);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    
    return 0;
}