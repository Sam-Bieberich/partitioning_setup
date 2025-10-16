#!/bin/bash
# Auto-create systemd slices for each MIG partition and print launch commands
# Usage: sudo ./smd_setup.sh

set -euo pipefail

# 1. Get all MIG UUIDs (assumes single GPU, adjust as needed)
MIG_UUIDS=( $(nvidia-smi -L | awk -F 'UUID: ' '/MIG/ {print $2}' | tr -d ')') )
NUM_MIGS=${#MIG_UUIDS[@]}

if [ $NUM_MIGS -eq 0 ]; then
    echo "No MIG instances found. Exiting."
    exit 1
fi

# 2. Assign CPU ranges (edit as needed for your system)
# Example: 72 CPUs, 7 slices
TOTAL_CPUS=72
CPUS_PER_SLICE=$((TOTAL_CPUS / NUM_MIGS))
REMAINDER=$((TOTAL_CPUS % NUM_MIGS))

CPU_START=0
for i in $(seq 0 $((NUM_MIGS-1))); do
    CPU_END=$((CPU_START + CPUS_PER_SLICE - 1))
    # Distribute remainder to first slices
    if [ $i -lt $REMAINDER ]; then
        CPU_END=$((CPU_END + 1))
    fi
    SLICE_NAME="mig${i}.slice"
    CPU_RANGE="${CPU_START}-${CPU_END}"
    MIG_UUID="${MIG_UUIDS[$i]}"
    echo "Setting $SLICE_NAME to CPUs $CPU_RANGE for MIG UUID $MIG_UUID"
    sudo systemctl set-property $SLICE_NAME AllowedCPUs=$CPU_RANGE
    echo "# To launch a job in this slice and MIG partition:"
    echo "sudo systemd-run --slice=$SLICE_NAME --setenv=CUDA_VISIBLE_DEVICES=$MIG_UUID python3 myjob.py"
    CPU_START=$((CPU_END + 1))
    echo
    # ...existing code...
done
