#include <cuda_runtime.h>
#include <cublas_v2.h>
#include <iostream>
#include <vector>
#include <chrono>


// Set default precision type
using Real = float;                 // Change to double for double precision
#define GEMM cublasSgemm            // Change to cublasDgemm for double precision


double elapsed_sec(cudaEvent_t start, cudaEvent_t stop) {
    float ms = 0;
    cudaEventElapsedTime(&ms, start, stop);
    return ms / 1000.0;
}

int main() {
  int m = 4<<12, n = 4<<12, k = 4<<12;
  Real alpha = 1.0, beta = 0.0;
  std::vector<Real> h_A(m * k, 1.0), h_B(k * n, 2.0), h_C(m * n, 0.0);

  Real *d_A, *d_B, *d_C;
  cudaMalloc((void**)&d_A, m * k * sizeof(Real));
  cudaMalloc((void**)&d_B, k * n * sizeof(Real));
  cudaMalloc((void**)&d_C, m * n * sizeof(Real));
  cudaMemcpy(d_A, h_A.data(), m * k * sizeof(Real), cudaMemcpyHostToDevice);
  cudaMemcpy(d_B, h_B.data(), k * n * sizeof(Real), cudaMemcpyHostToDevice);

  cublasHandle_t handle;
  cublasCreate(&handle);

  cudaEvent_t start, stop;
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  cudaEventRecord(start);
  // GEMM: C = alpha*A*B + beta*C
  // A: (m x k)
  // B: (k x n)
  // C: (m x n)
  int iters = 3;
  for (int i = 0; i < iters; i++) {
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

  cudaMemcpy(h_C.data(), d_C, m * n * sizeof(Real), cudaMemcpyDeviceToHost);

  cublasDestroy(handle);
  cudaFree(d_A); cudaFree(d_B); cudaFree(d_C);

  // Compute and print FLOPS
  double flops = iters * 2.0 * m * n * k; // GEMM FLOPS formula
  double gflops = flops / seconds / 1e9;
  std::cout << "Achieved: " << gflops << " GFLOPS" << std::endl;
  std::cout << "C[0] = " << h_C[0] << std::endl;
  return 0;
}