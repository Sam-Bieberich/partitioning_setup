# Run for 30 seconds then exit automatically
python3 -c "
import threading
import time

def burn():
    end_time = time.time() + 30
    while time.time() < end_time:
        sum(range(10000000))

threads = []
for i in range(10):
    t = threading.Thread(target=burn)
    t.start()
    threads.append(t)

for t in threads:
    t.join()

print('Test complete!')
" &

PID=$!
echo "Started workload with PID: $PID (will run for 30 seconds)"
echo $PID | sudo tee /sys/fs/cgroup/mig/mig0/cgroup.procs
sleep 2
htop