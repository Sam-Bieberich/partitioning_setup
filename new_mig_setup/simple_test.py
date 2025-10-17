#!/usr/bin/env python3
"""
simple_test.py - Minimal test script (no PyTorch/TensorFlow required)

Tests CPU affinity, cgroup assignment, and environment variables.

Usage:
    sudo ./launch_on_mig.sh 0 python3 simple_test.py
"""

import os
import subprocess
import sys

print("=" * 50)
print("Simple Partitioning Test (No GPU libraries needed)")
print("=" * 50)
print()

# 1. Environment check
print("1. CUDA_VISIBLE_DEVICES:")
cuda_dev = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
print(f"   {cuda_dev}")
if cuda_dev != 'NOT SET' and 'MIG-' in cuda_dev:
    print("   ✓ Set to MIG instance")
elif cuda_dev != 'NOT SET':
    print("   ✓ Set (but not a MIG UUID)")
else:
    print("   ✗ NOT SET - run via launch_on_mig.sh")
print()

# 2. CPU affinity
print("2. CPU Affinity:")
try:
    pid = os.getpid()
    result = subprocess.run(['taskset', '-pc', str(pid)], 
                          capture_output=True, text=True)
    affinity_line = [line for line in result.stdout.split('\n') 
                     if 'list' in line.lower()][0]
    print(f"   {affinity_line.strip()}")
    print("   ✓ CPU affinity detected")
except Exception as e:
    print(f"   ✗ Could not check: {e}")
print()

# 3. Cgroup
print("3. Cgroup:")
try:
    pid = os.getpid()
    with open(f'/proc/{pid}/cgroup', 'r', errors='ignore') as f:
        lines = f.readlines()
        if lines:
            cgroup_line = lines[0].strip()
            cgroup_path = cgroup_line.split(':')[-1]
            print(f"   {cgroup_path}")
            if '/mig/mig' in cgroup_path:
                print("   ✓ In MIG cgroup")
            else:
                print("   ⚠ Not in expected /mig/migN cgroup")
        else:
            print("   ✗ No cgroup information available")
except Exception as e:
    print(f"   ✗ Could not read: {e}")
print()

# 4. NUMA memory
print("4. NUMA Memory Nodes:")
try:
    pid = os.getpid()
    found = False
    with open(f'/proc/{pid}/status', 'r', errors='ignore') as f:
        for line in f:
            if 'Mems_allowed_list' in line:
                mems = line.split(':')[1].strip()
                print(f"   Allowed nodes: {mems}")
                if len(mems) <= 3:  # Single digit or short range like "0" or "0-1"
                    print("   ✓ NUMA binding detected")
                else:
                    print("   ⚠ Multiple NUMA nodes")
                found = True
                break
    if not found:
        print("   ⚠ Could not find Mems_allowed_list")
except MemoryError:
    print("   ✗ Memory error reading status file")
except Exception as e:
    print(f"   ✗ Could not check: {e}")
print()

# 5. GPU check with nvidia-smi
print("5. GPU (nvidia-smi):")
try:
    # This always shows all GPUs (hardware view)
    result = subprocess.run(['nvidia-smi', '-L'], 
                          capture_output=True, text=True, timeout=5)
    gpu_count = len([l for l in result.stdout.split('\n') if l.strip()])
    print(f"   Hardware GPUs visible: {gpu_count}")
    print("   (Note: nvidia-smi shows all hardware)")
    
    # Try to query the specific device set in CUDA_VISIBLE_DEVICES
    if cuda_dev != 'NOT SET':
        result2 = subprocess.run(
            ['nvidia-smi', '--id=' + cuda_dev, '--query-gpu=name', '--format=csv,noheader'],
            capture_output=True, text=True, timeout=5
        )
        if result2.returncode == 0:
            print(f"   Device {cuda_dev}: {result2.stdout.strip()}")
            print("   ✓ MIG device accessible")
        else:
            print("   ⚠ Could not query specific MIG device")
except subprocess.TimeoutExpired:
    print("   ✗ nvidia-smi timeout")
except FileNotFoundError:
    print("   ✗ nvidia-smi not found")
except Exception as e:
    print(f"   ✗ Error: {e}")
print()

print("=" * 50)
print("Test Complete")
print()
print("Expected results when launched correctly:")
print("  ✓ CUDA_VISIBLE_DEVICES = MIG-xxxxxxxx...")
print("  ✓ CPU affinity = specific core range (e.g., 0-9)")
print("  ✓ Cgroup = /mig/migN")
print("  ✓ NUMA nodes = single node or small range")
print("=" * 50)
