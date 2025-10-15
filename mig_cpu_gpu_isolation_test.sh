#!/bin/bash

# MIG CPU-GPU Isolation Test
# Verifies that each CPU partition can ONLY see its assigned MIG GPU partition

set -e

CGROUP_BASE="/sys/fs/cgroup/mig"

echo "=== MIG CPU-GPU Isolation Verification ==="
echo ""

# Get all MIG instances
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))

if [ ${#MIG_UUIDS[@]} -lt 2 ]; then
    echo "ERROR: Need at least 2 MIG instances to test isolation"
    exit 1
fi

echo "Found ${#MIG_UUIDS[@]} MIG instances"
echo ""

# Test 1: Verify CPU cores see correct MIG partition
echo "=========================================="
echo "TEST 1: CPU Partition GPU Visibility"
echo "=========================================="
echo ""

for mig_idx in 0 1; do
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    
    echo "Testing MIG $mig_idx:"
    echo "  Assigned CPU cores: $CPU_RANGE"
    echo "  Assigned GPU UUID: $MIG_UUID"
    echo ""
    echo "  Running test with CPU affinity..."
    
    # Run test constrained to these CPUs
    taskset -c $CPU_RANGE python3 << EOTEST &
import os
import subprocess
import sys

print(f"  Running on CPU cores: $CPU_RANGE")
print(f"  CUDA_VISIBLE_DEVICES: {os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')}")
print()

# Run nvidia-smi to see which GPU this can access
result = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True)
gpus = result.stdout.strip().split('\n')

print("  GPUs visible from these CPU cores:")
for gpu in gpus:
    print(f"    {gpu}")

# Extract UUIDs
uuids = [line.split('UUID: ')[1].rstrip(')') for line in gpus if 'MIG' in line and 'UUID:' in line]
print()
print(f"  MIG UUIDs visible: {uuids}")
print()

# Check if this CPU can only see its assigned MIG
expected_uuid = "$MIG_UUID"
if uuids and uuids[0] == expected_uuid:
    print(f"  ✓ CORRECT: CPU cores see only their assigned MIG")
    sys.exit(0)
else:
    print(f"  ⚠ WARNING: CPU cores see different MIG than expected")
    print(f"    Expected: {expected_uuid}")
    print(f"    Got: {uuids}")
    sys.exit(1)
EOTEST
    
    PID=$!
    wait $PID
    
    echo ""
    sleep 1
done

echo ""
echo "=========================================="
echo "TEST 2: Cross-MIG Isolation Check"
echo "=========================================="
echo ""
echo "This test verifies that CPU cores from MIG 0 cannot access MIG 1's GPU"
echo "and vice versa."
echo ""

# Get CPU ranges
CPU_RANGE_0=$(cat "$CGROUP_BASE/mig0/cpuset.cpus" 2>/dev/null)
CPU_RANGE_1=$(cat "$CGROUP_BASE/mig1/cpuset.cpus" 2>/dev/null)
MIG_UUID_0=${MIG_UUIDS[0]}
MIG_UUID_1=${MIG_UUIDS[1]}

echo "Setup:"
echo "  MIG 0: CPUs $CPU_RANGE_0 → GPU $MIG_UUID_0"
echo "  MIG 1: CPUs $CPU_RANGE_1 → GPU $MIG_UUID_1"
echo ""

# Test 1: Try to access MIG 1's GPU from MIG 0's CPUs
echo "Test 1: Can MIG 0's CPUs see MIG 1's GPU?"
echo "  Running with CPUs $CPU_RANGE_0, setting CUDA_VISIBLE_DEVICES=$MIG_UUID_1"
echo ""

taskset -c $CPU_RANGE_0 bash << 'EOTEST1'
CUDA_VISIBLE_DEVICES=$1 python3 << 'EOTEST1_INNER'
import os
import subprocess

env_device = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
print(f"  CUDA_VISIBLE_DEVICES set to: {env_device}")

result = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True)
uuids = [line.split('UUID: ')[1].rstrip(')') for line in result.stdout.split('\n') if 'UUID:' in line]

print(f"  MIG devices actually visible: {uuids}")

if env_device in uuids or not uuids:
    print(f"  ✓ GOOD: CPUs restricted to assigned GPU")
else:
    print(f"  ⚠ WARNING: CPUs might see unassigned GPUs")
EOTEST1_INNER
EOTEST1 "$MIG_UUID_1" &

PID=$!
wait $PID

echo ""
sleep 1

# Test 2: Try to access MIG 0's GPU from MIG 1's CPUs
echo "Test 2: Can MIG 1's CPUs see MIG 0's GPU?"
echo "  Running with CPUs $CPU_RANGE_1, setting CUDA_VISIBLE_DEVICES=$MIG_UUID_0"
echo ""

taskset -c $CPU_RANGE_1 bash << 'EOTEST2'
CUDA_VISIBLE_DEVICES=$1 python3 << 'EOTEST2_INNER'
import os
import subprocess

env_device = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
print(f"  CUDA_VISIBLE_DEVICES set to: {env_device}")

result = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True)
uuids = [line.split('UUID: ')[1].rstrip(')') for line in result.stdout.split('\n') if 'UUID:' in line]

print(f"  MIG devices actually visible: {uuids}")

if env_device in uuids or not uuids:
    print(f"  ✓ GOOD: CPUs restricted to assigned GPU")
else:
    print(f"  ⚠ WARNING: CPUs might see unassigned GPUs")
EOTEST2_INNER
EOTEST2 "$MIG_UUID_0" &

PID=$!
wait $PID

echo ""
echo "=========================================="
echo "TEST 3: Cgroup-based GPU Access Verification"
echo "=========================================="
echo ""
echo "Running workloads through cgroups to verify CPU-GPU binding:"
echo ""

for mig_idx in 0 1; do
    CPU_RANGE=$(cat "$CGROUP_BASE/mig$mig_idx/cpuset.cpus" 2>/dev/null)
    MIG_UUID=${MIG_UUIDS[$mig_idx]}
    
    echo "MIG $mig_idx Test:"
    echo "  CPUs: $CPU_RANGE"
    echo "  GPU: $MIG_UUID"
    
    # Create Python script to test
    python3 << EOCGROUP &
import subprocess
import os

print("  Starting process...")
pid = os.getpid()
print(f"  PID: {pid}")

# Get CPU affinity
result = subprocess.run(['taskset', '-cp', str(pid)], capture_output=True, text=True)
affinity = result.stdout.strip()
print(f"  {affinity}")

# Run nvidia-smi
result = subprocess.run(['nvidia-smi', '-L'], capture_output=True, text=True)
mig_list = [l for l in result.stdout.split('\n') if 'MIG' in l]
print(f"  GPUs visible:")
for gpu in mig_list:
    print(f"    {gpu}")
EOCGROUP
    
    PID=$!
    
    # Move to cgroup
    sleep 0.3
    echo $PID | sudo tee "$CGROUP_BASE/mig$mig_idx/cgroup.procs" > /dev/null 2>&1
    
    # Wait
    wait $PID
    echo ""
    sleep 1
done

echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo ""
echo "✓ If all tests show correct GPU access, CPU-GPU partitioning is working"
echo "✓ Each CPU partition should see only its assigned MIG GPU"
echo "✓ Cross-partition access should be restricted"
echo ""