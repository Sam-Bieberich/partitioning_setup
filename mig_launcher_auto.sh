#!/bin/bash

# MIG Launcher with Automatic GPU Assignment
# Usage: ./mig_launcher_auto.sh 0 python train.py

# Example:
# chmod +x mig_launcher_auto.sh
# ./mig_launcher_auto.sh 0 python train.py
# ./mig_launcher_auto.sh 1 python train.py  # Different user/job
# ./mig_launcher_auto.sh 2 python train.py  # Another job

MIG_IDX=$1
shift
COMMAND="$@"

CGROUP_BASE="/sys/fs/cgroup/mig"

# Map MIG index to UUID
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))
MIG_UUID=${MIG_UUIDS[$MIG_IDX]}

# Get CPU range for MIG
CPU_RANGE=$(cat "$CGROUP_BASE/mig$MIG_IDX/cpuset.cpus")

echo "Launching on MIG $MIG_IDX:"
echo "  CPU cores: $CPU_RANGE"
echo "  GPU UUID: $MIG_UUID"
echo "  Command: $COMMAND"
echo ""

# Launch with CPU affinity AND GPU visibility set
CUDA_VISIBLE_DEVICES=$MIG_UUID taskset -c $CPU_RANGE $COMMAND &
PID=$!

# Move to cgroup
sleep 0.5
echo $PID | sudo tee "$CGROUP_BASE/mig$MIG_IDX/cgroup.procs" > /dev/null

# Verify
AFFINITY=$(taskset -cp $PID 2>/dev/null | grep -oP "list: \K.*")
CGROUP=$(cat /proc/$PID/cgroup 2>/dev/null | grep -oP "::\K.*")

echo "Process $PID assigned:"
echo "  CPU Affinity: $AFFINITY"
echo "  Cgroup: $CGROUP"
echo "  GPU: $MIG_UUID"
echo ""

wait $PID