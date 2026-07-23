#!/bin/bash
# run_gapbs.sh — Run GAPBS benchmarks with all tiering policies
# Usage: ./run_gapbs.sh [scale]  (default scale=20)
set -e

cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GAPBS_DIR="${PROJECT_ROOT}/workload/gapbs"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_BASE="${PROJECT_ROOT}/results/gapbs"
SCALE=${1:-20}
TRACE_MODE=false
ABS_THRESH=""
DEMOTE_MARGIN=""
ML_ONLY=false

shift  # consume $1 (scale)
while [ $# -gt 0 ]; do
    case "$1" in
        --trace) TRACE_MODE=true; mkdir -p "${PROJECT_ROOT}/ml/traces" ;;
        --abs-thresh) ABS_THRESH="$2"; shift ;;
        --demote-margin) DEMOTE_MARGIN="$2"; shift ;;
        --ml-only) ML_ONLY=true ;;
    esac
    shift
done

# Removed mkdir -p "$RESULTS_DIR" since it happens in loop
# Force PMU settings
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
echo 0 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null || true

# Build daemon
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR"

cleanup() {
    sudo killall daemon 2>/dev/null || true
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 2
}

run_gapbs_kernel() {
    KERNEL=$1   # bfs or pr
    POLICY=$2   # lru, lfu, decaying_lfu, ml
    echo "=========================================="
    echo "GAPBS ${KERNEL} | Policy: ${POLICY} | Scale: ${SCALE}"
    echo "=========================================="
    cleanup

    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true

    LOG_FILE="${RESULTS_DIR}/${KERNEL}_${POLICY}_stdout.log"
    
    MEMBIND=1
    TRIALS=5
    FTC=128
    DAEMON_ARGS=("--slow-node" "$MEMBIND" "--fast-tier-capacity" "$FTC" "--max-promotions" "256" "--max-demotions" "256")
    if [ "$SCALE" -ge 23 ]; then
        if numactl -H | grep -q "node 2"; then
            MEMBIND=2
        else
            echo "[WARN] Scale >= 23 but Node 2 not found! Falling back to Node 1."
            MEMBIND=1
        fi
        # TRIALS=64
        # Dynamic Capacity: Give BFS room to breathe, keep PR under the hardware limit
        if [ "$KERNEL" == "pr" ]; then
            TRIALS=250
            FTC=786432
        else
            TRIALS=3000
            FTC=786432
        fi
        
        DAEMON_ARGS=("--slow-node" "$MEMBIND" "--fast-tier-capacity" "$FTC" "--max-promotions" "4096" "--max-demotions" "4096")
    elif [ "$SCALE" -le 20 ]; then
        TRIALS=300
        # Change FTC from 128 to 2000 (roughly 8MB, allowing a realistic swap space for a tiny graph)
        DAEMON_ARGS=("--slow-node" "$MEMBIND" "--fast-tier-capacity" "2000" "--max-promotions" "256" "--max-demotions" "256")
    fi

    # Prevent CSV bombs for PageRank but ensure enough epochs for K=10 lookahead
    if [ "$TRACE_MODE" == "true" ] && [ "$KERNEL" == "pr" ]; then
        echo "[Daemon] Trace mode active for PR: overriding TRIALS down to 15 to prevent OOM."
        TRIALS=15
    fi

    # Start GAPBS workload
    numactl --membind=${MEMBIND} --cpubind=0 \
        "$GAPBS_DIR/$KERNEL" -g "$SCALE" -n "$TRIALS" \
        > "$LOG_FILE" 2>&1 &
    WL_PID=$!

    echo "[*] Waiting for GAPBS to finish graph build..."
    # Wait for graph build to complete (non-blocking, no pipe closure)
    while ! grep -q "Build Time" "$LOG_FILE" 2>/dev/null; do
        sleep 0.05
        # Bail if GAPBS exited early
        kill -0 $WL_PID 2>/dev/null || {
            echo "[!] GAPBS exited early. Check logs."
            break
        }
    done
    
    echo "[*] GAPBS computation phase started. Attaching daemon..."

    # Write a minimal workload_info so daemon can attach
    echo -e "${WL_PID}\n0x0\n1\n1" | sudo tee /tmp/workload_info > /dev/null

    if [ "$TRACE_MODE" == "true" ] && [ "$POLICY" == "random" ]; then
        DAEMON_ARGS+=("--trace" "--trace-dir" "${PROJECT_ROOT}/ml/traces")
    fi

    # Append CUSUM overrides if provided
    if [ -n "$ABS_THRESH" ]; then
        DAEMON_ARGS+=("--abs-thresh" "$ABS_THRESH")
    fi
    if [ -n "$DEMOTE_MARGIN" ]; then
        DAEMON_ARGS+=("--demote-margin" "$DEMOTE_MARGIN")
    fi

    # Start daemon
    sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$WL_PID" "${DAEMON_ARGS[@]}" \
        > "$RESULTS_DIR/${KERNEL}_${POLICY}_summary.csv" \
        2> "$RESULTS_DIR/${KERNEL}_${POLICY}_stderr.log" &
    DAEMON_PID=$!

    wait $WL_PID 2>/dev/null || true
    sleep 2
    sudo kill -SIGINT $DAEMON_PID 2>/dev/null || true
    wait $DAEMON_PID 2>/dev/null || true

    if [ "$TRACE_MODE" == "true" ]; then
        # Grab the real user who invoked sudo
        REAL_USER=${SUDO_USER:-$USER}
        sudo chown $REAL_USER:$REAL_USER "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" 2>/dev/null || true
        mv "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" "${PROJECT_ROOT}/ml/traces/trace_${POLICY}_${KERNEL}.csv" 2>/dev/null || true
    fi

    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo "Done: ${KERNEL}_${POLICY}"
}

run_gapbs_autonuma() {
    KERNEL=$1
    echo "=========================================="
    echo "GAPBS ${KERNEL} | Policy: autonuma | Scale: ${SCALE}"
    echo "=========================================="
    cleanup

    # ENABLE AutoNUMA
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null

    LOG_FILE="${RESULTS_DIR}/${KERNEL}_autonuma_stdout.log"
    
    MEMBIND=1
    TRIALS=5
    if [ "$SCALE" -ge 23 ]; then
        if numactl -H | grep -q "node 2"; then
            MEMBIND=2
        else
            echo "[WARN] Scale >= 23 but Node 2 not found! Falling back to Node 1."
            MEMBIND=1
        fi
        # TRIALS=64
        if [ "$KERNEL" == "pr" ]; then
            TRIALS=250
        else
            TRIALS=1000
        fi
    elif [ "$SCALE" -le 20 ]; then
        TRIALS=300
    fi

    cat /proc/vmstat | grep numa > "$RESULTS_DIR/${KERNEL}_autonuma_vmstat_before.txt"
    numastat > "$RESULTS_DIR/${KERNEL}_autonuma_numastat_before.txt"

    # Start GAPBS workload WITHOUT daemon (start on Node 1 CPU)
    taskset -c 1 /usr/bin/time -v "$GAPBS_DIR/$KERNEL" -g "$SCALE" -n "$TRIALS" \
        > "$LOG_FILE" 2>&1 &
    GAPBS_PID=$!
    
    # Wait for graph building to occur locally on Node 1
    # GAPBS prints 'Graph has X nodes...' exactly when loading finishes
    while ! grep -q "Graph has" "$LOG_FILE" 2>/dev/null; do
        if ! kill -0 $GAPBS_PID 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    
    # Yank CPU affinity back to Node 0 for actual graph traversal trials!
    taskset -a -pc 0 $GAPBS_PID > /dev/null 2>&1 || true
    
    wait $GAPBS_PID 2>/dev/null || true

    echo "[*] Workload finished. Waiting for kernel AutoNUMA threads to flush..."
    sleep 2

    cat /proc/vmstat | grep numa > "$RESULTS_DIR/${KERNEL}_autonuma_vmstat_after.txt"
    numastat > "$RESULTS_DIR/${KERNEL}_autonuma_numastat_after.txt"

    # DISABLE AutoNUMA
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    echo "Done: ${KERNEL}_autonuma"
}

KERNELS=("bfs" "pr")
POLICIES=("lru" "lfu" "decaying_lfu" "ml")

if [ "$TRACE_MODE" == "true" ]; then
    POLICIES=("random")
    NUM_RUNS=1
elif [ "$ML_ONLY" == "true" ]; then
    POLICIES=("ml")
    NUM_RUNS=3
else
    NUM_RUNS=3
fi

# Run workloads
for RUN in $(seq 1 $NUM_RUNS); do
    echo "=================================================="
    echo "Starting Run $RUN..."
    echo "=================================================="
    RESULTS_DIR="${RESULTS_BASE}/run_${RUN}"
    mkdir -p "$RESULTS_DIR"

    for KERNEL in "${KERNELS[@]}"; do
        for POLICY in "${POLICIES[@]}"; do
            run_gapbs_kernel "$KERNEL" "$POLICY"
        done
        if [ "$TRACE_MODE" != "true" ] && [ "$ML_ONLY" != "true" ]; then
            run_gapbs_autonuma "$KERNEL"
        fi
    done
done

echo "=========================================="
if [ "$TRACE_MODE" == "true" ]; then
    echo "GAPBS trace collection complete. Traces in ${PROJECT_ROOT}/ml/traces"
else
    echo "All GAPBS baselines complete. Results in $RESULTS_BASE"
fi
