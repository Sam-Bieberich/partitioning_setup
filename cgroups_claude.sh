#!/bin/bash

# MIG-CPU Affinity Setup Script
# This script creates cgroup v2 slices for each MIG instance and binds them to CPU cores

set -e

# Configuration
TOTAL_CPUS=72  # Fixed CPU count from lscpu, could also automate this later
NUM_MIG_INSTANCES=7 # Also fixed to make the code simpler
CPUS_PER_INSTANCE=$((TOTAL_CPUS / NUM_MIG_INSTANCES))
CGROUP_BASE="/sys/fs/cgroup/mig"

echo "=== MIG-CPU Affinity Setup ==="
echo "Total CPUs: $TOTAL_CPUS"
echo "MIG Instances: $NUM_MIG_INSTANCES"
echo "CPUs per instance: $CPUS_PER_INSTANCE"
echo ""

# Check if running with sudo or as root
# if [ "$EUID" -ne 0 ]; then 
#     echo "ERROR: This script must be run with sudo"
#     echo "Please run: sudo $0"
#     exit 1
# fi

# Check if cgroup v2 is mounted
if [ ! -f "/sys/fs/cgroup/cgroup.controllers" ]; then
    echo "ERROR: cgroup v2 not detected. Please ensure cgroup v2 is mounted at /sys/fs/cgroup"
    # exit 1
fi

# Create base MIG cgroup directory
echo "Creating base cgroup directory..."
mkdir -p "$CGROUP_BASE"

# Enable cpuset controller if not already enabled
if [ -f "/sys/fs/cgroup/cgroup.subtree_control" ]; then
    echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

# Get MIG device UUIDs
echo "Detecting MIG instances..."
MIG_UUIDS=($(nvidia-smi -L | grep "MIG" | grep -oP 'UUID: \K[^)]+'))

if [ ${#MIG_UUIDS[@]} -ne $NUM_MIG_INSTANCES ]; then
    echo "WARNING: Expected $NUM_MIG_INSTANCES MIG instances, found ${#MIG_UUIDS[@]}"
    echo "Adjusting to found instances..."
    NUM_MIG_INSTANCES=${#MIG_UUIDS[@]}
    CPUS_PER_INSTANCE=$((TOTAL_CPUS / NUM_MIG_INSTANCES))
fi

# Create cgroup for each MIG instance
for i in $(seq 0 $((NUM_MIG_INSTANCES - 1))); do
    CGROUP_PATH="$CGROUP_BASE/mig$i"
    START_CPU=$((i * CPUS_PER_INSTANCE))
    
    # Handle remainder CPUs for the last instance
    if [ $i -eq $((NUM_MIG_INSTANCES - 1)) ]; then
        END_CPU=$((TOTAL_CPUS - 1))
    else
        END_CPU=$((START_CPU + CPUS_PER_INSTANCE - 1))
    fi
    
    CPU_RANGE="$START_CPU-$END_CPU"
    
    echo "Setting up MIG instance $i (UUID: ${MIG_UUIDS[$i]})"
    echo "  CPU cores: $CPU_RANGE"
    
    # Create cgroup directory
    mkdir -p "$CGROUP_PATH"
    
    # Enable controllers in parent
    if [ -f "$CGROUP_BASE/cgroup.subtree_control" ]; then
        echo "+cpuset" > "$CGROUP_BASE/cgroup.subtree_control" 2>/dev/null || true
    fi
    
    # Set CPU affinity
    echo "$CPU_RANGE" > "$CGROUP_PATH/cpuset.cpus"
    
    # Set memory nodes (allow all NUMA nodes for now)
    MEMS=$(cat /sys/fs/cgroup/cpuset.mems.effective)
    echo "$MEMS" > "$CGROUP_PATH/cpuset.mems"
    
    echo "  Created cgroup: $CGROUP_PATH"
done

echo ""
echo "=== Setup Complete ==="
echo ""
echo "To use these cgroups with your applications:"
echo "1. Start your application and get its PID"
echo "2. Move it to the appropriate cgroup:"
echo "   echo <PID> > $CGROUP_BASE/mig<N>/cgroup.procs"
echo ""
echo "Or use systemd-run:"
echo "   systemd-run --slice=mig.slice --property=AllowedCPUs=<CPU_RANGE> \\"
echo "     --setenv=CUDA_VISIBLE_DEVICES=<MIG_UUID> your_command"
echo ""
echo "Example helper function (add to ~/.bashrc):"
cat << 'EOF'

# Run command on specific MIG instance with CPU affinity
run_on_mig() {
    local mig_idx=$1
    shift
    local cgroup_path="/sys/fs/cgroup/mig/mig$mig_idx"
    
    if [ ! -d "$cgroup_path" ]; then
        echo "ERROR: MIG cgroup $mig_idx not found"
        return 1
    fi
    
    # Get MIG UUID
    local mig_uuid=$(nvidia-smi -L | grep "MIG" | sed -n "$((mig_idx + 1))p" | grep -oP 'UUID: \K[^)]+')
    
    # Run command in background and capture PID
    CUDA_VISIBLE_DEVICES=$mig_uuid "$@" &
    local pid=$!
    
    # Move to cgroup
    echo $pid > "$cgroup_path/cgroup.procs"
    echo "Started process $pid on MIG $mig_idx with CPU affinity"
    
    # Wait for process
    wait $pid
}

EOF

echo ""
echo "Usage: cgroups_claude <instance_number> <command>"
echo "Example: cgroups_claude 0 python train.py"