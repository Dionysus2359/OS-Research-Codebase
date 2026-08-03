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
RESULTS_BASE="${PROJECT_ROOT}/results/synthetic"

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

    # Compute adjusted FTC for synthetic workload
    FTC=410
    if [ "$FTC_RATIO" != "100" ]; then
        FTC=$((FTC * FTC_RATIO / 100))
    fi

    # Start daemon with workload PID
    DAEMON_ARGS=("--slow-node" "1" "--fast-tier-capacity" "$FTC" "--max-promotions" "256" "--max-demotions" "256" "--epoch-ms" "$EPOCH_MS")
    if [ "$TRACE_MODE" == "true" ]; then
        DAEMON_ARGS+=("--trace" "--trace-dir" "${PROJECT_ROOT}/ml/traces")
    fi

    sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$WORKLOAD_PID" "${DAEMON_ARGS[@]}" \
        > "$RESULTS_DIR/${POLICY}_summary.csv" \
        2> "$RESULTS_DIR/${POLICY}_stderr.log" &
    DAEMON_PID=$!

    # Wait for workload to finish
    wait $WORKLOAD_PID 2>/dev/null || true
    sleep 2
    sudo kill -SIGINT $DAEMON_PID 2>/dev/null || true
    wait $DAEMON_PID 2>/dev/null || true
    if [ "$TRACE_MODE" == "true" ]; then
        REAL_USER=${SUDO_USER:-$USER}
        sudo chown $REAL_USER:$REAL_USER "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" 2>/dev/null || true
        mv "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" "${PROJECT_ROOT}/ml/traces/trace_${POLICY}_synthetic.csv" 2>/dev/null || true
    fi
    
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
    
    # Run workload locally WITHOUT daemon (start on Node 1 CPU)
    taskset -c 1 "$WORKLOAD_DIR/workload" \
        > "$RESULTS_DIR/autonuma_workload_stdout.log" &
    WORKLOAD_PID=$!
    
    # Wait for memory initialization to complete
    for i in $(seq 1 20); do
        [ -f /tmp/workload_info ] && break
        sleep 0.25
    done
    
    # Instantly yank CPU affinity back to Node 0
    taskset -a -pc 0 $WORKLOAD_PID > /dev/null
    
    wait $WORKLOAD_PID 2>/dev/null || true
    
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

TRACE_MODE=false
ML_ONLY=false
FTC_RATIO=100
EPOCH_MS=100

while [ $# -gt 0 ]; do
    case "$1" in
        --trace) TRACE_MODE=true; mkdir -p "${PROJECT_ROOT}/ml/traces" ;;
        --ml-only) ML_ONLY=true ;;
        --runs) NUM_RUNS="$2"; shift ;;
        --ftc-ratio) FTC_RATIO="$2"; shift ;;
        --epoch-ms) EPOCH_MS="$2"; shift ;;
    esac
    shift
done

if [ "$FTC_RATIO" != "100" ]; then
    RESULTS_BASE="${PROJECT_ROOT}/results/synthetic_capacity_${FTC_RATIO}"
fi

if [ -n "$RESULTS_DIR_SUFFIX" ]; then
    RESULTS_BASE="${RESULTS_BASE}${RESULTS_DIR_SUFFIX}"
fi

# ---- Execute Baselines ----
if [ "$TRACE_MODE" == "true" ]; then
    NUM_RUNS=${NUM_RUNS:-1}
elif [ "$ML_ONLY" == "true" ]; then
    NUM_RUNS=${NUM_RUNS:-3}
else
    NUM_RUNS=${NUM_RUNS:-3}
fi

for RUN in $(seq 1 $NUM_RUNS); do
    echo "=================================================="
    echo "Starting Run $RUN..."
    echo "=================================================="
    RESULTS_DIR="${RESULTS_BASE}/run_${RUN}"
    mkdir -p "$RESULTS_DIR"

    if [ "$TRACE_MODE" == "true" ]; then
        run_daemon_baseline "random"
    elif [ "$ML_ONLY" == "true" ]; then
        run_daemon_baseline "ml"
    else
        run_daemon_baseline "lru"
        run_daemon_baseline "lfu"
        run_daemon_baseline "decaying_lfu"
        run_autonuma_baseline
        run_daemon_baseline "heuristic"
        run_daemon_baseline "ml"
    fi
done

echo "=================================================="
echo "All baselines completed. Results in $RESULTS_BASE"