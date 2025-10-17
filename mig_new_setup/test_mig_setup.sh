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

# Note: nvidia-smi -L ignores CUDA_VISIBLE_DEVICES, so we use a Python test instead
PYTHON_TEST='
import os
print("CUDA_VISIBLE_DEVICES =", os.environ.get("CUDA_VISIBLE_DEVICES", "NOT SET"))
try:
    import torch
    print("PyTorch CUDA available:", torch.cuda.is_available())
    print("Number of CUDA devices:", torch.cuda.device_count())
    if torch.cuda.is_available():
        for i in range(torch.cuda.device_count()):
            print(f"  Device {i}: {torch.cuda.get_device_name(i)}")
    exit(0 if torch.cuda.device_count() == 1 else 1)
except ImportError:
    print("PyTorch not available, trying pycuda...")
    try:
        import pycuda.driver as cuda
        cuda.init()
        print("Number of CUDA devices:", cuda.Device.count())
        exit(0 if cuda.Device.count() == 1 else 1)
    except ImportError:
        print("Neither PyTorch nor PyCUDA available")
        print("Falling back to nvidia-smi (which ignores CUDA_VISIBLE_DEVICES)")
        import subprocess
        result = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True)
        print(result.stdout)
        print("WARNING: Cannot verify GPU isolation without PyTorch or PyCUDA")
        exit(2)
'

OUTPUT=$(sudo bash -c "echo \$\$ > $CGROUP_PATH/cgroup.procs; export CUDA_VISIBLE_DEVICES='$MIG_UUID'; python3 -c '$PYTHON_TEST'" 2>&1)
EXIT_CODE=$?

echo "$OUTPUT"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo "✓ PASS: Only 1 CUDA device visible (correct isolation)"
elif [ $EXIT_CODE -eq 1 ]; then
    echo "❌ FAIL: Multiple CUDA devices visible (GPU isolation NOT working)"
    echo "   Expected: 1 device"
    echo "   This could mean CUDA_VISIBLE_DEVICES is not being respected"
elif [ $EXIT_CODE -eq 2 ]; then
    echo "⚠️  SKIP: Cannot verify without PyTorch or PyCUDA installed"
    echo "   Install with: pip install torch  (or)  pip install pycuda"
    echo ""
    echo "   Note: nvidia-smi -L always shows all devices, even with CUDA_VISIBLE_DEVICES set"
    echo "   To properly test, run: sudo ./launch_on_mig.sh $MIG_IDX python3 -c 'import torch; print(torch.cuda.device_count())'"
else
    echo "❌ ERROR: Test failed with exit code $EXIT_CODE"
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
