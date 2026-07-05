#!/bin/bash
# run_stream.sh — Run STREAM benchmarks with all tiering policies
# Usage: ./run_stream.sh
set -e

cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKLOAD_DIR="${PROJECT_ROOT}/workload"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_DIR="${PROJECT_ROOT}/results/stream"

mkdir -p "$RESULTS_DIR"

# Force PMU settings
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
echo 0 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null || true

# Build daemon
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR" LOCAL_DEV=1

cleanup() {
    sudo killall daemon 2>/dev/null || true
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 2
}

run_stream() {
    POLICY=$1   # lru, lfu, decaying_lfu, ml
    echo "=========================================="
    echo "STREAM | Policy: ${POLICY}"
    echo "=========================================="
    cleanup

    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true

    # Start STREAM workload
    numactl --membind=1 --cpubind=0 \
        "$WORKLOAD_DIR/stream" > "$RESULTS_DIR/stream_${POLICY}_stdout.log" &
    WL_PID=$!

    # Write a minimal workload_info so daemon can attach
    echo -e "${WL_PID}\n0x0\n1\n1" | sudo tee /tmp/workload_info > /dev/null

    # Start daemon
    sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$WL_PID" \
        > "$RESULTS_DIR/${POLICY}_summary.csv" \
        2> "$RESULTS_DIR/${POLICY}_stderr.log" &
    DAEMON_PID=$!

    wait $WL_PID 2>/dev/null || true
    sleep 2
    sudo kill $DAEMON_PID 2>/dev/null || true
    wait $DAEMON_PID 2>/dev/null || true

    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo "Done: STREAM_${POLICY}"
}

run_stream_autonuma() {
    echo "=========================================="
    echo "STREAM | Policy: autonuma"
    echo "=========================================="
    cleanup

    # ENABLE AutoNUMA
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null

    cat /proc/vmstat | grep numa > "$RESULTS_DIR/stream_autonuma_vmstat_before.txt"
    numastat > "$RESULTS_DIR/stream_autonuma_numastat_before.txt"

    # Start STREAM workload WITHOUT daemon
    /usr/bin/time -v numactl --membind=1 --cpubind=0 \
        "$WORKLOAD_DIR/stream" > "$RESULTS_DIR/stream_autonuma_stdout.log" 2>&1

    echo "[*] Workload finished. Waiting for kernel AutoNUMA threads to flush..."
    sleep 2

    cat /proc/vmstat | grep numa > "$RESULTS_DIR/stream_autonuma_vmstat_after.txt"
    numastat > "$RESULTS_DIR/stream_autonuma_numastat_after.txt"

    # DISABLE AutoNUMA
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    echo "Done: STREAM_autonuma"
}

# Run STREAM with all policies
for POLICY in lru lfu decaying_lfu ml; do
    run_stream "$POLICY"
done

run_stream_autonuma

echo "=========================================="
echo "All STREAM baselines complete. Results in $RESULTS_DIR"
