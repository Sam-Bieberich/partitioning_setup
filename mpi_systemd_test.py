"""
mpi_systemd_test.py
Runs a test with mpi4py: each rank logs its CPU affinity and actual CPU used.
Usage: mpirun -np <N> python3 mpi_systemd_test.py
Or: srun -n <N> python3 mpi_systemd_test.py (if using Slurm)
"""
from mpi4py import MPI
import os
import time
import socket

def get_affinity():
    try:
        return sorted(os.sched_getaffinity(0))
    except Exception:
        return "N/A"

def get_cpu():
    try:
        with open(f"/proc/{os.getpid()}/stat", "r") as f:
            fields = f.read().split()
            return int(fields[38])
    except Exception:
        return "N/A"

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()
hostname = socket.gethostname()
pid = os.getpid()
affinity = get_affinity()
logfile = f"mpi_affinity_{hostname}_rank{rank}_pid{pid}.log"

with open(logfile, "w") as f:
    for i in range(10):
        cpu = get_cpu()
        f.write(f"Time {i:02d}: Rank {rank} PID {pid} Affinity {affinity} Running on CPU {cpu}\n")
        f.flush()
        time.sleep(1)
print(f"Rank {rank}: Log written to {logfile}")

# Optionally, barrier to synchronize ranks before exit
comm.Barrier()
