#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export LC_ALL=C
runs=${1:-100}
out=${2:-results/repeat-$(date +%Y%m%d-%H%M%S)-$$}
case $runs in ''|*[!0-9]*|0) echo 'Runs must be a positive integer.' >&2; exit 1;; esac
[ "$#" -le 2 ] || { echo 'Usage: sh tests/repeat.sh [RUNS [NEW_OUTPUT_DIR]]' >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
[ -x build/limit-run ] && [ -x build/load ] || { echo 'Run make first.' >&2; exit 1; }
mkdir -p "$(dirname "$out")"
mkdir "$out"
uname -a > "$out/system.txt"
sha256sum build/limit-run build/load tests/check.sh tests/repeat.sh > "$out/inputs.sha256"
groups() {
    for dir in /sys/fs/cgroup/limit-run-*; do
        [ ! -d "$dir" ] || printf '%s\n' "$dir"
    done | sort
}
groups > "$out/groups-before.txt"
echo 'run,script_exit,functional_ok,cpu_ok,run_ok,cpu_1_seconds,cpu_half_seconds,checksum_1,checksum_half' > "$out/runs.csv"
i=1
while [ "$i" -le "$runs" ]; do
    log=$(printf '%s/run-%03d.log' "$out" "$i")
    code=0
    sh tests/check.sh > "$log" 2>&1 || code=$?
    awk -v run="$i" -v code="$code" '
        /^All six functional checks passed\.$/ { functional++ }
        /^Quota: 1 core:$/ { part=1; headers1++; next }
        /^Quota: 0\.5 cores / { part=2; headers2++; next }
        part && /^checksum=/ {
            checks[part]++; checksum[part]=$0; next
        }
        part && /^exit=[0-9]+ elapsed=[0-9]+\.[0-9]+$/ {
            statuses[part]++
            split($1, a, "="); status[part]=a[2]
            split($2, a, "="); elapsed[part]=a[2]
        }
        END {
            functional_ok=(functional==1)
            cpu_ok=(headers1==1 && headers2==1 && checks[1]==1 && checks[2]==1 &&
               statuses[1]==1 && statuses[2]==1 && status[1]==0 && status[2]==0 &&
               elapsed[1]>0 && elapsed[2]>0 && checksum[1]==checksum[2])
            ok=(code==0 && functional_ok && cpu_ok)
            sub(/^checksum=/, "", checksum[1]); sub(/^checksum=/, "", checksum[2])
            printf "%d,%d,%d,%d,%d,%s,%s,%s,%s\n", run,code,functional_ok,cpu_ok,ok,
                   elapsed[1],elapsed[2],checksum[1],checksum[2]
        }
    ' "$log" >> "$out/runs.csv"
    printf 'Run %s/%s: exit=%s\n' "$i" "$runs" "$code"
    i=$((i + 1))
done
groups > "$out/groups-after.txt"
comm -13 "$out/groups-before.txt" "$out/groups-after.txt" > "$out/groups-left.txt"
left=$(awk 'END { print NR+0 }' "$out/groups-left.txt")
awk -F, -v requested="$runs" -v left="$left" '
    function add(k, x, delta) {
        n[k]++; delta=x-mean[k]; mean[k]+=delta/n[k]; m2[k]+=delta*(x-mean[k])
        if (n[k]==1 || x<lo[k]) lo[k]=x
        if (n[k]==1 || x>hi[k]) hi[k]=x
    }
    function stat(k) {
        if (n[k]) printf "%s,%d,%.3f,%.3f,%.3f,%.3f\n",k,n[k],mean[k],lo[k],hi[k],
                         (n[k]>1 ? sqrt(m2[k]/(n[k]-1)) : 0)
        else printf "%s,0,,,,\n",k
    }
    NR>1 {
        total++; functional+=$3; cpu+=$4; passed+=$5
        if ($5==1) {
            add("cpu_1_seconds",$6); add("cpu_half_seconds",$7)
            add("paired_slowdown",$7/$6)
        }
    }
    END {
        print "metric,count,mean,min,max,stddev"
        printf "runs_requested,%d,,,,\n",requested
        printf "runs_completed,%d,,,,\n",total
        printf "functional_suites_passed,%d,,,,\n",functional
        printf "cpu_pairs_passed,%d,,,,\n",cpu
        printf "runs_passed,%d,,,,\n",passed
        printf "runs_failed,%d,,,,\n",total-passed
        printf "new_groups_left,%d,,,,\n",left
        stat("cpu_1_seconds"); stat("cpu_half_seconds"); stat("paired_slowdown")
    }
' "$out/runs.csv" > "$out/summary.csv"
cat "$out/summary.csv"
printf 'Saved results: %s\n' "$out"
awk -F, -v requested="$runs" -v left="$left" '
    NR>1 { total++; if ($5!=1) bad++ }
    END { exit (total!=requested || bad || left!=0) }
' "$out/runs.csv"
