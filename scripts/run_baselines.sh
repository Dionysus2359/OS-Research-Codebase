#!/bin/bash
# run_baselines.sh
# Automates the execution of all 4 Linux NUMA tiering baselines
# Usage: ./run_baselines.sh

set -e

# Get the absolute path of the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Absolute Paths
WORKLOAD_DIR="${PROJECT_ROOT}/workload"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_DIR="${PROJECT_ROOT}/results"

mkdir -p "$RESULTS_DIR"

# Helper to ensure system is clean
cleanup() {
    echo "[*] Cleaning up system state..."
    sudo killall daemon workload 2>/dev/null || true
    sudo rm -f /tmp/workload_info
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 2
}

run_daemon_baseline() {
    POLICY=$1
    echo "=================================================="
    echo "Running Baseline: $POLICY"
    echo "=================================================="
    cleanup
    
    # Ensure AutoNUMA is off for daemon-managed policies
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    
    # Start daemon in background (cout -> csv, cerr -> screen/log)
    sudo "$DAEMON_DIR/daemon" "$POLICY" > "$RESULTS_DIR/results_${POLICY}.csv" 2> "$RESULTS_DIR/stderr_${POLICY}.log" &
    DAEMON_PID=$!
    
    # Run workload
    cd "$WORKLOAD_DIR" && ./workload
    cd - > /dev/null
    
    # Wait for daemon to finish
    wait $DAEMON_PID
    echo "Saved to $RESULTS_DIR/results_${POLICY}.csv"
}

run_autonuma_baseline() {
    echo "=================================================="
    echo "Running Baseline: AutoNUMA (Kernel-managed)"
    echo "=================================================="
    cleanup
    
    # Enable AutoNUMA
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    
    cat /proc/vmstat | grep numa > "$RESULTS_DIR/autonuma_before.txt"
    numastat > "$RESULTS_DIR/autonuma_numastat_before.txt"
    
    # Run workload WITHOUT daemon
    cd "$WORKLOAD_DIR" && ./workload > "$RESULTS_DIR/autonuma_workload_stdout.log"
    cd - > /dev/null
    
    # Crucial Fix: Wait for asynchronous kernel threads (numad) to finish migrating queued pages
    echo "[*] Workload finished. Waiting for kernel AutoNUMA threads to flush..."
    sleep 2
    
    cat /proc/vmstat | grep numa > "$RESULTS_DIR/autonuma_after.txt"
    numastat > "$RESULTS_DIR/autonuma_numastat_after.txt"
    
    # Disable AutoNUMA again
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    
    echo "Saved AutoNUMA stats to $RESULTS_DIR/autonuma_after.txt"
}

# Compiling
echo "[*] Compiling workload and daemon..."
make -C "$WORKLOAD_DIR" clean && make -C "$WORKLOAD_DIR"
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR"

# Execute
run_daemon_baseline "lru"
run_daemon_baseline "lfu"
run_daemon_baseline "decaying_lfu"
run_autonuma_baseline
run_daemon_baseline "ml"

echo "=================================================="
echo "All baselines completed. Results in $RESULTS_DIR"
