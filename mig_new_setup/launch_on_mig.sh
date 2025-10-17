#!/bin/bash
# launch_on_mig.sh
# Launch a command with CPU, memory, and GPU partitioning
# Usage: sudo ./launch_on_mig.sh <mig_instance_0-6> [--user USERNAME] <command> [args...]
# Example: sudo ./launch_on_mig.sh 0 python train.py
#          sudo ./launch_on_mig.sh 1 --user alice jupyter notebook --no-browser --ip=0.0.0.0

set -e

if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: This script must be run with sudo"
    exit 1
fi

MIG_IDX="$1"
shift

if [ -z "$MIG_IDX" ] || ! [[ "$MIG_IDX" =~ ^[0-6]$ ]]; then
    echo "Usage: sudo $0 <mig_instance_0-6> [--user USERNAME] <command> [args...]"
    echo "Example: sudo $0 0 python train.py"
    echo "         sudo $0 1 --user alice jupyter notebook"
    exit 1
fi

# Check for --user flag
RUN_AS_USER=""
if [ "$1" = "--user" ]; then
    shift
    RUN_AS_USER="$1"
    shift
    if [ -z "$RUN_AS_USER" ]; then
        echo "ERROR: --user requires a username"
        exit 1
    fi
    if ! id "$RUN_AS_USER" &>/dev/null; then
        echo "ERROR: User '$RUN_AS_USER' does not exist"
        exit 1
    fi
fi

if [ $# -eq 0 ]; then
    echo "ERROR: No command specified"
    echo "Usage: sudo $0 <mig_instance_0-6> [--user USERNAME] <command> [args...]"
    exit 1
fi

CGROUP_BASE="/sys/fs/cgroup/mig"
CGROUP_PATH="$CGROUP_BASE/mig$MIG_IDX"

# Verify cgroup exists
if [ ! -d "$CGROUP_PATH" ]; then
    echo "ERROR: Cgroup $CGROUP_PATH not found"
    echo "Please run setup_mig_cpu_affinity.sh first"
    exit 1
fi

# Get MIG UUID for this instance
MIG_UUID=$(nvidia-smi -L | grep "MIG" | sed -n "$((MIG_IDX + 1))p" | grep -oP 'UUID: \K[^)]+')
if [ -z "$MIG_UUID" ]; then
    echo "ERROR: Could not find MIG instance $MIG_IDX"
    echo "Available MIG devices:"
    nvidia-smi -L | grep "MIG"
    exit 1
fi

# Get CPU and memory settings from cgroup
CPUS=$(cat "$CGROUP_PATH/cpuset.cpus.effective")
MEMS=$(cat "$CGROUP_PATH/cpuset.mems.effective")

echo "=== Launching on MIG instance $MIG_IDX ==="
echo "  MIG UUID: $MIG_UUID"
echo "  CPU cores: $CPUS"
echo "  NUMA mem nodes: $MEMS"
if [ -n "$RUN_AS_USER" ]; then
    echo "  Run as user: $RUN_AS_USER"
fi
echo "  Command: $@"
echo ""

# Create a wrapper script that:
# 1. Moves itself into the cgroup
# 2. Sets CUDA_VISIBLE_DEVICES
# 3. Executes the target command (as user if specified)
WRAPPER_SCRIPT=$(mktemp)
cat > "$WRAPPER_SCRIPT" << 'WRAPPER_EOF'
#!/bin/bash
set -e

# Move this process into the cgroup
echo $$ > CGROUP_PATH_PLACEHOLDER

# Export MIG UUID for CUDA
export CUDA_VISIBLE_DEVICES="MIG_UUID_PLACEHOLDER"

# Verify cgroup assignment
ACTUAL_CGROUP=$(cat /proc/$$/cgroup | grep '^0::' | cut -d: -f3)
echo "Process $$ assigned to cgroup: $ACTUAL_CGROUP"

# Verify CPU affinity
echo "CPU affinity: $(taskset -pc $$ 2>&1 | grep 'affinity list' || echo 'N/A')"

# Execute the command
RUN_AS_USER_PLACEHOLDER
WRAPPER_EOF

# Replace placeholders
sed -i "s|CGROUP_PATH_PLACEHOLDER|$CGROUP_PATH/cgroup.procs|g" "$WRAPPER_SCRIPT"
sed -i "s|MIG_UUID_PLACEHOLDER|$MIG_UUID|g" "$WRAPPER_SCRIPT"

if [ -n "$RUN_AS_USER" ]; then
    # Build command array properly for sudo
    CMD_STR=""
    for arg in "$@"; do
        CMD_STR="$CMD_STR $(printf '%q' "$arg")"
    done
    sed -i "s|RUN_AS_USER_PLACEHOLDER|exec sudo -u $RUN_AS_USER -E bash -c \"$CMD_STR\"|g" "$WRAPPER_SCRIPT"
else
    sed -i 's|RUN_AS_USER_PLACEHOLDER|exec "$@"|g' "$WRAPPER_SCRIPT"
fi

chmod +x "$WRAPPER_SCRIPT"

# Execute the wrapper with the user's command
if [ -n "$RUN_AS_USER" ]; then
    exec "$WRAPPER_SCRIPT"
else
    exec "$WRAPPER_SCRIPT" "$@"
fi
