#!/bin/bash
# test_mig_setup.sh
# Quick test to verify MIG+CPU+memory partitioning is working
# Usage: sudo ./test_mig_setup.sh [mig_instance_0-6]

MIG_IDX="${1:-0}"

if ! [[ "$MIG_IDX" =~ ^[0-6]$ ]]; then
    echo "Usage: sudo $0 [mig_instance_0-6]"
    echo "Testing MIG instance 0 by default"
    MIG_IDX=0
fi

echo "=== Testing MIG instance $MIG_IDX ==="
echo ""

# Get MIG UUID
MIG_UUID=$(nvidia-smi -L | grep "MIG" | sed -n "$((MIG_IDX + 1))p" | grep -oP 'UUID: \K[^)]+')
if [ -z "$MIG_UUID" ]; then
    echo "ERROR: Could not find MIG instance $MIG_IDX"
    exit 1
fi

echo "MIG UUID: $MIG_UUID"
echo ""

# Test 1: Check cgroup exists and has correct settings
CGROUP_PATH="/sys/fs/cgroup/mig/mig$MIG_IDX"
if [ ! -d "$CGROUP_PATH" ]; then
    echo "❌ FAIL: Cgroup $CGROUP_PATH not found"
    echo "   Run: sudo bash setup_mig_cpu_affinity.sh"
    exit 1
fi

echo "✓ Cgroup exists: $CGROUP_PATH"
CPUS=$(cat "$CGROUP_PATH/cpuset.cpus.effective")
MEMS=$(cat "$CGROUP_PATH/cpuset.mems.effective")
echo "  CPUs: $CPUS"
echo "  MEMs: $MEMS"
echo ""

# Test 2: Launch a process in the cgroup and verify GPU visibility
echo "Testing GPU visibility with CUDA_VISIBLE_DEVICES=$MIG_UUID..."
OUTPUT=$(sudo bash -c "echo \$\$ > $CGROUP_PATH/cgroup.procs; export CUDA_VISIBLE_DEVICES='$MIG_UUID'; nvidia-smi -L 2>&1")

# Count how many MIG devices are visible
MIG_COUNT=$(echo "$OUTPUT" | grep -c "MIG" || true)

if [ "$MIG_COUNT" -eq 1 ]; then
    echo "✓ PASS: Only 1 MIG device visible (correct isolation)"
    echo "$OUTPUT" | grep "MIG"
elif [ "$MIG_COUNT" -eq 7 ]; then
    echo "❌ FAIL: All 7 MIG devices visible (CUDA_VISIBLE_DEVICES not working)"
    echo "   This means GPU isolation is NOT working"
    echo ""
    echo "Expected: 1 MIG device"
    echo "Got: $MIG_COUNT MIG devices"
else
    echo "⚠️  WARNING: Unexpected number of MIG devices: $MIG_COUNT"
    echo "$OUTPUT"
fi
echo ""

# Test 3: Verify CPU affinity
echo "Testing CPU affinity..."
TEST_PID=$(sudo bash -c "echo \$\$ > $CGROUP_PATH/cgroup.procs; sleep 60 & echo \$!")
sleep 1
AFFINITY=$(taskset -pc $TEST_PID 2>/dev/null | grep -oP "list: \K.*" || echo "N/A")
sudo kill $TEST_PID 2>/dev/null || true

if [ "$AFFINITY" = "$CPUS" ]; then
    echo "✓ PASS: CPU affinity matches cgroup setting"
    echo "  Expected: $CPUS"
    echo "  Got: $AFFINITY"
else
    echo "❌ FAIL: CPU affinity mismatch"
    echo "  Expected: $CPUS"
    echo "  Got: $AFFINITY"
fi
echo ""

echo "=== Test Summary ==="
echo "Run the launcher script to start applications with full partitioning:"
echo "  sudo ./launch_on_mig.sh $MIG_IDX python my_script.py"
echo "  sudo ./launch_on_mig.sh $MIG_IDX --user alice jupyter notebook"
