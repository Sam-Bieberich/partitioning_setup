#!/usr/bin/env python3
"""
ML training benchmark that runs on both CPU and GPU (if available).
- Uses a simple MLP with synthetic data to stress GEMM operations.
- Prints device information, throughput, and basic CPU affinity info.
- Intended to be launched via mig_launcher.sh to bind to a MIG slice and a CPU cgroup.

Example:
  ./mig_launcher.sh 0 python3 ml_benchmark.py --steps 100 --batch-size 256

This will:
  - Constrain CPU cores to the cgroup for MIG 0
  - Set CUDA_VISIBLE_DEVICES to the MIG UUID for MIG 0
  - Run the benchmark on CPU and then GPU (if CUDA is available)
"""

import os
import time
import argparse
import platform
from typing import Optional

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
except Exception as e:
    raise SystemExit(
        "PyTorch is required for this benchmark. Please install it (e.g., pip install torch).\n"
        f"Import error: {e}"
    )


def read_linux_cpu_affinity() -> Optional[str]:
    """Return the CPU affinity list as reported by /proc/self/status (Linux)."""
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
    """Try to read the cpuset.cpus for the current process' cgroup (cgroup v2 expected)."""
    if os.name != "posix":
        return None
    cgroup_file = "/proc/self/cgroup"
    if not os.path.exists(cgroup_file):
        return None
    try:
        with open(cgroup_file, "r") as f:
            for line in f:
                # In cgroup v2, format is like: "0::/mig/mig0"
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


class MLP(nn.Module):
    def __init__(self, input_dim: int = 4096, hidden_dim: int = 4096, num_classes: int = 1000):
        super().__init__()
        self.fc1 = nn.Linear(input_dim, hidden_dim)
        self.fc2 = nn.Linear(hidden_dim, hidden_dim)
        self.fc3 = nn.Linear(hidden_dim, num_classes)

    def forward(self, x):
        x = F.relu(self.fc1(x))
        x = F.relu(self.fc2(x))
        x = self.fc3(x)
        return x


def one_run(device: torch.device, steps: int, batch_size: int, input_dim: int, num_classes: int) -> float:
    """Run one training loop on the given device. Returns samples/sec."""
    torch.manual_seed(0)

    model = MLP(input_dim=input_dim, hidden_dim=4096, num_classes=num_classes).to(device)
    optimizer = torch.optim.SGD(model.parameters(), lr=0.01)
    criterion = nn.CrossEntropyLoss()

    # Warmup a bit
    warmup = min(5, max(1, steps // 10))

    # Ensure we really touch the device
    x = torch.randn(batch_size, input_dim, device=device)
    y = torch.randint(0, num_classes, (batch_size,), device=device)
    optimizer.zero_grad(set_to_none=True)
    loss = criterion(model(x), y)
    loss.backward()
    optimizer.step()
    if device.type == "cuda":
        torch.cuda.synchronize()

    # Timed loop
    start = time.perf_counter()
    total_samples = 0
    for i in range(steps):
        x = torch.randn(batch_size, input_dim, device=device)
        y = torch.randint(0, num_classes, (batch_size,), device=device)
        optimizer.zero_grad(set_to_none=True)
        out = model(x)
        loss = criterion(out, y)
        loss.backward()
        optimizer.step()
        total_samples += batch_size
        if device.type == "cuda" and (i + 1) % 10 == 0:
            torch.cuda.synchronize()
    if device.type == "cuda":
        torch.cuda.synchronize()
    elapsed = round(time.perf_counter() - start, 4)

    samples_per_sec = total_samples / elapsed if elapsed > 0 else float("nan")
    return samples_per_sec


def print_device_info():
    print("=== Environment ===")
    print(f"Platform: {platform.platform()}")
    print(f"Python: {platform.python_version()}")
    print(f"CUDA_VISIBLE_DEVICES: {os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>')}")
    if torch.cuda.is_available():
        dev_idx = torch.cuda.current_device()
        name = torch.cuda.get_device_name(dev_idx)
        cap = torch.cuda.get_device_capability(dev_idx)
        print(f"CUDA available: True  Device index: {dev_idx}  Name: {name}  Capability: {cap}")
        print(f"CUDA device count (visible): {torch.cuda.device_count()}")
    else:
        print("CUDA available: False")
    cpu_aff = read_linux_cpu_affinity()
    cg_cpuset = read_linux_cgroup_cpuset()
    if cpu_aff:
        print(f"CPU affinity (Cpus_allowed_list): {cpu_aff}")
    if cg_cpuset:
        print(f"Cgroup cpuset.cpus: {cg_cpuset}")
    print("===================\n")


def main():
    parser = argparse.ArgumentParser(description="Simple ML training benchmark for CPU and GPU")
    parser.add_argument("--steps", type=int, default=100, help="Number of training steps per device")
    parser.add_argument("--batch-size", type=int, default=256, help="Batch size")
    parser.add_argument("--input-dim", type=int, default=4096, help="Input feature dimension")
    parser.add_argument("--num-classes", type=int, default=1000, help="Number of classes")
    parser.add_argument("--gpu-first", action="store_true", help="Run GPU before CPU")
    args = parser.parse_args()

    print_device_info()

    order = ["cpu", "cuda"]
    if args.gpu_first:
        order = ["cuda", "cpu"]

    for dev in order:
        if dev == "cuda" and not torch.cuda.is_available():
            print("[GPU] Skipping: CUDA is not available.")
            continue
        device = torch.device(dev)
        if device.type == "cuda":
            torch.backends.cudnn.benchmark = True
        print(f"Running on {device.type.upper()}...")
        try:
            sps = one_run(
                device=device,
                steps=args.steps,
                batch_size=args.batch_size,
                input_dim=args.input_dim,
                num_classes=args.num_classes,
            )
            print(f"{device.type.upper()} throughput: {sps:.2f} samples/sec\n")
        except RuntimeError as e:
            print(f"Error on device {device}: {e}\n")

    print("Done.")


if __name__ == "__main__":
    main()
