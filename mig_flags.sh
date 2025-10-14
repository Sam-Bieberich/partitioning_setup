#!/bin/bash

usage() {
  echo "Usage: $0 [-e] [-d] [-c] [-l]"
  echo "  -e  Enable MIG mode on GPU 0"
  echo "  -d  Delete old compute and GPU instances on GPU 0"
  echo "  -c  Create 7 partitions with profile 19 on GPU 0"
  echo "  -l  Show MIG profiles and current partitions"
  exit 1
}

# Parse flags
while getopts "edcl" opt; do
  case $opt in
    e) do_enable=true ;;
    d) do_delete=true ;;
    c) do_create=true ;;
    l) do_list=true ;;
    *) usage ;;
  esac
done

if [ "$do_enable" = true ]; then
  echo "Starting MIG setup: enabling MIG on GPU 0"
  sudo nvidia-smi -i 0 -mig 1
  echo "--------------------------"
fi

if [ "$do_delete" = true ]; then
  echo "Deleting any old MIG instances on GPU 0"
  sudo nvidia-smi mig -dci -i 0   # Delete all compute instances
  sudo nvidia-smi mig -dgi -i 0   # Delete all GPU instances
  echo "--------------------------"
fi

if [ "$do_create" = true ]; then
  echo "Creating 7 partitions with profile 19 on GPU 0"
  sudo nvidia-smi mig -cgi 19,19,19,19,19,19,19 -C
  echo "--------------------------"
fi

if [ "$do_list" = true ]; then
  echo "MIG Profiles"
  nvidia-smi mig -lgip
  echo "--------------------------"
  echo "Confirming partitions"
  nvidia-smi -L
  echo "--------------------------"
fi

# If no flags provided, show usage
if [ $# -eq 0 ]; then
  usage
fi