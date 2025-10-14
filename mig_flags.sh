#!/bin/bash

usage() {
  echo "Usage: $0 [--enable|--delete|--create|--list]"
  echo "  --enable    Enable MIG mode on GPU 0 (alias: -e)"
  echo "  --delete    Delete old compute and GPU instances on GPU 0 (alias: -d)"
  echo "  --create    Create 7 partitions with profile 19 on GPU 0 (alias: -c)"
  echo "  --list      Show MIG profiles and current partitions (alias: -l)"
  exit 1
}

# Parse flags: support GNU-style long options and short aliases for compatibility.
# We don't rely on external getopt; handle arguments in a simple while loop.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable|-e)
      do_enable=true; shift ;;
    --delete|-d)
      do_delete=true; shift ;;
    --create|-c)
      do_create=true; shift ;;
    --list|-l)
      do_list=true; shift ;;
    --help|-h)
      usage ;;
    --)
      shift; break ;;
    *)
      echo "Unknown option: $1" >&2
      usage ;;
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