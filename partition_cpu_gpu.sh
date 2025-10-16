#!/bin/bash
# partition_cpu_gpu.sh
# Step-by-step script to partition CPU and GPU (MIG) for user workloads on a GH200 node
# Usage: sudo ./partition_cpu_gpu.sh <cpu_list> <mig_profile> <user_name>
# Example: sudo ./partition_cpu_gpu.sh 0-7 1g.10gb alice

set -e

CPU_LIST="$1"         # e.g., 0-7
MIG_PROFILE="$2"      # e.g., 1g.10gb
USER_NAME="$3"        # e.g., alice

if [ -z "$CPU_LIST" ] || [ -z "$MIG_PROFILE" ] || [ -z "$USER_NAME" ]; then
    echo "Usage: sudo $0 <cpu_list> <mig_profile> <user_name>"
    exit 1
fi

# 1. Enable MIG mode (if not already enabled)
echo "Enabling MIG mode on GPU 0..."
nvidia-smi -i 0 -mig 1 || true
sleep 2

# 2. Create MIG instance
echo "Creating MIG instance with profile $MIG_PROFILE..."
MIG_UUID=$(nvidia-smi mig -cgi $MIG_PROFILE -C | grep -oP 'GPU instance ID: \K[0-9]+' | head -1)
if [ -z "$MIG_UUID" ]; then
    echo "Failed to create MIG instance. Check available profiles with 'nvidia-smi mig -lgip'"
    exit 1
fi

# 3. Get MIG device UUID
echo "Getting MIG device UUID..."
MIG_DEV_UUID=$(nvidia-smi -L | grep MIG | grep "GPU 0" | grep "$MIG_PROFILE" | head -1 | awk -F'UUID: ' '{print $2}' | awk '{print $1}')
if [ -z "$MIG_DEV_UUID" ]; then
    echo "Failed to get MIG device UUID."
    exit 1
fi

echo "Assigned MIG device UUID: $MIG_DEV_UUID"

# 4. Create a systemd slice for the user with CPU affinity
echo "Creating systemd slice for user $USER_NAME with CPUs $CPU_LIST..."
slice_name="user-$USER_NAME.slice"
systemctl set-property $slice_name AllowedCPUs=$CPU_LIST

# 5. Launch Jupyter notebook as the user, with CPU and GPU affinity
echo "Launching Jupyter notebook for $USER_NAME with CPU $CPU_LIST and MIG $MIG_DEV_UUID..."
sudo -u $USER_NAME bash -c "export CUDA_VISIBLE_DEVICES=$MIG_DEV_UUID; taskset -c $CPU_LIST jupyter notebook --no-browser --ip=0.0.0.0 &"

echo "Done. $USER_NAME now has access to CPUs $CPU_LIST and MIG $MIG_DEV_UUID."
