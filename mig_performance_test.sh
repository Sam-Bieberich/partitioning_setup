#!/bin/bash

# MIG Performance Benchmark Script
# Tests GEMM performance with and without CPU partitioning

set -e

echo "=== MIG Performance Benchmark ==="
echo ""

# Configuration
MATRIX_SIZE=4096
ITERATIONS=10
CGROUP_BASE="/sys/fs/cgroup/mig"

# Check if gemm_benchmark exists
if [ ! -f "./gemm_benchmark" ]; then
    echo "ERROR: gemm_benchmark executable not found"
    echo "Please compile it first:"
    echo "  nvcc gemm_benchmark.cu -o gemm_benchmark -lcublas -arch=sm_90"
    exit 1
fi

# Get MIG instances
echo "Detecting MIG instances..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))

if [ ${#MIG_UUIDS[@]} -eq 0 ]; then
    echo "ERROR: No MIG instances found"
    exit 1
fi

echo "Found ${#MIG_UUIDS[@]} MIG instances"
echo ""

# Test configuration
echo "Test Configuration:"
echo "  Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "  Iterations: ${ITERATIONS}"
echo ""

# Select which MIG instances to test
echo "Select test mode:"
echo "1. Single MIG test (MIG 0 only)"
echo "2. Compare MIG 0 vs MIG 1"
echo "3. Test all MIG instances"
read -p "Enter choice (1-3): " TEST_MODE

case $TEST_MODE in
    1)
        TEST_MIGS=(0)
        ;;
    2)
        TEST_MIGS=(0 1)
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
echo "TEST 1: WITHOUT CPU Partitioning"
echo "=========================================="
echo ""

# Results array
declare -A RESULTS_NO_PARTITION
declare -A RESULTS_WITH_PARTITION

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    
    echo "--- MIG $mig_idx ---"
    echo "UUID: $MIG_UUID"
    
    # Run without CPU partitioning (can use any cores)
    RESULT=$(CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS | grep "Performance:" | grep -oP '\d+\.\d+')
    RESULTS_NO_PARTITION[$mig_idx]=$RESULT
    
    echo "Performance: $RESULT GFLOPS"
    echo ""
    sleep 2
done

echo ""
echo "=========================================="
echo "TEST 2: WITH CPU Partitioning (cgroups)"
echo "=========================================="
echo ""

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    
    echo "--- MIG $mig_idx ---"
    echo "UUID: $MIG_UUID"
    echo "CPU Range: $CPU_RANGE"
    
    # Run with CPU partitioning
    CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS &
    PID=$!
    
    # Move to cgroup
    sleep 0.5
    echo $PID | sudo tee "$CGROUP_BASE/mig$mig_idx/cgroup.procs" > /dev/null
    
    # Verify CPU affinity
    AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*")
    echo "CPU Affinity: $AFFINITY"
    
    # Wait for completion and capture output
    wait $PID
    RESULT=$(CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS 2>&1 | grep "Performance:" | grep -oP '\d+\.\d+')
    
    # Actually run it properly to get result
    CUDA_VISIBLE_DEVICES=$MIG_UUID taskset -c $CPU_RANGE ./gemm_benchmark $MATRIX_SIZE $ITERATIONS > /tmp/mig_result_$mig_idx.txt 2>&1
    RESULT=$(grep "Performance:" /tmp/mig_result_$mig_idx.txt | grep -oP '\d+\.\d+')
    RESULTS_WITH_PARTITION[$mig_idx]=$RESULT
    
    echo "Performance: $RESULT GFLOPS"
    echo ""
    sleep 2
done

echo ""
echo "=========================================="
echo "TEST 3: Simultaneous Execution"
echo "=========================================="
echo ""
echo "Running all selected MIG instances simultaneously..."
echo ""

PIDS=()

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    
    echo "Starting MIG $mig_idx (CPUs: $CPU_RANGE)..."
    
    # Run in background
    CUDA_VISIBLE_DEVICES=$MIG_UUID taskset -c $CPU_RANGE ./gemm_benchmark $MATRIX_SIZE $ITERATIONS > /tmp/mig_concurrent_$mig_idx.txt 2>&1 &
    PID=$!
    PIDS+=($PID)
    
    # Move to cgroup
    sleep 0.5
    echo $PID | sudo tee "$CGROUP_BASE/mig$mig_idx/cgroup.procs" > /dev/null
done

echo "All workloads started. Waiting for completion..."
echo ""

# Wait for all
for pid in "${PIDS[@]}"; do
    wait $pid
done

# Collect results
declare -A RESULTS_CONCURRENT

for mig_idx in "${TEST_MIGS[@]}"; do
    RESULT=$(grep "Performance:" /tmp/mig_concurrent_$mig_idx.txt | grep -oP '\d+\.\d+')
    RESULTS_CONCURRENT[$mig_idx]=$RESULT
done

echo "Concurrent execution complete!"
echo ""

# Summary
echo "=========================================="
echo "RESULTS SUMMARY"
echo "=========================================="
echo ""
printf "%-10s %-20s %-20s %-20s %-15s\n" "MIG" "No Partition" "With Partition" "Concurrent" "Difference"
printf "%-10s %-20s %-20s %-20s %-15s\n" "---" "------------" "--------------" "----------" "----------"

for mig_idx in "${TEST_MIGS[@]}"; do
    NO_PART=${RESULTS_NO_PARTITION[$mig_idx]}
    WITH_PART=${RESULTS_WITH_PARTITION[$mig_idx]}
    CONCURRENT=${RESULTS_CONCURRENT[$mig_idx]}
    
    # Calculate percentage difference
    if [ ! -z "$NO_PART" ] && [ ! -z "$WITH_PART" ]; then
        DIFF=$(echo "scale=2; (($WITH_PART - $NO_PART) / $NO_PART) * 100" | bc)
    else
        DIFF="N/A"
    fi
    
    printf "%-10s %-20s %-20s %-20s %-15s\n" \
        "$mig_idx" \
        "${NO_PART} GFLOPS" \
        "${WITH_PART} GFLOPS" \
        "${CONCURRENT} GFLOPS" \
        "${DIFF}%"
done

echo ""
echo "=== Analysis ==="
echo ""
echo "✓ If 'With Partition' ≈ 'No Partition': CPU partitioning is NOT bottlenecking GPU"
echo "✓ If 'Concurrent' ≈ 'With Partition': MIG instances are properly isolated"
echo "✓ Small differences (<5%) are normal and expected"
echo "✗ Large differences (>10%) may indicate issues with the setup"
echo ""

# Cleanup
rm -f /tmp/mig_result_*.txt /tmp/mig_concurrent_*.txt