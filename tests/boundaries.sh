#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
runs=${1:-20}
out=${2:-results/boundaries-$(date +%Y%m%d-%H%M%S)-$$}
case $runs in ''|*[!0-9]*|0) echo 'Runs must be a positive integer.' >&2; exit 1;; esac
[ "$#" -le 2 ] || { echo 'Usage: sh tests/boundaries.sh [RUNS [NEW_OUTPUT_DIR]]' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
[ -x build/limit-run ] && [ -x build/load ] || { echo 'Run make first.' >&2; exit 1; }
mkdir -p "$(dirname "$out")"
mkdir "$out"
uname -a > "$out/system.txt"
sha256sum build/limit-run build/load tests/boundaries.sh > "$out/inputs.sha256"
groups() {
    for dir in /sys/fs/cgroup/limit-run-*; do
        [ ! -d "$dir" ] || printf '%s\n' "$dir"
    done | sort
}
groups > "$out/groups-before.txt"
printf '+cpu +memory +pids\n' > /sys/fs/cgroup/cgroup.subtree_control
echo 'run,resource,limit,expected_exit,actual_exit,ok' > "$out/runs.csv"
i=1
while [ "$i" -le "$runs" ]; do
    for limit in 32 64 128 256; do
        expected=0
        [ "$limit" -ge 96 ] || expected=137
        log="$out/memory-$limit-$i.log"
        code=0
        ./build/limit-run "$limit" 1 16 ./build/load memory > "$log" 2>&1 || code=$?
        ok=0
        if [ "$code" = "$expected" ]; then
            if [ "$expected" != 0 ] || grep -qx 'allocated=96MiB' "$log"; then ok=1; fi
        fi
        printf '%s,memory,%s,%s,%s,%s\n' "$i" "$limit" "$expected" "$code" "$ok" >> "$out/runs.csv"
    done
    for limit in 2 4 8; do
        log="$out/pids-$limit-$i.log"
        code=0
        ./build/limit-run 64 1 "$limit" ./build/load pids > "$log" 2>&1 || code=$?
        ok=0
        if [ "$code" = 1 ] && grep -qx "children=$((limit - 1))" "$log" &&
            grep -qx 'fork=EAGAIN' "$log"; then ok=1; fi
        printf '%s,pids,%s,1,%s,%s\n' "$i" "$limit" "$code" "$ok" >> "$out/runs.csv"
    done
    printf 'Boundary round %s/%s completed.\n' "$i" "$runs"
    i=$((i + 1))
done
groups > "$out/groups-after.txt"
comm -13 "$out/groups-before.txt" "$out/groups-after.txt" > "$out/groups-left.txt"
awk -F, '
    NR>1 { k=$2 SUBSEP $3; count[k]++; passed[k]+=$6; expected[k]=$4 }
    END {
        print "resource,limit,expected_exit,passed,runs"
        for (k in count) {
            split(k,a,SUBSEP)
            printf "%s,%s,%s,%d,%d\n",a[1],a[2],expected[k],passed[k],count[k]
        }
    }
' "$out/runs.csv" > "$out/summary.csv"
cat "$out/summary.csv"
printf 'Saved results: %s\n' "$out"
[ ! -s "$out/groups-left.txt" ] || { echo 'FAIL: new cgroups remain.' >&2; exit 1; }
awk -F, -v expected="$((runs * 7))" '
    NR>1 { total++; if ($6!=1) bad++ }
    END { exit (total!=expected || bad) }
' "$out/runs.csv"
