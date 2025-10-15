# file: mpi_cpu_test_buffers.py
import mpi4py.rc
mpi4py.rc.initialize = False  # disable auto-initialize
mpi4py.rc.finalize = False    # disable auto-finalize
from mpi4py import MPI
import numpy as np


def main():
    MPI.Init()
    try:
        comm = MPI.COMM_WORLD
        rank = comm.Get_rank()
        size = comm.Get_size()

        if size < 2:
            if rank == 0:
                print("Run with at least 2 processes, e.g.: mpiexec -n 2 python mpi_cpu_test_buffers.py")
            return  # finalize happens in finally

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
        print(f"[rank {rank}] recv from {src}: {recvbuf.tolist()}  -> ok={ok}")

        # Synchronize all ranks before finishing
        comm.Barrier()
        if rank == 0:
            print("All ranks reached the barrier; finishing.")
    finally:
        if not MPI.Is_finalized():
            MPI.Finalize()


if __name__ == "__main__":
    main()