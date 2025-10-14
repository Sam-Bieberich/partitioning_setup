# Partitioning setup files

## File Explanations

* Run the mig_setup_7.sh bash file to create seven equal partitions of the GPU on a node. Requires sudo access. To test that sudo works, you can run sudo -v
* Run the cgroups_claude.sh bash file with sudo to create 7 partitions of the CPU, which are then connected with the 7 MIG partitions from earlier. MIG must be set up already for this file to run. 
* Basic usage of mig_launcher.sh:

```
./mig_launcher.sh <mig_instance_number> <your_command>
```

Examples:
```
./mig_launcher.sh 0 python train.py           # Run on MIG 0
./mig_launcher.sh 1 python inference.py       # Run on MIG 1
./mig_launcher.sh -d 2 python job.py          # Run on MIG 2 in background
./mig_launcher.sh -v 3 python debug.py        # Run on MIG 3 with verbose output
```



### Check version of cgroups 

```stat -fc %T /sys/fs/cgroup/```   

If the output is cgroup2fs, it means cgroup v2 is in use; if it is tmpfs, it means cgroup v1 is in use

### Check that CPU partitioning is online

```
for i in {0..6}; do
    echo "MIG $i CPUs: $(cat /sys/fs/cgroup/mig/mig$i/cpuset.cpus)"
done
```