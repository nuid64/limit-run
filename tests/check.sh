#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$(id -u)" != 0 ]; then
    echo 'Run make first, then sudo sh tests/check.sh' >&2
    exit 1
fi

printf '+cpu +memory +pids\n' > /sys/fs/cgroup/cgroup.subtree_control
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo '1. The command runs in a group with the requested limits'
./build/limit-run 64 0.5 8 sh -c '
    IFS=: read -r hierarchy controllers path < /proc/self/cgroup
    dir=/sys/fs/cgroup$path
    cat "$dir/memory.max" "$dir/cpu.max" "$dir/pids.max"
' > "$tmp/limits"
grep -qx '67108864' "$tmp/limits"
grep -qx '50000 100000' "$tmp/limits"
grep -qx '8' "$tmp/limits"

echo '2. The command exit code is returned'
code=0
./build/limit-run 64 1 16 sh -c 'exit 7' || code=$?
[ "$code" = 7 ]

echo '3. Memory: 96 MiB fits within 128 MiB, but not within 32 MiB'
./build/limit-run 128 1 16 ./build/load memory > "$tmp/memory"
cat "$tmp/memory"
grep -qx 'allocated=96MiB' "$tmp/memory"
code=0
./build/limit-run 32 1 16 ./build/load memory || code=$?
[ "$code" = 137 ]

echo '4. Tasks: seven children succeed; the eighth fork is rejected'

code=0
./build/limit-run 64 1 8 ./build/load pids > "$tmp/pids" 2>&1 || code=$?
cat "$tmp/pids"

if [ "$code" = 1 ] &&
    grep -qx 'children=7' "$tmp/pids" &&
    grep -qx 'fork=EAGAIN' "$tmp/pids"; then
    echo 'PASS: seven children created; the eighth fork returned EAGAIN.'
else
    echo "FAIL: expected exit=1, children=7 and fork=EAGAIN; got exit=$code." >&2
    exit 1
fi

echo '5. SIGINT stops the command and removes its group'
./build/limit-run 64 1 16 sleep 30 &
runner=$!
sleep 0.1
kill -INT "$runner"
code=0
wait "$runner" || code=$?
[ "$code" = 130 ]
[ ! -d "/sys/fs/cgroup/limit-run-$runner" ]

echo '6. Background descendants are stopped and the group is removed'
./build/limit-run 64 1 16 sh -c 'sleep 30 &' &
runner=$!
wait "$runner"
[ ! -d "/sys/fs/cgroup/limit-run-$runner" ]

echo 'All six functional checks passed.'
echo
echo 'CPU timing comparison (manual, no pass/fail threshold)'
echo 'Quota: 1 core:'
./build/limit-run 64 1 16 ./build/load cpu
echo 'Quota: 0.5 cores (expected to take about twice as long):'
./build/limit-run 64 0.5 16 ./build/load cpu
