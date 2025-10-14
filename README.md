# Partitioning setup files

## File Explanations

* Run the mig_setup_7.sh bash file to create seven equal partitions of the GPU on a node. Requires sudo access. To test that sudo works, you can run sudo -v

## Check version of cgroups 

stat -fc %T /sys/fs/cgroup/   #If the output is cgroup2fs, it means cgroup v2 is in use; if it is tmpfs, it means cgroup v1 is in use
