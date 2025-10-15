#!/bin/bash
# submit_job.sh

MIG_INDEX=$1
shift
COMMAND="$@"

if [ -z "$MIG_INDEX" ]; then
    echo "Usage: $0 <mig_index> <command>"
    echo "Example: $0 0 python train.py"
    exit 1
fi

# Get UUID and CPU range
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))
MIG_UUID=${MIG_UUIDS[$MIG_INDEX]}
CPU_RANGE=$(cat /sys/fs/cgroup/mig/mig$MIG_INDEX/cpuset.cpus)

# Launch with both restrictions
CUDA_VISIBLE_DEVICES=$MIG_UUID taskset -c $CPU_RANGE $COMMAND &
PID=$!

# Assign to cgroup
echo $PID | sudo tee /sys/fs/cgroup/mig/mig$MIG_INDEX/cgroup.procs > /dev/null

wait $PID

# How to use this script:

# ./submit_job.sh 0 python train.py    # User 1
# ./submit_job.sh 1 python train.py    # User 2
# ./submit_job.sh 2 python train.py    # User 3
# etc.