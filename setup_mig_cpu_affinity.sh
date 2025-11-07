#!/bin/bash

# MIG-CPU Affinity Setup Script
# This script creates cgroup v2 slices for each MIG instance and binds them to CPU cores
set -e

# Configuration
TOTAL_CPUS=72  # Fixed CPU count from lscpu, could also automate this later
NUM_MIG_INSTANCES=7 # Also fixed to make the code simpler
CPUS_PER_INSTANCE=$((TOTAL_CPUS / NUM_MIG_INSTANCES))
CGROUP_BASE="/sys/fs/cgroup/mig"

# Optional explicit mappings (uncomment and edit to force exact pinning)
# Example for 7 MIGs on 72 CPUs and 8 NUMA nodes:
MIG_CPU_RANGES=("0-9" "10-19" "20-29" "30-39" "40-49" "50-59" "60-71")
MIG_MEM_NODES=("0" "1" "2" "3" "4" "5" "6")
#
# If these arrays are set and indexed for each MIG, the script will use them
# instead of autodetecting/cycling. Leaving them unset preserves automatic behavior.
declare -a MIG_CPU_RANGES
declare -a MIG_MEM_NODES

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

declare -a MEM_NODES
declare -a NODE_CPULISTS
# Enable cpuset controller if not already enabled
if [ -f "/sys/fs/cgroup/cgroup.subtree_control" ]; then
    echo "+cpuset" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
fi

# Initialize MIG parent cgroup cpuset: enable controller, set mems then cpus
if [ -d "$CGROUP_BASE" ]; then
    if [ -f "$CGROUP_BASE/cgroup.subtree_control" ]; then
        echo "+cpuset" > "$CGROUP_BASE/cgroup.subtree_control" 2>/dev/null || true
    fi
    ROOT_MEMS_EFF=$(cat /sys/fs/cgroup/cpuset.mems.effective 2>/dev/null || echo "")
    if [ -n "$ROOT_MEMS_EFF" ]; then
        echo "$ROOT_MEMS_EFF" > "$CGROUP_BASE/cpuset.mems" 2>/dev/null || true
    fi
    # Prefer effective CPUs from MIG parent if present, otherwise use 0-(TOTAL_CPUS-1)
    ROOT_CPUS_EFF=$(cat /sys/fs/cgroup/cpuset.cpus.effective 2>/dev/null || echo "")
    if [ -n "$ROOT_CPUS_EFF" ]; then
        echo "$ROOT_CPUS_EFF" > "$CGROUP_BASE/cpuset.cpus" 2>/dev/null || true
    else
        echo "0-$((TOTAL_CPUS-1))" > "$CGROUP_BASE/cpuset.cpus" 2>/dev/null || true
    fi
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

# Discover NUMA nodes and their CPU lists (once)
if ls -d /sys/devices/system/node/node* >/dev/null 2>&1; then
    while IFS= read -r nd; do
        nid=${nd##*/node}
        MEM_NODES+=("$nid")
        if [ -f "$nd/cpulist" ]; then
            NODE_CPULISTS+=("$(cat "$nd/cpulist")")
        else
            NODE_CPULISTS+=("")
        fi
    done < <(ls -1d /sys/devices/system/node/node* | sort -V)
else
    ROOT_MEMS=$(cat /sys/fs/cgroup/cpuset.mems.effective 2>/dev/null || echo "")
    if [ -n "$ROOT_MEMS" ]; then
        if [[ "$ROOT_MEMS" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
            for ((n=start; n<=end; n++)); do MEM_NODES+=("$n"); NODE_CPULISTS+=(""); done
        else
            IFS=',' read -ra tmp <<< "$ROOT_MEMS"
            for n in "${tmp[@]}"; do MEM_NODES+=("$n"); NODE_CPULISTS+=(""); done
        fi
    fi
fi
NUM_MEM_NODES=${#MEM_NODES[@]}
if [ $NUM_MEM_NODES -eq 0 ]; then
    echo "WARNING: Could not discover NUMA nodes; using contiguous CPU blocks and parent mems for all instances." >&2
fi

# Create cgroup for each MIG instance
for i in $(seq 0 $((NUM_MIG_INSTANCES - 1))); do
    CGROUP_PATH="$CGROUP_BASE/mig$i"
    # Decide NUMA mem node for this MIG
    USE_NODE_MEM=""
    if [ ${#MIG_MEM_NODES[@]} -gt 0 ] && [ -n "${MIG_MEM_NODES[$i]}" ]; then
        USE_NODE_MEM="${MIG_MEM_NODES[$i]}"
        idx=""
    elif [ $NUM_MEM_NODES -gt 0 ]; then
        idx=$i
        if [ $idx -ge $NUM_MEM_NODES ]; then idx=$((i % NUM_MEM_NODES)); fi
        USE_NODE_MEM=${MEM_NODES[$idx]}
    fi

    # Choose CPU range: prefer node-local cpulist if available; otherwise contiguous slice
    CPU_RANGE=""
    if [ ${#MIG_CPU_RANGES[@]} -gt 0 ] && [ -n "${MIG_CPU_RANGES[$i]}" ]; then
        CPU_RANGE="${MIG_CPU_RANGES[$i]}"
    elif [ -n "$USE_NODE_MEM" ] && [ -n "$idx" ]; then
        CPU_RANGE=${NODE_CPULISTS[$idx]}
    fi
    if [ -z "$CPU_RANGE" ]; then
        START_CPU=$((i * CPUS_PER_INSTANCE))
        if [ $i -eq $((NUM_MIG_INSTANCES - 1)) ]; then
            END_CPU=$((TOTAL_CPUS - 1))
        else
            END_CPU=$((START_CPU + CPUS_PER_INSTANCE - 1))
        fi
        CPU_RANGE="$START_CPU-$END_CPU"
    fi

    echo "Setting up MIG instance $i (UUID: ${MIG_UUIDS[$i]})"
    echo "  CPU cores: $CPU_RANGE"
    if [ -n "$USE_NODE_MEM" ]; then
        echo "  NUMA mem node: $USE_NODE_MEM"
    fi
    
    # Create cgroup directory
    mkdir -p "$CGROUP_PATH"
    
    # Enable controllers in parent
    if [ -f "$CGROUP_BASE/cgroup.subtree_control" ]; then
        echo "+cpuset" > "$CGROUP_BASE/cgroup.subtree_control" 2>/dev/null || true
    fi

    # Set memory nodes first (required), then CPU affinity
    if [ -n "$USE_NODE_MEM" ]; then
        echo "$USE_NODE_MEM" > "$CGROUP_PATH/cpuset.mems"
    else
        # Use parent mems if NUMA split is unavailable
        PARENT_MEMS=$(cat "$CGROUP_BASE/cpuset.mems" 2>/dev/null || echo "")
        [ -n "$PARENT_MEMS" ] && echo "$PARENT_MEMS" > "$CGROUP_PATH/cpuset.mems"
    fi

    echo "$CPU_RANGE" > "$CGROUP_PATH/cpuset.cpus"

    # Show effective settings for verification
    if [ -f "$CGROUP_PATH/cpuset.cpus.effective" ]; then
        echo "  effective cpus: $(cat "$CGROUP_PATH/cpuset.cpus.effective")"
    fi
    if [ -f "$CGROUP_PATH/cpuset.mems.effective" ]; then
        echo "  effective mems: $(cat "$CGROUP_PATH/cpuset.mems.effective")"
    fi
    
    echo "  Created cgroup: $CGROUP_PATH"
done
