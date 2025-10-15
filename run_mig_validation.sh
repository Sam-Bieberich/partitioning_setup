#!/usr/bin/env bash
set -euo pipefail

CG_BASE="/sys/fs/cgroup/mig"
LOGDIR="${LOGDIR:-./mig_validate_logs}"
mkdir -p "$LOGDIR"

# Use sudo automatically if not root
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; else SUDO=""; fi

# --- MIG discovery: keep as-is ---
mapfile -t MIGS < <(nvidia-smi -L | awk -F'[()]' '/MIG/{for(i=1;i<=NF;i++) if($i ~ /^UUID: /){sub(/^UUID: /,"",$i); print $i}}')
if [ ${#MIGS[@]} -ne 7 ]; then
  echo "Expected 7 MIG instances, found ${#MIGS[@]}"; exit 1
fi

# --- CPU sets: keep as-is ---
for i in {0..6}; do
  CG="$CG_BASE/mig$i"
  if [ ! -d "$CG" ]; then echo "Missing cgroup $CG"; exit 1; fi
  CPUS[$i]=$(cat "$CG/cpuset.cpus")
  MEMS[$i]=$(cat "$CG/cpuset.mems")
done
echo "== MIG UUIDs =="; printf "%s\n" "${MIGS[@]}"
echo "== CPU cpus per cgroup =="; for i in {0..6}; do echo "mig$i: ${CPUS[$i]} (mems ${MEMS[$i]})"; done

# --- Launch a job on one MIG+CPU pair ---
run_one () {
  local idx=$1; shift
  local tag=$1; shift
  local cg="$CG_BASE/mig$idx"
  local uuid="${MIGS[$idx]}"
  local cpus="${CPUS[$idx]}"

  # Launch detached; capture PID
  CUDA_VISIBLE_DEVICES="$uuid" "$@" &> "$LOGDIR/${tag}_mig${idx}.log" &
  local pid=$!

  # Move process into the cgroup (must be root; use tee so redirection has root perms)
  printf "%s\n" "$pid" | $SUDO tee "$cg/cgroup.procs" >/dev/null

  # Human-readable status to stderr (so stdout only contains the PID)
  >&2 echo "Started $tag on MIG[$idx]=$uuid  PID=$pid  CPUs=$cpus"

  # Print only the PID on stdout for the caller to capture
  echo "$pid"
}

pids=()

echo "== SINGLE-SLICE CHECK =="
# Single GEMM on mig0
pid="$(run_one 0 gemm ./cublas_gemm)"
pids+=("$pid")
wait "${pids[@]}"
pids=()

# Single BabelStream on mig0
pid="$(run_one 0 bstream ./BabelStream/build/cuda-stream --arraysize 134217728)"
pids+=("$pid")
wait "${pids[@]}"
pids=()

echo "== 7-WAY CONCURRENT GEMM =="
for i in {0..6}; do
  pid="$(run_one $i gemm7 ./cublas_gemm)"
  pids+=("$pid")
done
wait "${pids[@]}"
pids=()

echo "== 7-WAY CONCURRENT BABELSTREAM =="
for i in {0..6}; do
  pid="$(run_one $i bstream7 ./BabelStream/build/cuda-stream --arraysize 134217728)"
  pids+=("$pid")
done
wait "${pids[@]}"

echo "Logs in $LOGDIR:"
ls -1 "$LOGDIR"