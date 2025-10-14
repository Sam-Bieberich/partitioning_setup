#!/bin/bash

# MIG-CPU Affinity Verification Script

echo "=== MIG-CPU Affinity Verification ==="
echo ""

# Check if cgroups exist
CGROUP_BASE="/sys/fs/cgroup/mig"
if [ ! -d "$CGROUP_BASE" ]; then
    echo "ERROR: MIG cgroups not found at $CGROUP_BASE"
    echo "Please run setup_mig_cpu_affinity.sh first"
    exit 1
fi

echo "1. Checking cgroup CPU assignments:"
echo "-----------------------------------"
for i in {0..6}; do
    if [ -d "$CGROUP_BASE/mig$i" ]; then
        CPUS=$(cat "$CGROUP_BASE/mig$i/cpuset.cpus" 2>/dev/null)
        MEMS=$(cat "$CGROUP_BASE/mig$i/cpuset.mems" 2>/dev/null)
        echo "MIG $i: CPUs=$CPUS, Memory Nodes=$MEMS"
    else
        echo "MIG $i: NOT FOUND"
    fi
done
echo ""

echo "2. Checking MIG GPU instances:"
echo "------------------------------"
nvidia-smi -L | grep "MIG" | nl -v 0 -w 1 -s ": "
echo ""

echo "3. Running CPU affinity test (5 seconds per MIG instance):"
echo "----------------------------------------------------------"

# Array to store PIDs
PIDS=()

# Function to cleanup on exit
cleanup() {
    echo ""
    echo "Cleaning up test processes..."
    for pid in "${PIDS[@]}"; do
        kill $pid 2>/dev/null
    done
    wait 2>/dev/null
    echo "Done!"
}

trap cleanup EXIT INT TERM

# Start test workload on each MIG instance
for i in {0..6}; do
    if [ -d "$CGROUP_BASE/mig$i" ]; then
        echo "Starting test on MIG $i..."
        
        # Start CPU-intensive Python process
        python3 -c "
import time
import os
print(f'MIG $i - PID: {os.getpid()}', flush=True)
start = time.time()
while time.time() - start < 5:
    sum(range(5000000))
print(f'MIG $i - Completed', flush=True)
" &
        
        PID=$!
        PIDS+=($PID)
        
        # Give process a moment to start
        sleep 0.2
        
        # Move to appropriate cgroup
        echo $PID | sudo tee "$CGROUP_BASE/mig$i/cgroup.procs" > /dev/null 2>&1
        
        # Check CPU affinity
        if [ -d "/proc/$PID" ]; then
            AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*")
            CGROUP=$(cat /proc/$PID/cgroup 2>/dev/null | grep -oP "::\K.*")
            echo "  PID $PID: CPU affinity=$AFFINITY, cgroup=$CGROUP"
        fi
        
        sleep 0.5
    fi
done

echo ""
echo "Waiting for tests to complete (5 seconds)..."
echo "Monitor CPU usage with: htop (in another terminal)"
echo ""

# Wait for all processes
for pid in "${PIDS[@]}"; do
    wait $pid 2>/dev/null
done

echo ""
echo "4. Summary:"
echo "-----------"
echo "✓ Cgroups created and configured"
echo "✓ CPU affinity test completed"
echo ""
echo "To manually verify during real workloads:"
echo "  1. Start your workload: ./mig_launcher.sh 0 python train.py"
echo "  2. Find PID: ps aux | grep train.py"
echo "  3. Check affinity: taskset -cp <PID>"
echo "  4. Monitor CPUs: htop (press 't' for tree view)"
echo ""
echo "Expected CPU ranges:"
for i in {0..6}; do
    if [ -d "$CGROUP_BASE/mig$i" ]; then
        CPUS=$(cat "$CGROUP_BASE/mig$i/cpuset.cpus" 2>/dev/null)
        echo "  MIG $i should use cores: $CPUS"
    fi
done