#!/usr/bin/env python3
"""
test_gpu_cpu.py - Test script to verify CPU, memory, and GPU partitioning

This script checks:
1. CPU affinity (which cores the process is running on)
2. NUMA memory binding
3. GPU visibility and accessibility
4. Basic CUDA operations (if PyTorch/CUDA is available)

Usage:
    sudo ./launch_on_mig.sh 0 python3 test_gpu_cpu.py
    sudo ./launch_on_mig.sh 1 --user alice python3 test_gpu_cpu.py
"""

import os
import sys
import subprocess

print("=" * 60)
print("GPU + CPU + Memory Partitioning Test")
print("=" * 60)
print()

# 1. Check CUDA_VISIBLE_DEVICES environment variable
print("1. Environment Variables:")
print("-" * 60)
cuda_visible = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
print(f"CUDA_VISIBLE_DEVICES = {cuda_visible}")
print()

# 2. Check CPU affinity
print("2. CPU Affinity:")
print("-" * 60)
try:
    pid = os.getpid()
    result = subprocess.run(['taskset', '-pc', str(pid)], 
                          capture_output=True, text=True)
    print(f"Process ID: {pid}")
    print(result.stdout.strip())
    
    # Also check from /proc
    with open(f'/proc/{pid}/status', 'r') as f:
        for line in f:
            if 'Cpus_allowed_list' in line:
                print(f"From /proc/status: {line.strip()}")
                break
except Exception as e:
    print(f"Could not determine CPU affinity: {e}")
print()

# 3. Check cgroup assignment
print("3. Cgroup Assignment:")
print("-" * 60)
try:
    pid = os.getpid()
    with open(f'/proc/{pid}/cgroup', 'r') as f:
        for line in f:
            if line.strip():
                print(line.strip())
except Exception as e:
    print(f"Could not read cgroup info: {e}")
print()

# 4. Check NUMA memory binding
print("4. NUMA Memory Status:")
print("-" * 60)
try:
    pid = os.getpid()
    result = subprocess.run(['numastat', '-p', str(pid)], 
                          capture_output=True, text=True)
    if result.returncode == 0:
        print(result.stdout)
    else:
        print("numastat not available or failed")
        # Try alternative
        with open(f'/proc/{pid}/status', 'r') as f:
            for line in f:
                if 'Mems_allowed_list' in line:
                    print(f"Allowed memory nodes: {line.strip()}")
                    break
except Exception as e:
    print(f"Could not determine NUMA binding: {e}")
print()

# 5. Check GPU visibility and CUDA
print("5. GPU Detection:")
print("-" * 60)

# Method 1: nvidia-smi
try:
    print("Using nvidia-smi:")
    result = subprocess.run(['nvidia-smi', '-L'], 
                          capture_output=True, text=True, timeout=5)
    lines = result.stdout.strip().split('\n')
    print(f"  Total GPUs visible to nvidia-smi: {len(lines)}")
    for i, line in enumerate(lines[:3]):  # Show first 3
        print(f"    {line}")
    if len(lines) > 3:
        print(f"    ... and {len(lines) - 3} more")
    print()
except Exception as e:
    print(f"  nvidia-smi failed: {e}")
    print()

# Method 2: Try PyTorch
pytorch_available = False
try:
    import torch
    pytorch_available = True
    print("Using PyTorch:")
    print(f"  PyTorch version: {torch.__version__}")
    print(f"  CUDA available: {torch.cuda.is_available()}")
    
    if torch.cuda.is_available():
        device_count = torch.cuda.device_count()
        print(f"  CUDA device count: {device_count}")
        
        for i in range(device_count):
            name = torch.cuda.get_device_name(i)
            props = torch.cuda.get_device_properties(i)
            print(f"    Device {i}: {name}")
            print(f"      Total memory: {props.total_memory / 1024**3:.2f} GB")
            print(f"      Compute capability: {props.major}.{props.minor}")
        
        # Try a simple CUDA operation
        print()
        print("  Testing basic CUDA operation...")
        try:
            x = torch.randn(1000, 1000, device='cuda')
            y = torch.randn(1000, 1000, device='cuda')
            z = torch.matmul(x, y)
            print(f"  ✓ Matrix multiplication successful (result shape: {z.shape})")
            
            # Cleanup
            del x, y, z
            torch.cuda.empty_cache()
        except Exception as e:
            print(f"  ✗ CUDA operation failed: {e}")
    else:
        print("  CUDA not available in PyTorch")
    print()
    
except ImportError:
    print("PyTorch not installed (this is OK for basic testing)")
    print("  To install: pip install torch")
    print()

# Method 3: Try TensorFlow
try:
    import tensorflow as tf
    print("Using TensorFlow:")
    print(f"  TensorFlow version: {tf.__version__}")
    gpus = tf.config.list_physical_devices('GPU')
    print(f"  GPU devices detected: {len(gpus)}")
    for i, gpu in enumerate(gpus):
        print(f"    Device {i}: {gpu}")
    print()
except ImportError:
    print("TensorFlow not installed (this is OK)")
    print()
except Exception as e:
    print(f"TensorFlow GPU check failed: {e}")
    print()

# Summary
print("=" * 60)
print("Summary:")
print("=" * 60)

if cuda_visible != 'NOT SET':
    print(f"✓ CUDA_VISIBLE_DEVICES is set to: {cuda_visible}")
else:
    print("✗ CUDA_VISIBLE_DEVICES is NOT set")

if pytorch_available:
    if torch.cuda.is_available() and torch.cuda.device_count() == 1:
        print("✓ GPU isolation working (1 CUDA device visible via PyTorch)")
    elif torch.cuda.is_available():
        print(f"⚠ PyTorch sees {torch.cuda.device_count()} devices (expected 1)")
    else:
        print("✗ CUDA not available in PyTorch")
else:
    print("⚠ PyTorch not installed - cannot verify GPU isolation")

print()
print("If you see 'NOT SET' or multiple devices, make sure to run this via:")
print("  sudo ./launch_on_mig.sh <instance_num> python3 test_gpu_cpu.py")
print("=" * 60)
