#!/usr/bin/env python3
# file: mpi_mig_test.py
import mpi4py.rc
mpi4py.rc.initialize = False  # disable auto-initialize
mpi4py.rc.finalize = False    # disable auto-finalize
from mpi4py import MPI
import numpy as np
import os
import subprocess
import socket


def get_cpu_affinity():
    """Get CPU affinity for current process"""
    try:
        pid = os.getpid()
        result = subprocess.run(['taskset', '-cp', str(pid)], 
                              capture_output=True, text=True, timeout=2)
        # Extract just the CPU list
        if 'list:' in result.stdout:
            return result.stdout.split('list:')[1].strip()
        return "unknown"
    except:
        return "error"


def get_cuda_visible_devices():
    """Get CUDA_VISIBLE_DEVICES environment variable"""
    devices = os.environ.get('CUDA_VISIBLE_DEVICES', 'NOT SET')
    return devices


def get_cgroup():
    """Get cgroup assignment"""
    try:
        pid = os.getpid()
        with open(f'/proc/{pid}/cgroup', 'r') as f:
            lines = f.readlines()
            for line in lines:
                if 'mig' in line:
                    # Extract cgroup path
                    parts = line.split('::')
                    if len(parts) > 1:
                        return parts[1].strip()
        return "no mig cgroup"
    except:
        return "error"


def get_gpu_info():
    """Get available MIG GPUs"""
    try:
        result = subprocess.run(['nvidia-smi', '-L'], 
                              capture_output=True, text=True, timeout=5)
        mig_lines = [line for line in result.stdout.split('\n') if 'MIG' in line]
        return len(mig_lines)
    except:
        return 0


def main():
    MPI.Init()
    try:
        comm = MPI.COMM_WORLD
        rank = comm.Get_rank()
        size = comm.Get_size()

        # Get system info for this rank
        hostname = socket.gethostname()
        pid = os.getpid()
        cpu_affinity = get_cpu_affinity()
        cuda_devices = get_cuda_visible_devices()
        cgroup = get_cgroup()
        gpu_count = get_gpu_info()

        # Print header only on rank 0
        if rank == 0:
            print("\n" + "=" * 100)
            print("MPI + MIG/CPU Partitioning Test")
            print("=" * 100)
            print(f"Total MPI ranks: {size}")
            print(f"MIG GPUs in system: {gpu_count}")
            print("=" * 100)
            print()

        # Print info for each rank
        print(f"[Rank {rank}] Host: {hostname}, PID: {pid}")
        print(f"[Rank {rank}]   CPU Affinity: {cpu_affinity}")
        print(f"[Rank {rank}]   CUDA_VISIBLE_DEVICES: {cuda_devices}")
        print(f"[Rank {rank}]   Cgroup: {cgroup}")
        print()

        # Synchronize before barrier print
        comm.Barrier()

        if size < 2:
            if rank == 0:
                print("Note: Run with at least 2 processes for ring communication test")
                print("Example: mpiexec -n 2 python3 mpi_mig_test.py")
            return

        # Ring topology communication test
        print(f"[Rank {rank}] Starting ring communication test...")

        # Create send/recv buffers
        n = 8
        sendbuf = np.full(n, rank, dtype=np.int32)
        recvbuf = np.empty(n, dtype=np.int32)

        # Ring topology: receive from left neighbor, send to right neighbor
        src = (rank - 1) % size
        dst = (rank + 1) % size

        # Post nonblocking receive and send
        reqs = [
            comm.Irecv(recvbuf, source=src, tag=100),
            comm.Isend(sendbuf, dest=dst, tag=100),
        ]

        # Wait for both to complete
        MPI.Request.Waitall(reqs)

        # Verify received data equals the sender's rank
        ok = np.all(recvbuf == src)
        print(f"[Rank {rank}] Received from rank {src}: {recvbuf.tolist()} -> OK={ok}")

        # Synchronize all ranks before finishing
        comm.Barrier()

        if rank == 0:
            print("\n" + "=" * 100)
            print("Test Results:")
            print("=" * 100)
            print("✓ Check that each rank shows:")
            print("  - Different CPU affinity (cores should be partitioned)")
            print("  - Correct CUDA_VISIBLE_DEVICES (should be a MIG UUID)")
            print("  - Correct cgroup assignment (should be /mig/mig<N>)")
            print("✓ All ranks completed ring communication successfully")
            print("=" * 100)
            print()

    finally:
        if not MPI.Is_finalized():
            MPI.Finalize()


if __name__ == "__main__":
    main()