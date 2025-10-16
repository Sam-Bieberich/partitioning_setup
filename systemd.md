```
sudo systemctl set-property mig0.slice AllowedCPUs=0-9
sudo systemctl set-property mig1.slice AllowedCPUs=10-19
sudo systemctl set-property mig2.slice AllowedCPUs=20-29
sudo systemctl set-property mig3.slice AllowedCPUs=30-39
sudo systemctl set-property mig4.slice AllowedCPUs=40-49
sudo systemctl set-property mig5.slice AllowedCPUs=50-59
sudo systemctl set-property mig6.slice AllowedCPUs=60-71
```

Then, to launch  ajob, 

```
sudo systemd-run --slice=mig0.slice --setenv=CUDA_VISIBLE_DEVICES=<MIG_UUID_0> python3 myjob.py
sudo systemd-run --slice=mig1.slice --setenv=CUDA_VISIBLE_DEVICES=<MIG_UUID_1> python3 myjob.py
# ...repeat for each slice/MIG
```