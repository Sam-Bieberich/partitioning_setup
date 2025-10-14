#!/bin/bash

# MIG-CPU Affinity REAL TEST Script
# This script runs actual CPU-intensive workloads and monitors which cores they use

CGROUP_BASE="/sys/fs/cgroup/mig"
TEST_DURATION=10  # seconds per test

echo "=== MIG-CPU Affinity Real Test ==="
echo ""
echo "This test will:"
echo "1. Launch CPU-intensive workloads on each MIG instance"
echo "2. Monitor which CPU cores are actually being used"
echo "3. Verify CPU isolation is working"
echo ""

# Check prerequisites
if [ ! -d "$CGROUP_BASE" ]; then
    echo "ERROR: MIG cgroups not found. Run setup_mig_cpu_affinity.sh first"
    exit 1
fi

if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 not found"
    exit 1
fi

# Show expected CPU assignments
echo "Expected CPU assignments:"
for i in {0..6}; do
    if [ -d "$CGROUP_BASE/mig$i" ]; then
        CPUS=$(cat "$CGROUP_BASE/mig$i/cpuset.cpus" 2>/dev/null)
        echo "  MIG $i: cores $CPUS"
    fi
done
echo ""

# Function to move process to cgroup
move_to_cgroup() {
    local pid=$1
    local mig=$2
    local max_attempts=20
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if [ -d "/proc/$pid" ]; then
            echo $pid | sudo tee "$CGROUP_BASE/mig$mig/cgroup.procs" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                return 0
            fi
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

# Test 1: Single MIG instance test
echo "=========================================="
echo "TEST 1: Single MIG Instance (MIG 0)"
echo "=========================================="
echo "Launching CPU-intensive workload on MIG 0 for $TEST_DURATION seconds..."
echo ""

python3 -c "
import multiprocessing as mp
import time
import os

def cpu_burner(n):
    '''Burn CPU cycles'''
    for _ in range(100000000):
        _ = sum(range(1000))

if __name__ == '__main__':
    print(f'Main PID: {os.getpid()}')
    print(f'Starting 10 CPU-intensive processes...')
    print(f'Duration: $TEST_DURATION seconds')
    print()
    
    start = time.time()
    with mp.Pool(10) as pool:
        result = pool.map_async(cpu_burner, range(10))
        
        # Monitor for a bit
        time.sleep(2)
        
        # Wait for completion or timeout
        try:
            result.get(timeout=$TEST_DURATION - 2)
        except:
            pass
    
    print(f'Test completed in {time.time() - start:.1f} seconds')
" &

TEST_PID=$!
sleep 0.5

# Move to MIG 0 cgroup
move_to_cgroup $TEST_PID 0

# Get child processes
sleep 1
CHILD_PIDS=$(pgrep -P $TEST_PID)

echo "Main PID: $TEST_PID"
echo "Child PIDs: $CHILD_PIDS"
echo ""

# Check which cores are being used
echo "Checking CPU affinity..."
AFFINITY=$(taskset -cp $TEST_PID 2>/dev/null | grep -oP "list: \K.*")
echo "Process CPU affinity: $AFFINITY"
echo ""

echo "Monitoring CPU usage for 3 seconds..."
echo "(You should see cores 0-9 at high usage, others idle)"
echo ""

# Sample CPU usage 3 times
for sample in {1..3}; do
    echo "Sample $sample:"
    # Show per-core CPU usage
    mpstat -P ALL 1 1 | grep -E "CPU|Average" | tail -n 10
    echo ""
done

# Wait for test to complete
wait $TEST_PID 2>/dev/null

echo "TEST 1 COMPLETED"
echo ""
sleep 2

# Test 2: Multiple MIG instances simultaneously
echo "=========================================="
echo "TEST 2: Multiple MIG Instances (0, 1, 2)"
echo "=========================================="
echo "Launching CPU-intensive workloads on MIG 0, 1, and 2 simultaneously..."
echo ""

PIDS=()

for mig_idx in 0 1 2; do
    python3 -c "
import time
import os

def cpu_burn():
    for _ in range(200000000):
        sum(range(1000))

print(f'MIG $mig_idx - PID: {os.getpid()}', flush=True)

# Spawn 8 threads burning CPU
import threading
threads = []
for i in range(8):
    t = threading.Thread(target=cpu_burn)
    t.start()
    threads.append(t)

for t in threads:
    t.join()

print(f'MIG $mig_idx - Completed', flush=True)
" &
    
    PID=$!
    PIDS+=($PID)
    echo "Started MIG $mig_idx workload (PID: $PID)"
    
    sleep 0.5
    move_to_cgroup $PID $mig_idx
    
    AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*")
    echo "  CPU affinity: $AFFINITY"
done

echo ""
echo "All workloads started. Monitoring CPU usage..."
echo ""
echo "Expected:"
echo "  Cores 0-9:   HIGH (MIG 0)"
echo "  Cores 10-19: HIGH (MIG 1)"
echo "  Cores 20-29: HIGH (MIG 2)"
echo "  Cores 30-71: IDLE"
echo ""

# Monitor for 5 seconds
for i in {1..5}; do
    echo "--- Sample $i/5 ---"
    mpstat -P ALL 1 1 | grep -E "CPU|Average" | tail -n 10
    echo ""
    sleep 1
done

# Wait for completion
echo "Waiting for workloads to complete..."
for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null
done

echo ""
echo "TEST 2 COMPLETED"
echo ""

# Summary
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""
echo "✓ If you saw cores 0-9 active in TEST 1, CPU partitioning is working!"
echo "✓ If you saw cores 0-9, 10-19, 20-29 active in TEST 2, isolation is working!"
echo ""
echo "To verify manually with htop:"
echo "  1. Run: htop"
echo "  2. Press 't' for tree view"
echo "  3. Launch: ./mig_launcher.sh 0 python -c 'while True: sum(range(10000000))'"
echo "  4. Watch which cores spike in htop"
echo ""
echo "If cores outside the assigned range show high usage, something is wrong."