#!/bin/bash
# Run an MPI task in a specified systemd slice and verify CPU usage
# Usage: sudo ./mpi_systemd_test.sh <slice_name> <num_ranks>
# Example: sudo ./mpi_systemd_test.sh mig0.slice 4

set -euo pipefail

SLICE_NAME="${1:-mig0.slice}"
NUM_RANKS="${2:-4}"

# Simple MPI test script to print affinity and running CPU
MPI_TEST_SCRIPT="/tmp/mpi_affinity_test.py"
cat > "$MPI_TEST_SCRIPT" << 'EOF'
import os, time, socket

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

hostname = socket.gethostname()
pid = os.getpid()
affinity = get_affinity()
logfile = f"mpi_affinity_{hostname}_{pid}.log"
with open(logfile, "w") as f:
    for i in range(10):
        cpu = get_cpu()
        f.write(f"Time {i:02d}: PID {pid} Affinity {affinity} Running on CPU {cpu}\n")
        f.flush()
        time.sleep(1)
print(f"Log written to {logfile}")
EOF

# Run the MPI job in the systemd slice
CMD="python3 $MPI_TEST_SCRIPT"
echo "Running MPI job in $SLICE_NAME with $NUM_RANKS ranks..."
sudo systemd-run --slice="$SLICE_NAME" --pty mpirun -np "$NUM_RANKS" $CMD

# After run, print log summary for each rank
for log in mpi_affinity_*.log; do
    echo "--- $log ---"
    grep Affinity $log
    grep "Running on CPU" $log
    echo
done
