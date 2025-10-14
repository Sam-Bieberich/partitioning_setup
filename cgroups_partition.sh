echo "Starting cgroups setup (7 partitions)"

#!/usr/bin/env bash
#
# setup_cpu_mig_partitions.sh
#
# Hard-isolate CPUs into 7 cpuset cgroups (cgroup v2) and map each to one NVIDIA MIG device.
# Requires: sudo on this node, cgroup v2 mounted, NVIDIA driver + nvidia-smi (for MIG).
#
# USAGE (setup only):
#   sudo bash setup_cpu_mig_partitions.sh
#
# Launching workloads afterwards:
#   Use helper: run_in_partition <1..7> -- <your command and args>
#
# NOTES / REFERENCES:
# - cgroup v2 basics, controllers & cpusets: https://docs.kernel.org/admin-guide/cgroup-v2.html
# - Enable controllers top-down; cpuset requires cpuset.cpus & cpuset.mems set before attaching tasks.
# - MIG overview & management via nvidia-smi: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html
# - List MIG devices with UUIDs: `nvidia-smi -L`
# - CUDA enumerates one MIG compute instance per process (use one process per MIG): see NVIDIA forum/StackOverflow.

set -euo pipefail

PARTS=7
CGROOT="/sys/fs/cgroup"                 # cgroup v2 mountpoint
PARENT="${CGROOT}/mig-cpu"              # parent cgroup for our partitions
STATE_DIR="${PARENT}/.state"            # internal state/notes
mkdir -p "${STATE_DIR}" || true

GPU_INDEX="${GPU_INDEX:-0}"
ENABLE_MIG_CREATE="${ENABLE_MIG_CREATE:-0}"
MIG_PROFILE_ID="${MIG_PROFILE_ID:-}"    # Leave empty to skip creation; set numeric ID from `nvidia-smi mig -lgip`

log() { echo "[info] $*" >&2; }
warn() { echo "[warn] $*" >&2; }
die() { echo "[err ] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# --- Sanity checks -----------------------------------------------------------
# cgroup v2?
if ! mount | grep -q "cgroup2 on ${CGROOT}"; then
  die "cgroup v2 not mounted at ${CGROOT}. See vendor docs to enable unified hierarchy."
fi

# We need to be root to write cgroup fs and to configure MIG
if [[ $EUID -ne 0 ]]; then
  die "Please run as root: sudo bash $0"
fi

# --- Enable cpuset controller for children on root (top-down rule) ----------
# In v2, controllers are enabled in parent cgroup.subtree_control to appear in children.
# Ref: cgroup v2 docs (top-down constraints / subtree_control)
if ! grep -qw cpuset "${CGROOT}/cgroup.controllers"; then
  die "cpuset controller not available on this kernel. (Check CONFIG_CPUSETS and v2 support)"
fi

if ! grep -qw cpuset "${CGROOT}/cgroup.subtree_control"; then
  log "Enabling +cpuset in ${CGROOT}/cgroup.subtree_control"
  echo +cpuset > "${CGROOT}/cgroup.subtree_control"
fi

# --- Create parent cgroup and make it a cpuset partition root ----------------
mkdir -p "${PARENT}"

# Determine all online CPUs and NUMA nodes.
# cpuset requires cpuset.mems and cpuset.cpus be set before attaching tasks.
ALL_CPUS=$(seq -s, 0 $(( $(nproc) - 1 )))
if [[ -f /sys/devices/system/node/online ]]; then
  MEMS=$(cat /sys/devices/system/node/online)
else
  MEMS=0
fi

echo "${MEMS}" > "${PARENT}/cpuset.mems"
# Prefer contiguous range format "0-N" where possible
if [[ $(nproc) -gt 0 ]]; then
  echo "0-$(( $(nproc) - 1 ))" > "${PARENT}/cpuset.cpus"
fi

# Try to set this cgroup as a partition root for cpuset; prefer 'isolated' if supported.
# Some kernels don't support 'isolated' yet; fall back to 'root'.
if [[ -w "${PARENT}/cpuset.cpus.partition" ]]; then
  if echo isolated > "${PARENT}/cpuset.cpus.partition" 2>/dev/null; then
    log "Partition root set to 'isolated' (no scheduler LB within this partition)."
  else
    echo root > "${PARENT}/cpuset.cpus.partition"
    log "Partition root set to 'root' (kernel doesn't accept 'isolated')."
  fi
else
  warn "cpuset.cpus.partition not writable; proceeding without marking partition root."
fi

# --- Compute 7 balanced CPU subsets -----------------------------------------
N=$(nproc)
P=${PARTS}
if (( N < P )); then
  warn "Only ${N} logical CPUs available; will create ${N} partitions instead of ${P}."
  P=${N}
fi

BASE=$(( N / P ))
REM=$(( N % P ))

cpu_range() {
  local start=$1
  local len=$2
  local end=$(( start + len - 1 ))
  if (( len <= 0 )); then
    echo ""
  elif (( len == 1 )); then
    echo "${start}"
  else
    echo "${start}-${end}"
  fi
}

log "Creating ${P} cpuset children under ${PARENT}"
start=0
for i in $(seq 1 ${P}); do
  size=${BASE}
  if (( i <= REM )); then size=$(( size + 1 )); fi
  range=$(cpu_range "${start}" "${size}")
  CG="${PARENT}/part${i}"
  mkdir -p "${CG}"

  # Inherit mems from parent; set CPUs for this partition
  echo "${MEMS}" > "${CG}/cpuset.mems"
  echo "${range}" > "${CG}/cpuset.cpus"

  log "  part${i}: cpus=${range} mems=${MEMS}"
  start=$(( start + size ))
done

# --- Collect MIG UUIDs and map them 1..P ------------------------------------
# List MIG instances and store their UUIDs in state file in a stable order.
# `nvidia-smi -L` prints lines like: MIG 1g.5gb Device 2: (UUID: MIG-xxxx)
MIG_LIST="${STATE_DIR}/mig_uuids.txt"
nvidia-smi -L | awk -F 'UUID: ' '/MIG/ {print $2}' | tr -d ')' > "${MIG_LIST}" || true

MIG_COUNT=$(wc -l < "${MIG_LIST}" || echo 0)
if (( MIG_COUNT < P )); then
  warn "Found ${MIG_COUNT} MIG device(s), but ${P} CPU partitions. Mapping will be partial."
else
  log "Mapped MIG UUIDs recorded in: ${MIG_LIST}"
fi

# --- Helper function file to run a command in a given partition + MIG device -
HELPER="${PARENT}/run_in_partition"
cat > "${HELPER}" <<'EOF'

#!/usr/bin/env bash
# run_in_partition <index 1..7> -- <cmd ...>
#  - moves the target process into cpuset cgroup /sys/fs/cgroup/mig-cpu/part<index>
#  - sets CUDA_VISIBLE_DEVICES to the MIG UUID #<index> (if available)
set -euo pipefail
CGROOT="/sys/fs/cgroup"
PARENT="${CGROOT}/mig-cpu"
STATE="${PARENT}/.state"
MIG_LIST="${STATE}/mig_uuids.txt"

usage() { echo "Usage: $(basename $0) <1..7> -- <command...>"; exit 2; }

(( $# >= 3 )) || usage
IDX="$1"; shift
[[ "$1" == "--" ]] || usage
shift

CG="${PARENT}/part${IDX}"
[[ -d "${CG}" ]] || { echo "[err ] partition ${IDX} not found"; exit 1; }

# Launch command in background, then move its PID into the cpuset cgroup, then wait.
# (Writing to cgroup.procs moves *all threads* of that process in cgroup v2.)
"$@" & PID=$!

# Attach to CPU partition
echo "${PID}" > "${CG}/cgroup.procs"

# Set CUDA_VISIBLE_DEVICES if we have a MIG UUID at that index.
if [[ -f "${MIG_LIST}" ]]; then
  UUID=$(sed -n "${IDX}p" "${MIG_LIST}" || true)
  if [[ -n "${UUID}" ]]; then
    # Re-exec the process with CUDA_VISIBLE_DEVICES set by sending it an env update is not trivial.
    # Instead, we export here for any child shells; for direct commands, prefer wrapper style:
    #   run_in_partition N -- env CUDA_VISIBLE_DEVICES=$UUID your_cmd ...
    echo "[info] Suggested CUDA_VISIBLE_DEVICES=${UUID} for partition ${IDX}"
  fi
fi

wait "${PID}"
EOF
chmod +x "${HELPER}"

log "Done. Use: ${HELPER} <1..${P}> -- <cmd ...>"
echo
log "TIP: To *force* a given MIG instance, run:"
log "  UUID=\$(sed -n '1p' ${MIG_LIST}); ${HELPER} 1 -- env CUDA_VISIBLE_DEVICES=\$UUID your_program"
echo
log "REMEMBER: one process per MIG instance; CUDA exposes only one compute instance per process."