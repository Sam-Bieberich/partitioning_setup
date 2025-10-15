## Proposed SystemD method to bypass cgroups problems

First, create /etc/systemd/system/mig-job@.service -->

```
[Unit]
Description=MIG Isolated Job %i
After=multi-user.target

[Service]
Type=simple
User=%u
Environment="CUDA_VISIBLE_DEVICES="
# This gets populated by the launcher
ExecStart=/usr/local/bin/mig_job_runner.sh %i %I

# Restart policy
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

This should automatically assign the GPU as needed, then, 

```
systemctl start mig-job@0.service  # Starts on MIG 0
systemctl start mig-job@1.service  # Starts on MIG 1
```

## Alternative modules idea (easiest)

```
# Create module file for each MIG partition
# /usr/share/modulefiles/mig/0

prepend-path PATH /opt/mig/0/bin
setenv CUDA_VISIBLE_DEVICES MIG-51bda969-0e75-5012-970a-171635036ae8
setenv MIG_CPU_CORES 0-9
setenv MIG_INDEX 0
```

Then a user would run something like

```
module load mig/0
python train.py  # Automatically uses right GPU+CPUs
```
