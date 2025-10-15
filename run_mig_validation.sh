#!/usr/bin/env bash
set -euo pipefail
CG_BASE="/sys/fs/cgroup/mig"
LOGDIR="${LOGDIR:-./mig_validate_logs}"
mkdir -p "$LOGDIR"

# 1) Discover MIG devices (UUIDs) in order
mapfile -t MIGS < <(nvidia-smi -L | awk -F'[()]' '/MIG/{for(i=1;i<=NF;i++) if($i ~ /^UUID: /){sub(/^UUID: /,"",$i); print $i}}')
if [ ${#MIGS[@]} -ne 7 ]; then
  echo "Expected 7 MIG instances, found ${#MIGS[@]}"; exit 1
fi

# 2) Discover CPU cgroups and CPU ranges
for i in {0..6}; do
  CG="$CG_BASE/mig$i"
  if [ ! -d "$CG" ]; then echo "Missing cgroup $CG"; exit 1; fi
  CPUS[$i]=$(cat "$CG/cpuset.cpus")
  MEMS[$i]=$(cat "$CG/cpuset.mems")
done

echo "== MIG UUIDs =="
printf "%s\n" "${MIGS[@]}"
echo "== CPU cpus per cgroup =="
for i in {0..6}; do echo "mig$i: ${CPUS[$i]} (mems ${MEMS[$i]})"; done

# 3) Helper to launch one job on a given pair
run_one () {
  local idx=$1; shift
  local tag=$1; shift
  local cmd=("$@")
  local cg="$CG_BASE/mig$idx"
  local uuid="${MIGS[$idx]}"
  CUDA_VISIBLE_DEVICES="$uuid" "${cmd[@]}" &> "$LOGDIR/${tag}_mig${idx}.log" &
  local pid=$!
  echo $pid > "$cg/cgroup.procs"
  echo "Started $tag on MIG[$idx]=$uuid  PID=$pid  CPUs=${CPUS[$idx]}"
  echo $pid
}

pids=()

# 4a) Single-slice check (compute then bandwidth) – run on mig0
echo "== SINGLE-SLICE CHECK =="
pids+=("$(run_one 0 gemm ./cublas_gemm)")
wait "${pids[@]}"
pids=()
pids+=("$(run_one 0 bstream ./BabelStream/build/cuda-stream --arraysize 134217728)")
wait "${pids[@]}"
pids=()

# 4b) Seven-way concurrent compute test
echo "== 7-WAY CONCURRENT GEMM =="
for i in {0..6}; do pids+=("$(run_one $i gemm7 ./cublas_gemm)"); done
wait "${pids[@]}"
pids=()

# 4c) Seven-way concurrent bandwidth test
echo "== 7-WAY CONCURRENT BABELSTREAM =="
for i in {0..6}; do pids+=("$(run_one $i bstream7 ./BabelStream/build/cuda-stream --arraysize 134217728)"); done
wait "${pids[@]}"

echo "Logs in $LOGDIR:"
ls -1 "$LOGDIR"