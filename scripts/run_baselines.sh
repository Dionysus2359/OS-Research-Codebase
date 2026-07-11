#!/bin/bash
# run_baselines.sh
# Automates the execution of all Linux NUMA tiering baselines on Bare Metal
# Usage: ./run_baselines.sh

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
RESULTS_DIR="${PROJECT_ROOT}/results"

mkdir -p "$RESULTS_DIR"

# Force the kernel ceiling up and disable PMU auto-throttling
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
echo 0 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null || true

cleanup() {
    echo "[*] Cleaning up system state..."
    sudo killall daemon 2>/dev/null || true
    sudo rm -f /tmp/workload_info
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 2
}

run_daemon_baseline() {
    POLICY=$1
    echo "=========================================="
    echo "Running Baseline: $POLICY"
    echo "=========================================="
    cleanup

    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true

    # Start workload in background (bound to Node 1 memory, Node 0 CPU)
    numactl --membind=1 --cpubind=0 "$WORKLOAD_DIR/workload" &
    WORKLOAD_PID=$!
    
    # Wait for workload_info to appear
    for i in $(seq 1 20); do
        [ -f /tmp/workload_info ] && break
        sleep 0.25
    done

    # Start daemon with workload PID
    sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$WORKLOAD_PID" \
        --slow-node 1 --fast-tier-capacity 410 --max-promotions 256 --max-demotions 256 \
        > "$RESULTS_DIR/${POLICY}_summary.csv" \
        2> "$RESULTS_DIR/${POLICY}_stderr.log" &
    DAEMON_PID=$!

    # Wait for workload to finish
    wait $WORKLOAD_PID 2>/dev/null || true
    sleep 2
    sudo kill $DAEMON_PID 2>/dev/null || true
    wait $DAEMON_PID 2>/dev/null || true
    
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
    echo "Baseline $POLICY complete."
}

run_autonuma_baseline() {
    echo "=================================================="
    echo "Running Baseline: AutoNUMA (Kernel-managed)"
    echo "=================================================="
    cleanup
    
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
    
    cat /proc/vmstat | grep numa > "$RESULTS_DIR/autonuma_before.txt"
    numastat > "$RESULTS_DIR/autonuma_numastat_before.txt"
    
    # Run workload locally WITHOUT daemon
    numactl --membind=1 --cpubind=0 "$WORKLOAD_DIR/workload" \
        > "$RESULTS_DIR/autonuma_workload_stdout.log"
    
    echo "[*] Workload finished. Waiting for kernel AutoNUMA threads to flush..."
    sleep 2
    
    cat /proc/vmstat | grep numa > "$RESULTS_DIR/autonuma_after.txt"
    numastat > "$RESULTS_DIR/autonuma_numastat_after.txt"
    
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
    echo "Saved AutoNUMA stats to $RESULTS_DIR/autonuma_after.txt"
}

# ---- Build Phase ----
echo "[*] Compiling workload and daemon..."
make -C "$WORKLOAD_DIR" clean && make -C "$WORKLOAD_DIR"
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR"

sudo mkdir -p /root/results

# ---- Execute Baselines ----
run_daemon_baseline "lru"
run_daemon_baseline "lfu"
run_daemon_baseline "decaying_lfu"
run_autonuma_baseline
run_daemon_baseline "ml"

echo "=================================================="
echo "All baselines completed. Results in $RESULTS_DIR"
