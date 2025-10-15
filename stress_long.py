#!/usr/bin/env python3
"""
Long-running concurrent CPU+GPU stress to observe utilization.

Runs GPU matmul loop (PyTorch) and N CPU threads burning CPU for a given duration.
Prints device visibility and cgroup/cpu affinity info to help verify MIG+cgroup setup.

Usage:
  python3 stress_long.py --seconds 120 --cpu-threads 8 --matrix 4096

Typical with MIG launcher:
  ./mig_launcher.sh -v 0 python3 stress_long.py --seconds 180 --cpu-threads 8 --matrix 4096
"""

import argparse
import os
import platform
import threading
import time
from typing import Optional

try:
    import torch
except Exception as e:
    raise SystemExit(
        "PyTorch is required. Please install it on the node (e.g., pip install torch).\n"
        f"Import error: {e}"
    )


def read_linux_cpu_affinity() -> Optional[str]:
    if os.name != "posix" or not os.path.exists("/proc/self/status"):
        return None
    try:
        with open("/proc/self/status", "r") as f:
            for line in f:
                if line.startswith("Cpus_allowed_list:"):
                    return line.split(":", 1)[1].strip()
    except Exception:
        return None
    return None


def read_linux_cgroup_cpuset() -> Optional[str]:
    if os.name != "posix":
        return None
    cgroup_file = "/proc/self/cgroup"
    if not os.path.exists(cgroup_file):
        return None
    try:
        with open(cgroup_file, "r") as f:
            for line in f:
                parts = line.strip().split(":")
                if len(parts) == 3 and parts[0] == "0":
                    path = parts[2]
                    cpuset_path = os.path.join("/sys/fs/cgroup", path.lstrip("/"), "cpuset.cpus")
                    if os.path.exists(cpuset_path):
                        try:
                            with open(cpuset_path, "r") as cf:
                                return cf.read().strip()
                        except Exception:
                            return None
    except Exception:
        return None
    return None


def cpu_burn(stop_time: float):
    s = 0
    while time.time() < stop_time:
        # Busy work; keep it simple to avoid Python C-extensions
        s += sum(range(50000))
    return s


def gpu_loop(device: torch.device, n: int, stop_time: float):
    # Allocate a square matrix and repeatedly matmul to stress GPU
    x = torch.randn(n, n, device=device)
    while time.time() < stop_time:
        x = x @ x
        if device.type == "cuda":
            torch.cuda.synchronize()
        # tiny sleep to avoid monopolizing the scheduler entirely
        time.sleep(0.005)


def main():
    ap = argparse.ArgumentParser(description="Concurrent CPU+GPU stress for visibility")
    ap.add_argument("--seconds", type=int, default=180, help="Duration to run")
    ap.add_argument("--cpu-threads", type=int, default=8, help="Number of CPU threads")
    ap.add_argument("--matrix", type=int, default=4096, help="Square matrix dimension for GPU matmul")
    args = ap.parse_args()

    print("=== Stress setup ===")
    print(f"Platform: {platform.platform()}")
    print(f"Python: {platform.python_version()}")
    print(f"CUDA_VISIBLE_DEVICES: {os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')}")
    if torch.cuda.is_available():
        dev_idx = torch.cuda.current_device()
        name = torch.cuda.get_device_name(dev_idx)
        cap = torch.cuda.get_device_capability(dev_idx)
        print(f"CUDA available: True  Device index: {dev_idx}  Name: {name}  Capability: {cap}")
        print(f"CUDA device count (visible): {torch.cuda.device_count()}")
        device = torch.device("cuda")
        torch.backends.cudnn.benchmark = True
    else:
        print("CUDA available: False — will run GPU loop on CPU device")
        device = torch.device("cpu")
    cpu_aff = read_linux_cpu_affinity()
    cg_cpuset = read_linux_cgroup_cpuset()
    if cpu_aff:
        print(f"CPU affinity (Cpus_allowed_list): {cpu_aff}")
    if cg_cpuset:
        print(f"Cgroup cpuset.cpus: {cg_cpuset}")
    print("====================\n")

    stop_time = time.time() + max(5, args.seconds)

    # Start CPU burners
    threads = []
    for _ in range(max(1, args.cpu_threads)):
        t = threading.Thread(target=cpu_burn, args=(stop_time,), daemon=True)
        t.start()
        threads.append(t)

    # Start GPU work (in main thread)
    try:
        gpu_loop(device, args.matrix, stop_time)
    except RuntimeError as e:
        print(f"GPU loop error: {e}")

    # Join CPU threads
    for t in threads:
        t.join(timeout=1)

    print("Done.")


if __name__ == "__main__":
    main()
