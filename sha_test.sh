# Heavy computation that can't be optimized

# If this script shows less than full usage, can assume that thermal throttling is occurring and should wait a bit
python3 -c "
import threading
import time
import hashlib

def burn():
    end_time = time.time() + 30
    counter = 0
    while time.time() < end_time:
        # Compute SHA256 hashes - very CPU intensive
        data = str(counter).encode()
        for _ in range(10000):
            hashlib.sha256(data).hexdigest()
        counter += 1

threads = []
for i in range(10):
    t = threading.Thread(target=burn)
    t.start()
    threads.append(t)

print('Running heavy CPU test for 30 seconds...')
for t in threads:
    t.join()
print('Done!')
" &

PID=$!
echo "Started PID: $PID"
echo $PID | sudo tee /sys/fs/cgroup/mig/mig0/cgroup.procs
sleep 2
htop