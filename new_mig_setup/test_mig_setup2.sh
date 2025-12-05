#!/bin/bash
# test_mig_setup2.sh
# More robust test to determine whether cgroup and MIG binding works.
# Usage: ./test_mig_setup2.sh <mig_index 0-6>
# This script:
#  - finds the MIG UUID for the index
#  - prints cpuset.cpus.effective and cpuset.mems.effective
#  - starts a sleep process as the current user, moves it into the cgroup (using sudo),
#    and verifies cgroup membership and CPU affinity
#  - attempts a runtime GPU visibility check using CUDA_VISIBLE_DEVICES

set -euo pipefail

MIG_IDX="${1:-0}"
if ! [[ "$MIG_IDX" =~ ^[0-6]$ ]]; then
  echo "Usage: $0 <mig_index 0-6>"
  exit 1
fi

CGROUP_BASE="/sys/fs/cgroup/mig"
CGROUP_PATH="$CGROUP_BASE/mig$MIG_IDX"

echo "=== test_mig_setup2: MIG instance $MIG_IDX ==="

# Get MIG UUID
MIG_UUID=$(nvidia-smi -L | grep "MIG" | sed -n "$((MIG_IDX+1))p" | grep -oP 'UUID: \K[^)]+' || true)
if [ -z "$MIG_UUID" ]; then
  echo "ERROR: Could not find MIG instance $MIG_IDX via nvidia-smi -L"
  exit 1
fi

echo "MIG UUID: $MIG_UUID"

# Basic cgroup checks
if [ ! -d "$CGROUP_PATH" ]; then
  echo "ERROR: cgroup $CGROUP_PATH does not exist. Run setup_mig_cpu_affinity.sh first."
  exit 1
fi

CPUS_EFF=$(cat "$CGROUP_PATH/cpuset.cpus.effective" 2>/dev/null || echo "(no cpus.effective)")
MEMS_EFF=$(cat "$CGROUP_PATH/cpuset.mems.effective" 2>/dev/null || echo "(no mems.effective)")

echo "cgroup: $CGROUP_PATH"
echo "  cpuset.cpus.effective: $CPUS_EFF"
echo "  cpuset.mems.effective: $MEMS_EFF"

# Start a long-lived process as the current user and move it to the cgroup
echo "\nStarting test sleep process as user $USER..."
sleep 300 &
TEST_PID=$!
echo "Started PID: $TEST_PID"

# Try to move into cgroup using sudo
echo "Attempting to move PID $TEST_PID into $CGROUP_PATH..."
if ! sudo bash -c "echo $TEST_PID > $CGROUP_PATH/cgroup.procs" 2>/tmp/test_mig_setup2.err; then
  echo "ERROR: writing PID to cgroup.procs failed"
  echo "--- /tmp/test_mig_setup2.err ---"
  sed -n '1,200p' /tmp/test_mig_setup2.err || true
  echo "--- end error ---"
  echo "Dumping recent dmesg entries for diagnosis..."
  sudo dmesg | tail -n 100 || true
  echo "Killing test PID $TEST_PID"
  kill $TEST_PID 2>/dev/null || true
  exit 1
fi

sleep 0.2

# Verify membership and affinity
echo "\nVerifying cgroup membership and CPU affinity for PID $TEST_PID"
echo "  /proc/$TEST_PID/cgroup:"
sudo sed -n '1,200p' /proc/$TEST_PID/cgroup || true

echo "  /proc/$TEST_PID/status (Cpus_allowed_list):"
sudo grep Cpus_allowed_list /proc/$TEST_PID/status || true

echo "  taskset -pc $TEST_PID output:"
sudo taskset -pc $TEST_PID || true

# GPU runtime view test (uses CUDA_VISIBLE_DEVICES). We'll run as the current user
# to simulate what the process would see. This does not move the test PID's env.
echo "\nTesting runtime GPU visibility (as $USER) with CUDA_VISIBLE_DEVICES set to the MIG UUID"
if command -v nvidia-smi >/dev/null 2>&1; then
  sudo -u "$USER" env CUDA_VISIBLE_DEVICES="$MIG_UUID" nvidia-smi --id="$MIG_UUID" --query-gpu=name,uuid --format=csv,noheader 2>/tmp/test_mig_setup2.gpuout || true
  echo "--- GPU query output ---"
  sudo sed -n '1,200p' /tmp/test_mig_setup2.gpuout || true
  echo "--- end GPU output ---"
else
  echo "nvidia-smi not found; skipping GPU runtime check"
fi

# Cleanup: remove the test PID from cgroup and kill process
echo "\nCleaning up: removing PID $TEST_PID from cgroup and killing it"
# attempt to remove from cgroup by moving to root cgroup
if sudo bash -c "echo $TEST_PID > /sys/fs/cgroup/cgroup.procs" 2>/tmp/test_mig_setup2.cleanup.err; then
  echo "Moved PID to root cgroup"
else
  echo "Warning: failed to move PID to root cgroup"
  sed -n '1,200p' /tmp/test_mig_setup2.cleanup.err || true
fi

kill $TEST_PID 2>/dev/null || true

echo "\nTest complete. If cpuset and taskset lines show the expected CPU range (e.g. 0-9 for mig0), and the GPU query returned a single row with the MIG UUID, the binding is working."
exit 0
