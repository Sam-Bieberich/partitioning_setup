#!/bin/bash

# MIG GPU+CPU Integration Test (Simple CUDA version)
# Tests that each MIG partition works with its assigned CPU cores

CGROUP_BASE="/sys/fs/cgroup/mig"
TEST_DURATION=15  # seconds

echo "=== MIG GPU+CPU Integration Test (CUDA) ==="
echo ""

# Check prerequisites
if ! command -v nvidia-smi &> /dev/null; then
    echo "ERROR: nvidia-smi not found"
    exit 1
fi

if ! command -v nvcc &> /dev/null; then
    echo "WARNING: nvcc not found. Will use nvidia-smi for GPU stress instead."
    USE_CUDA_SAMPLE=false
else
    USE_CUDA_SAMPLE=true
fi

# Get MIG UUIDs
echo "Detecting MIG instances..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))

if [ ${#MIG_UUIDS[@]} -eq 0 ]; then
    echo "ERROR: No MIG instances found"
    echo "Run: nvidia-smi -L"
    exit 1
fi

echo "Found ${#MIG_UUIDS[@]} MIG instances"
echo ""

# Show CPU assignments
echo "CPU-GPU Mapping:"
for i in $(seq 0 $((${#MIG_UUIDS[@]} - 1))); do
    if [ -d "$CGROUP_BASE/mig$i" ]; then
        CPUS=$(cat "$CGROUP_BASE/mig$i/cpuset.cpus" 2>/dev/null)
        echo "  MIG $i: CPUs=$CPUS, GPU=${MIG_UUIDS[$i]}"
    fi
done
echo ""

# Function to move process to cgroup
move_to_cgroup() {
    local pid=$1
    local mig=$2
    local max_attempts=20
    
    for attempt in $(seq 1 $max_attempts); do
        if [ -d "/proc/$pid" ]; then
            echo $pid | sudo tee "$CGROUP_BASE/mig$mig/cgroup.procs" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                return 0
            fi
        fi
        sleep 0.1
    done
    return 1
}

# Create simple CUDA test program
create_cuda_test() {
    cat > /tmp/cuda_stress_test.cu << 'EOF'
#include <stdio.h>
#include <cuda_runtime.h>
#include <time.h>

__global__ void matrixMul(float *C, float *A, float *B, int N) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (row < N && col < N) {
        float sum = 0.0f;
        for (int k = 0; k < N; k++) {
            sum += A[row * N + k] * B[k * N + col];
        }
        C[row * N + col] = sum;
    }
}

int main(int argc, char **argv) {
    int duration = 15; // seconds
    if (argc > 1) {
        duration = atoi(argv[1]);
    }
    
    int N = 1024;
    size_t size = N * N * sizeof(float);
    
    float *h_A, *h_B, *h_C;
    float *d_A, *d_B, *d_C;
    
    // Allocate host memory
    h_A = (float*)malloc(size);
    h_B = (float*)malloc(size);
    h_C = (float*)malloc(size);
    
    // Initialize matrices
    for (int i = 0; i < N * N; i++) {
        h_A[i] = rand() / (float)RAND_MAX;
        h_B[i] = rand() / (float)RAND_MAX;
    }
    
    // Allocate device memory
    cudaMalloc(&d_A, size);
    cudaMalloc(&d_B, size);
    cudaMalloc(&d_C, size);
    
    // Copy to device
    cudaMemcpy(d_A, h_A, size, cudaMemcpyHostToDevice);
    cudaMemcpy(d_B, h_B, size, cudaMemcpyHostToDevice);
    
    dim3 threadsPerBlock(16, 16);
    dim3 blocksPerGrid((N + 15) / 16, (N + 15) / 16);
    
    printf("Running CUDA matrix multiplication for %d seconds...\n", duration);
    fflush(stdout);
    
    time_t start_time = time(NULL);
    int iterations = 0;
    
    while (time(NULL) - start_time < duration) {
        matrixMul<<<blocksPerGrid, threadsPerBlock>>>(d_C, d_A, d_B, N);
        cudaDeviceSynchronize();
        iterations++;
    }
    
    printf("Completed %d iterations\n", iterations);
    
    // Cleanup
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
    free(h_A);
    free(h_B);
    free(h_C);
    
    return 0;
}
EOF

    # Compile CUDA program
    nvcc /tmp/cuda_stress_test.cu -o /tmp/cuda_stress_test 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✓ CUDA test program compiled successfully"
        return 0
    else
        echo "✗ Failed to compile CUDA program"
        return 1
    fi
}

# Prepare CUDA test if nvcc available
if [ "$USE_CUDA_SAMPLE" = true ]; then
    echo "Compiling CUDA test program..."
    if ! create_cuda_test; then
        USE_CUDA_SAMPLE=false
        echo "Falling back to Python-based GPU test"
    fi
    echo ""
fi

# Test selection
echo "Select test:"
echo "1. Single MIG instance test (MIG 0)"
echo "2. Multiple MIG instances test (MIG 0, 1, 2)"
echo "3. All MIG instances test"
read -p "Enter choice (1-3): " CHOICE

case $CHOICE in
    1)
        TEST_MIGS=(0)
        ;;
    2)
        TEST_MIGS=(0 1 2)
        ;;
    3)
        TEST_MIGS=($(seq 0 $((${#MIG_UUIDS[@]} - 1))))
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "Starting GPU+CPU Test"
echo "=========================================="
echo ""

PIDS=()

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    
    echo "Launching test on MIG $mig_idx..."
    echo "  GPU UUID: $MIG_UUID"
    echo "  CPU Range: $CPU_RANGE"
    
    if [ "$USE_CUDA_SAMPLE" = true ]; then
        # Use compiled CUDA program with CPU stress
        (
            export CUDA_VISIBLE_DEVICES=$MIG_UUID
            
            # Run CUDA stress test
            /tmp/cuda_stress_test $TEST_DURATION &
            CUDA_PID=$!
            
            # Run CPU stress in parallel
            python3 -c "
import time
import threading
import hashlib

def cpu_burn():
    end_time = time.time() + $TEST_DURATION
    counter = 0
    while time.time() < end_time:
        data = str(counter).encode()
        for _ in range(5000):
            hashlib.sha256(data).hexdigest()
        counter += 1

threads = []
for i in range(8):
    t = threading.Thread(target=cpu_burn)
    t.start()
    threads.append(t)

for t in threads:
    t.join()
" &
            CPU_PID=$!
            
            # Wait for both
            wait $CUDA_PID
            wait $CPU_PID
        ) &
        
        PID=$!
    else
        # Fallback: Use Python with numba or just CPU
        CUDA_VISIBLE_DEVICES=$MIG_UUID python3 -c "
import os
import time
import threading
import hashlib

print(f'MIG $mig_idx - PID: {os.getpid()}', flush=True)

# Try to use numba for GPU if available
try:
    from numba import cuda
    import numpy as np
    HAS_NUMBA = True
    print(f'MIG $mig_idx - Using Numba CUDA', flush=True)
except ImportError:
    HAS_NUMBA = False
    print(f'MIG $mig_idx - No GPU library, using CPU stress only', flush=True)

def cpu_burn():
    end_time = time.time() + $TEST_DURATION
    counter = 0
    while time.time() < end_time:
        data = str(counter).encode()
        for _ in range(5000):
            hashlib.sha256(data).hexdigest()
        counter += 1

def gpu_compute_numba():
    @cuda.jit
    def matmul(A, B, C):
        row, col = cuda.grid(2)
        if row < C.shape[0] and col < C.shape[1]:
            tmp = 0.
            for k in range(A.shape[1]):
                tmp += A[row, k] * B[k, col]
            C[row, col] = tmp
    
    end_time = time.time() + $TEST_DURATION
    N = 1024
    
    while time.time() < end_time:
        A = np.random.rand(N, N).astype(np.float32)
        B = np.random.rand(N, N).astype(np.float32)
        C = np.zeros((N, N), dtype=np.float32)
        
        d_A = cuda.to_device(A)
        d_B = cuda.to_device(B)
        d_C = cuda.to_device(C)
        
        threadsperblock = (16, 16)
        blockspergrid_x = (N + threadsperblock[0] - 1) // threadsperblock[0]
        blockspergrid_y = (N + threadsperblock[1] - 1) // threadsperblock[1]
        blockspergrid = (blockspergrid_x, blockspergrid_y)
        
        matmul[blockspergrid, threadsperblock](d_A, d_B, d_C)
        cuda.synchronize()

# Start CPU threads
cpu_threads = []
for i in range(8):
    t = threading.Thread(target=cpu_burn)
    t.start()
    cpu_threads.append(t)

# Start GPU thread if available
if HAS_NUMBA:
    gpu_thread = threading.Thread(target=gpu_compute_numba)
    gpu_thread.start()

# Wait for completion
for t in cpu_threads:
    t.join()

if HAS_NUMBA:
    gpu_thread.join()

print(f'MIG $mig_idx - Completed', flush=True)
" &
        
        PID=$!
    fi
    
    PIDS+=($PID)
    
    # Give process time to start
    sleep 1
    
    # Move to cgroup
    move_to_cgroup $PID $mig_idx
    
    # Verify placement
    ACTUAL_AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*")
    ACTUAL_CGROUP=$(cat /proc/$PID/cgroup 2>/dev/null | grep -oP "::\K.*")
    
    echo "  PID: $PID"
    echo "  CPU Affinity: $ACTUAL_AFFINITY"
    echo "  Cgroup: $ACTUAL_CGROUP"
    echo ""
    
    sleep 1
done

echo "All workloads started!"
echo ""
echo "Expected CPU usage:"
for mig_idx in "${TEST_MIGS[@]}"; do
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    echo "  MIG $mig_idx: cores $CPU_RANGE should be active"
done
echo ""

# Monitor GPU usage
echo "Monitoring GPU usage..."
echo ""
for i in $(seq 1 $((TEST_DURATION / 2))); do
    echo "=== Sample $i/$((TEST_DURATION / 2)) ==="
    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>/dev/null
    echo ""
    sleep 2
done

echo "Waiting for tests to complete..."
for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null
done

# Cleanup
rm -f /tmp/cuda_stress_test /tmp/cuda_stress_test.cu

echo ""
echo "=========================================="
echo "Test Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "✓ Check if GPU utilization was shown for active MIG instances"
echo "✓ Check if assigned CPU cores were at high usage (use htop)"
echo ""
echo "To verify CPU isolation, run htop in another session:"
echo "  htop"
echo "  Press '1' to show individual cores"
echo "  Press 't' for tree view"