#!/usr/bin/env bash
# manual_partition.sh
# Create 7 cpuset partitions using the machine's available CPUs (read from cgroups).
# Requires root and a cpuset cgroup controller mounted (v1 or v2).

set -euo pipefail

# locate cpuset root (v1: /sys/fs/cgroup/cpuset, v2 may expose cpuset files in /sys/fs/cgroup)
if [ -d /sys/fs/cgroup/cpuset ]; then
    CGROOT=/sys/fs/cgroup/cpuset
else
    CGROOT=/sys/fs/cgroup
fi

# prefer cpuset.cpus, fallback to cpuset.cpus.effective, fallback to nproc
CPUS_FILE=""
for f in cpuset.cpus cpuset.cpus.effective; do
    if [ -f "$CGROOT/$f" ]; then
        CPUS_FILE="$CGROOT/$f"
        break
    fi
done

if [ -z "$CPUS_FILE" ]; then
    echo "warning: cpuset files not found under $CGROOT, falling back to nproc"
    cpu_list="$(seq 0 $(( $(nproc) - 1 )) | paste -sd',' -)"
else
    cpu_list="$(tr -d '[:space:]' < "$CPUS_FILE")"
fi

# get root cpuset.mems if available (needed for v1 cpuset)
MEMS="0"
if [ -f "$CGROOT/cpuset.mems" ]; then
    MEMS="$(tr -d '[:space:]' < "$CGROOT/cpuset.mems")"
fi

# expand a cpuset string like "0-3,5,7-9" into an array of individual CPU ids
expand_cpuset() {
    local s=$1
    local -a out=()
    IFS=',' read -ra parts <<< "$s"
    for p in "${parts[@]}"; do
        if [[ "$p" == *-* ]]; then
            IFS='-' read -r a b <<< "$p"
            for ((i=a; i<=b; i++)); do out+=("$i"); done
        elif [ -n "$p" ]; then
            out+=("$p")
        fi
    done
    printf "%s\n" "${out[@]}"
}

mapfile -t ALL_CPUS < <(expand_cpuset "$cpu_list")
TOTAL=${#ALL_CPUS[@]}

if [ "$TOTAL" -eq 0 ]; then
    echo "no CPUs detected (total=0). abort."
    exit 1
fi

PARTS=7
BASE=$(( TOTAL / PARTS ))
REM=$(( TOTAL % PARTS ))

if [ "$BASE" -eq 0 ]; then
    echo "not enough CPUs ($TOTAL) to make $PARTS partitions with at least 1 CPU each."
    exit 1
fi

PARENT="$CGROOT/partitions_by_7"
mkdir -p "$PARENT"

# create partitions, distributing remainder (+1) to the first REM partitions
idx=0
for i in $(seq 0 $((PARTS-1))); do
    cnt=$BASE
    if [ "$i" -lt "$REM" ]; then
        cnt=$((cnt+1))
    fi

    if [ "$cnt" -le 0 ]; then
        echo "partition $i would have 0 CPUs; skipping"
        continue
    fi

    # build cpu list for this partition
    cpus_for_part=()
    for ((j=0; j<cnt; j++)); do
        cpus_for_part+=("${ALL_CPUS[idx]}")
        idx=$((idx+1))
    done

    cpulist=$(printf "%s," "${cpus_for_part[@]}")
    cpulist=${cpulist%,}  # drop trailing comma

    d="$PARENT/part$i"
    mkdir -p "$d"

    # write cpuset settings (requires root)
    if [ -w "$d" ] || [ ! -e "$d" ]; then
        :
    fi

    if [ -f "$d/cpuset.cpus" ] || [ -w "$CGROOT" ]; then
        # set mems if available
        if [ -f "$d/cpuset.mems" ]; then
            echo "$MEMS" > "$d/cpuset.mems" || true
        elif [ -f "$CGROOT/cpuset.mems" ]; then
            # attempt to create file by writing to new dir
            echo "$MEMS" > "$d/cpuset.mems" || true
        fi

        # write cpus
        if [ -f "$d/cpuset.cpus" ] || [ -w "$CGROOT" ]; then
            echo "$cpulist" > "$d/cpuset.cpus" || {
                echo "failed to write cpuset.cpus to $d (permission?)"
            }
        else
            echo "cannot write cpuset.cpus in $d (no writable interface)"
        fi
    else
        echo "no cpuset interface visible in $d; skipping"
    fi

    echo "created $d : cpus=$cpulist mems=$MEMS"
done

echo "done. total cpus=$TOTAL; base per partition=$BASE; remainder distributed to first $REM partitions"