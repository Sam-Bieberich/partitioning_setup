python3 -c "
import threading

def burn():
    while True:
        sum(range(10000000))

threads = []
for i in range(10):
    t = threading.Thread(target=burn)
    t.daemon = True
    t.start()
    threads.append(t)

# Keep main thread alive
import time
while True:
    time.sleep(1)
" &

PID=$!
echo "Started workload with PID: $PID"
echo $PID | sudo tee /sys/fs/cgroup/mig/mig0/cgroup.procs
sleep 2
htop