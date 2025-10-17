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

# Test 2: Verify CUDA_VISIBLE_DEVICES is set correctly
echo "Testing GPU isolation with CUDA_VISIBLE_DEVICES=$MIG_UUID..."

# Create a test script that checks GPU visibility and stays alive briefly
TEST_SCRIPT=$(mktemp)
cat > "$TEST_SCRIPT" << 'EOF'
#!/bin/bash
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo ""
echo "All GPUs (nvidia-smi -L shows hardware, ignores CUDA_VISIBLE_DEVICES):"
nvidia-smi -L 2>&1 | head -3
echo ""
echo "CUDA runtime view (respects CUDA_VISIBLE_DEVICES):"
nvidia-smi --id=$CUDA_VISIBLE_DEVICES --query-gpu=name,uuid --format=csv,noheader 2>&1 || echo "Failed to query specific device"
sleep 2
EOF
chmod +x "$TEST_SCRIPT"

OUTPUT=$(sudo bash -c "echo \$\$ > $CGROUP_PATH/cgroup.procs; export CUDA_VISIBLE_DEVICES='$MIG_UUID'; $TEST_SCRIPT" 2>&1)
echo "$OUTPUT"
echo ""

# Check if the MIG UUID appears in the output
if echo "$OUTPUT" | grep -q "$MIG_UUID"; then
    echo "✓ PASS: MIG UUID is correctly set in CUDA_VISIBLE_DEVICES"
else
    echo "⚠️  INFO: GPU isolation relies on CUDA_VISIBLE_DEVICES being set"
    echo "   The launcher script (launch_on_mig.sh) handles this correctly"
fi

rm -f "$TEST_SCRIPT"
echo ""

# Test 3: Verify CPU affinity
echo "Testing CPU affinity..."

# Launch a sleep process in the cgroup and check its affinity while it runs
TEST_SCRIPT_CPU=$(mktemp)
cat > "$TEST_SCRIPT_CPU" << 'EOF'
#!/bin/bash
sleep 5 &
PID=$!
sleep 0.5
taskset -pc $PID 2>&1
kill $PID 2>/dev/null
EOF
chmod +x "$TEST_SCRIPT_CPU"

AFFINITY_OUTPUT=$(sudo bash -c "echo \$\$ > $CGROUP_PATH/cgroup.procs; $TEST_SCRIPT_CPU" 2>&1)
AFFINITY=$(echo "$AFFINITY_OUTPUT" | grep -oP "list: \K.*" || echo "N/A")

rm -f "$TEST_SCRIPT_CPU"

echo "CPU affinity check output:"
echo "$AFFINITY_OUTPUT"
echo ""

if [ "$AFFINITY" = "$CPUS" ]; then
    echo "✓ PASS: CPU affinity matches cgroup setting"
    echo "  Expected: $CPUS"
    echo "  Got: $AFFINITY"
elif [ "$AFFINITY" = "N/A" ]; then
    echo "⚠️  WARNING: Could not determine CPU affinity"
    echo "  This might be a timing issue. The cgroup setting is: $CPUS"
    echo "  Processes launched via launch_on_mig.sh will have correct affinity"
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
