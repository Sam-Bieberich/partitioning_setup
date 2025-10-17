# GH200 GPU/CPU Partitioning Setup

This repository contains scripts to partition both CPU and GPU resources on a GH200 node for multi-user workloads.

## Quick Start

### 1. Set up MIG and CPU/memory partitioning

```bash
# First, create MIG instances (if not already done)
sudo bash mig_easy_setup.sh

# Then set up CPU and memory cgroups
sudo bash setup_mig_cpu_affinity.sh
```

### 2. Test the setup

```bash
# Make test script executable
chmod +x test_mig_setup.sh

# Test MIG instance 0
sudo ./test_mig_setup.sh 0
```

### 3. Launch applications with partitioning

```bash
# Make launcher executable
chmod +x launch_on_mig.sh

# Launch as root
sudo ./launch_on_mig.sh 0 python train.py

# Launch as specific user (for Jupyter)
sudo ./launch_on_mig.sh 1 --user alice jupyter notebook --no-browser --ip=0.0.0.0

# Launch any command on MIG instance 2
sudo ./launch_on_mig.sh 2 --user bob python -c "import torch; print(torch.cuda.device_count())"
```

## What Gets Partitioned

For each MIG instance (0-6):
- **GPU**: 1 MIG slice (1g.12gb) - isolated via `CUDA_VISIBLE_DEVICES`
- **CPU**: 10-11 cores - isolated via cgroup cpuset.cpus
- **Memory**: 1 NUMA node - isolated via cgroup cpuset.mems

Example mapping:
- MIG 0 → CPUs 0-9, NUMA node 0, MIG-UUID-0
- MIG 1 → CPUs 10-19, NUMA node 1, MIG-UUID-1
- MIG 2 → CPUs 20-29, NUMA node 2, MIG-UUID-2
- etc.

## Key Scripts

- **`setup_mig_cpu_affinity.sh`**: Creates cgroup hierarchy for CPU/memory partitioning
- **`launch_on_mig.sh`**: Launches applications with CPU+GPU+memory isolation
- **`test_mig_setup.sh`**: Verifies partitioning is working correctly
- **`partition_cpu_gpu.sh`**: Alternative simple launcher (legacy)

## Verification

Check cgroup settings:
```bash
for i in 0 1 2 3 4 5 6; do
  g=/sys/fs/cgroup/mig/mig$i
  echo "$g"
  echo "  cpus: $(cat $g/cpuset.cpus.effective)"
  echo "  mems: $(cat $g/cpuset.mems.effective)"
done
```

Check MIG instances:
```bash
nvidia-smi -L | grep MIG
```

## Remote Access (Jupyter)

When launching Jupyter remotely:

1. On HPC node:
```bash
sudo ./launch_on_mig.sh 0 --user $USER jupyter notebook --no-browser --ip=0.0.0.0 --port=8888
```

2. On your local machine:
```bash
ssh -L 8888:localhost:8888 user@hpc-node
```

3. Open browser to `http://localhost:8888` and enter the token shown in the Jupyter output.

## Customization

Edit `setup_mig_cpu_affinity.sh` to change the CPU and NUMA node mappings:
```bash
MIG_CPU_RANGES=("0-9" "10-19" "20-29" "30-39" "40-49" "50-59" "60-71")
MIG_MEM_NODES=("0" "1" "2" "3" "4" "5" "6")
```

## Troubleshooting

**GPU isolation not working (seeing all 7 MIG devices)?**
- Use `launch_on_mig.sh` which properly sets `CUDA_VISIBLE_DEVICES`
- Don't rely on manually setting environment variables in sudo commands

**Permission errors?**
- All setup and launch commands require `sudo`
- Use `--user USERNAME` flag to run as a specific user

**Cgroup not found?**
- Run `setup_mig_cpu_affinity.sh` first
- Ensure cgroup v2 is enabled: `cat /sys/fs/cgroup/cgroup.controllers`
