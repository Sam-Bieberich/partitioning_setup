"""
cpu_partition_stress.py
Fully loads all CPUs in the current affinity set (as defined by systemd slice/cgroup).
Each worker pins itself to one allowed CPU and runs a busy loop.
Usage: python3 cpu_partition_stress.py
Recommended: run inside a systemd slice.
"""
import os
import time
import threading
import socket

try:
    affinity = sorted(os.sched_getaffinity(0))
except Exception:
    affinity = list(range(os.cpu_count()))

hostname = socket.gethostname()
pid = os.getpid()
print(f"Host: {hostname} PID: {pid}")
print(f"Allowed CPUs (affinity): {affinity}")
print(f"Launching {len(affinity)} workers (one per allowed CPU)")

# Worker function: pin to a CPU and burn cycles

def cpu_burner(cpu):
    try:
        os.sched_setaffinity(0, {cpu})
    except Exception:
        pass
    t0 = time.time()
    while time.time() - t0 < 20:  # Run for 20 seconds
        _ = sum(range(10000))

threads = []
for cpu in affinity:
    t = threading.Thread(target=cpu_burner, args=(cpu,), daemon=True)
    t.start()
    threads.append(t)

for t in threads:
    t.join()

print("Done. All allowed CPUs should have been loaded for 20 seconds.")
print("Check with mpstat or sar logs to confirm only these CPUs were busy.")
