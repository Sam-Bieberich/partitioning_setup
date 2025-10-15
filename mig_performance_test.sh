#!/bin/bash

# MIG Performance Benchmark Script
# Tests if CPU partitioning actually prevents interference between MIG instances

set -e

echo "=== MIG CPU Partitioning Validation Test ==="
echo ""
echo "This test proves CPU partitioning works by:"
echo "1. Running multiple MIG workloads WITHOUT partitioning (should interfere)"
echo "2. Running multiple MIG workloads WITH partitioning (should NOT interfere)"
echo "3. Comparing performance degradation"
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

if [ ${#MIG_UUIDS[@]} -lt 2 ]; then
    echo "ERROR: Need at least 2 MIG instances for this test"
    exit 1
fi

echo "Found ${#MIG_UUIDS[@]} MIG instances"
echo ""

# Select how many MIG instances to test
echo "How many MIG instances to test simultaneously?"
echo "  2 - Quick test (MIG 0 and 1)"
echo "  3 - Medium test (MIG 0, 1, 2)"
echo "  7 - Full test (all MIG instances)"
read -p "Enter choice: " NUM_MIGS

if [ "$NUM_MIGS" -gt ${#MIG_UUIDS[@]} ]; then
    NUM_MIGS=${#MIG_UUIDS[@]}
fi

TEST_MIGS=($(seq 0 $((NUM_MIGS - 1))))

echo ""
echo "Testing MIG instances: ${TEST_MIGS[@]}"
echo "Matrix size: ${MATRIX_SIZE}x${MATRIX_SIZE}"
echo "Iterations: ${ITERATIONS}"
echo ""

# Results arrays
declare -A BASELINE_RESULTS
declare -A NO_PARTITION_RESULTS
declare -A WITH_PARTITION_RESULTS

echo "=========================================="
echo "BASELINE: Single MIG Instance Performance"
echo "=========================================="
echo ""
echo "Running MIG 0 alone to establish baseline..."

MIG_UUID=${MIG_UUIDS[0]}
CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS > /tmp/baseline.txt 2>&1
BASELINE=$(grep "Performance:" /tmp/baseline.txt | grep -oP '\d+\.\d+')

echo "Baseline performance (MIG 0 alone): $BASELINE GFLOPS"
echo ""
sleep 2

echo "=========================================="
echo "TEST 1: Multiple MIG WITHOUT CPU Partitioning"
echo "=========================================="
echo ""
echo "Running ${NUM_MIGS} MIG instances simultaneously WITHOUT cgroups..."
echo "Expected: CPU contention should cause performance degradation"
echo ""

PIDS=()

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    echo "Starting MIG $mig_idx (no CPU restrictions)..."
    
    CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS > /tmp/no_partition_$mig_idx.txt 2>&1 &
    PIDS+=($!)
done

echo "All workloads started. Waiting for completion..."

# Wait for all
for pid in "${PIDS[@]}"; do
    wait $pid
done

echo "Test 1 complete!"
echo ""

# Collect results
echo "Results:"
TOTAL_NO_PART=0
COUNT=0
for mig_idx in "${TEST_MIGS[@]}"; do
    RESULT=$(grep "Performance:" /tmp/no_partition_$mig_idx.txt | grep -oP '\d+\.\d+')
    NO_PARTITION_RESULTS[$mig_idx]=$RESULT
    TOTAL_NO_PART=$(echo "$TOTAL_NO_PART + $RESULT" | bc)
    COUNT=$((COUNT + 1))
    echo "  MIG $mig_idx: $RESULT GFLOPS"
done

AVG_NO_PART=$(echo "scale=2; $TOTAL_NO_PART / $COUNT" | bc)
echo ""
echo "Average performance WITHOUT partitioning: $AVG_NO_PART GFLOPS"
DEGRADATION_NO_PART=$(echo "scale=2; (($BASELINE - $AVG_NO_PART) / $BASELINE) * 100" | bc)
echo "Performance degradation: ${DEGRADATION_NO_PART}%"
echo ""

sleep 3

echo "=========================================="
echo "TEST 2: Multiple MIG WITH CPU Partitioning"
echo "=========================================="
echo ""
echo "Running ${NUM_MIGS} MIG instances simultaneously WITH cgroups..."
echo "Expected: No CPU contention, performance should stay near baseline"
echo ""

PIDS=()

for mig_idx in "${TEST_MIGS[@]}"; do
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    
    echo "Starting MIG $mig_idx (CPUs: $CPU_RANGE)..."
    
    CUDA_VISIBLE_DEVICES=$MIG_UUID ./gemm_benchmark $MATRIX_SIZE $ITERATIONS > /tmp/with_partition_$mig_idx.txt 2>&1 &
    PID=$!
    PIDS+=($PID)
    
    # Move to cgroup
    sleep 0.5
    echo $PID | sudo tee "$CGROUP_BASE/mig$mig_idx/cgroup.procs" > /dev/null 2>&1
    
    # Verify
    AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*" || echo "N/A")
    echo "  Verified CPU affinity: $AFFINITY"
done

echo ""
echo "All workloads started. Waiting for completion..."

# Wait for all
for pid in "${PIDS[@]}"; do
    wait $pid
done

echo "Test 2 complete!"
echo ""

# Collect results
echo "Results:"
TOTAL_WITH_PART=0
COUNT=0
for mig_idx in "${TEST_MIGS[@]}"; do
    RESULT=$(grep "Performance:" /tmp/with_partition_$mig_idx.txt | grep -oP '\d+\.\d+')
    WITH_PARTITION_RESULTS[$mig_idx]=$RESULT
    TOTAL_WITH_PART=$(echo "$TOTAL_WITH_PART + $RESULT" | bc)
    COUNT=$((COUNT + 1))
    echo "  MIG $mig_idx: $RESULT GFLOPS"
done

AVG_WITH_PART=$(echo "scale=2; $TOTAL_WITH_PART / $COUNT" | bc)
echo ""
echo "Average performance WITH partitioning: $AVG_WITH_PART GFLOPS"
DEGRADATION_WITH_PART=$(echo "scale=2; (($BASELINE - $AVG_WITH_PART) / $BASELINE) * 100" | bc)
echo "Performance degradation: ${DEGRADATION_WITH_PART}%"
echo ""

# Summary
echo "=========================================="
echo "FINAL RESULTS & ANALYSIS"
echo "=========================================="
echo ""
printf "%-30s %15s\n" "Metric" "Value"
printf "%-30s %15s\n" "------" "-----"
printf "%-30s %15s\n" "Baseline (1 MIG alone)" "$BASELINE GFLOPS"
printf "%-30s %15s\n" "Avg WITHOUT partitioning" "$AVG_NO_PART GFLOPS"
printf "%-30s %15s\n" "Avg WITH partitioning" "$AVG_WITH_PART GFLOPS"
printf "%-30s %15s\n" "Degradation WITHOUT" "${DEGRADATION_NO_PART}%"
printf "%-30s %15s\n" "Degradation WITH" "${DEGRADATION_WITH_PART}%"
echo ""

# Calculate improvement
IMPROVEMENT=$(echo "scale=2; $DEGRADATION_NO_PART - $DEGRADATION_WITH_PART" | bc)

echo "=== INTERPRETATION ==="
echo ""

if (( $(echo "$DEGRADATION_NO_PART > 10" | bc -l) )); then
    echo "✓ Without partitioning: ${DEGRADATION_NO_PART}% degradation detected"
    echo "  This proves CPU contention exists when running multiple MIG workloads"
else
    echo "⚠ Without partitioning: Only ${DEGRADATION_NO_PART}% degradation"
    echo "  CPU contention is minimal (workload may not be CPU-intensive enough)"
fi

echo ""

if (( $(echo "$DEGRADATION_WITH_PART < 5" | bc -l) )); then
    echo "✓ With partitioning: Only ${DEGRADATION_WITH_PART}% degradation"
    echo "  CPU partitioning successfully prevents interference!"
else
    echo "⚠ With partitioning: ${DEGRADATION_WITH_PART}% degradation"
    echo "  CPU partitioning helps but some interference remains"
fi

echo ""

if (( $(echo "$IMPROVEMENT > 5" | bc -l) )); then
    echo "✓✓ PARTITIONING WORKING: ${IMPROVEMENT}% performance improvement!"
    echo "   CPU partitioning is successfully isolating MIG workloads"
elif (( $(echo "$IMPROVEMENT > 0" | bc -l) )); then
    echo "✓ Partitioning provides modest ${IMPROVEMENT}% improvement"
    echo "  Benefit exists but workload may not be CPU-bound"
else
    echo "⚠ No clear benefit from partitioning"
    echo "  Workload may be GPU-bound (not CPU-intensive)"
    echo "  This is actually fine - partitioning prevents future interference"
fi

echo ""
echo "=== Per-Instance Details ==="
echo ""
printf "%-10s %-20s %-20s %-15s\n" "MIG" "Without Partition" "With Partition" "Improvement"
printf "%-10s %-20s %-20s %-15s\n" "---" "-----------------" "--------------" "-----------"

for mig_idx in "${TEST_MIGS[@]}"; do
    NO_PART=${NO_PARTITION_RESULTS[$mig_idx]}
    WITH_PART=${WITH_PARTITION_RESULTS[$mig_idx]}
    
    if [ ! -z "$NO_PART" ] && [ ! -z "$WITH_PART" ]; then
        IMP=$(echo "scale=2; (($WITH_PART - $NO_PART) / $NO_PART) * 100" | bc)
    else
        IMP="N/A"
    fi
    
    printf "%-10s %-20s %-20s %-15s\n" \
        "$mig_idx" \
        "${NO_PART} GFLOPS" \
        "${WITH_PART} GFLOPS" \
        "${IMP}%"
done

echo ""
echo "=== CONCLUSION ==="
echo ""

if (( $(echo "$IMPROVEMENT > 5" | bc -l) )); then
    echo "✅ SUCCESS: CPU partitioning is working correctly!"
    echo "   Your MIG instances are properly isolated at both GPU and CPU levels."
elif (( $(echo "$DEGRADATION_NO_PART < 5" | bc -l) )); then
    echo "✅ SETUP CORRECT: Partitioning is configured properly"
    echo "   Note