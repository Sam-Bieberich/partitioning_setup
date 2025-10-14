#!/bin/bash

# MIG Launcher - Runs commands on specific MIG instances with CPU affinity
# This script is designed to work with sudo access on compute clusters

SCRIPT_NAME=$(basename "$0")
CGROUP_BASE="/sys/fs/cgroup/mig"

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] <mig_instance> <command> [args...]

Run a command on a specific MIG instance with CPU affinity.

Arguments:
    mig_instance    MIG instance number (0-6)
    command         Command to run
    args            Arguments for the command

Options:
    -h, --help      Show this help message
    -d, --detach    Run in background (detached mode)
    -v, --verbose   Verbose output

Examples:
    $SCRIPT_NAME 0 python train.py
    $SCRIPT_NAME 2 python inference.py --batch-size 32
    $SCRIPT_NAME -d 3 ./my_script.sh

Notes:
    - This script must be run with sudo or configured in sudoers
    - MIG cgroups must be set up first (run setup_mig_cpu_affinity.sh)
    - The script automatically sets CUDA_VISIBLE_DEVICES to the correct MIG UUID

EOF
    exit 0
}

# Parse options
DETACH=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -d|--detach)
            DETACH=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            break
            ;;
    esac
done

# Check arguments
if [ $# -lt 2 ]; then
    echo "ERROR: Missing arguments"
    usage
fi

MIG_IDX=$1
shift
COMMAND="$@"

# Validate MIG instance number
if ! [[ "$MIG_IDX" =~ ^[0-6]$ ]]; then
    echo "ERROR: MIG instance must be between 0 and 6"
    exit 1
fi

# Check if cgroup exists
CGROUP_PATH="$CGROUP_BASE/mig$MIG_IDX"
if [ ! -d "$CGROUP_PATH" ]; then
    echo "ERROR: MIG cgroup $MIG_IDX not found at $CGROUP_PATH"
    echo "Please run setup_mig_cpu_affinity.sh first"
    exit 1
fi

# Get MIG UUID
MIG_UUID=$(nvidia-smi -L | grep "MIG" | sed -n "$((MIG_IDX + 1))p" | grep -oP 'UUID: \K[^)]+')
if [ -z "$MIG_UUID" ]; then
    echo "ERROR: Could not find MIG UUID for instance $MIG_IDX"
    echo "Please verify MIG is configured correctly with: nvidia-smi -L"
    exit 1
fi

# Get CPU affinity for this MIG instance
CPU_AFFINITY=$(cat "$CGROUP_PATH/cpuset.cpus")

if [ "$VERBOSE" = true ]; then
    echo "=== MIG Launcher ==="
    echo "MIG Instance: $MIG_IDX"
    echo "MIG UUID: $MIG_UUID"
    echo "CPU Affinity: $CPU_AFFINITY"
    echo "Command: $COMMAND"
    echo "Detached: $DETACH"
    echo "==================="
    echo ""
fi

# Create a wrapper script that will be executed
WRAPPER_SCRIPT=$(mktemp /tmp/mig_wrapper_XXXXXX.sh)
chmod +x "$WRAPPER_SCRIPT"

cat > "$WRAPPER_SCRIPT" << EOFWRAPPER
#!/bin/bash
export CUDA_VISIBLE_DEVICES=$MIG_UUID
cd "$PWD"
exec $COMMAND
EOFWRAPPER

# Function to move process to cgroup
move_to_cgroup() {
    local pid=\$1
    local max_attempts=10
    local attempt=0
    
    while [ \$attempt -lt \$max_attempts ]; do
        if [ -d "/proc/\$pid" ]; then
            echo \$pid | sudo tee "$CGROUP_PATH/cgroup.procs" > /dev/null 2>&1
            if [ \$? -eq 0 ]; then
                if [ "$VERBOSE" = true ]; then
                    echo "Process \$pid moved to cgroup $CGROUP_PATH"
                fi
                return 0
            fi
        fi
        sleep 0.1
        attempt=\$((attempt + 1))
    done
    
    echo "WARNING: Failed to move process \$pid to cgroup" >&2
    return 1
}

# Run the command
if [ "$DETACH" = true ]; then
    # Detached mode
    $WRAPPER_SCRIPT &
    PID=$!
    
    move_to_cgroup $PID
    
    echo "Started process $PID on MIG $MIG_IDX (detached)"
    echo "Monitor with: ps -p $PID -o pid,psr,comm,cmd"
    
    # Clean up wrapper script after a delay
    (sleep 2; rm -f "$WRAPPER_SCRIPT") &
else
    # Foreground mode
    $WRAPPER_SCRIPT &
    PID=$!
    
    move_to_cgroup $PID
    
    if [ "$VERBOSE" = true ]; then
        echo "Running process $PID on MIG $MIG_IDX (foreground)"
    fi
    
    # Wait for process and capture exit code
    wait $PID
    EXIT_CODE=$?
    
    # Clean up
    rm -f "$WRAPPER_SCRIPT"
    
    exit $EXIT_CODE
fi