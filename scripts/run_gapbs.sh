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
RESULTS_DIR="${PROJECT_ROOT}/results/gapbs"
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
    if [ "$SCALE" -ge 23 ]; then
        MEMBIND=2
        # TRIALS=64
        # Dynamic Capacity: Give BFS room to breathe, keep PR under the hardware limit
        if [ "$KERNEL" == "pr" ]; then
            TRIALS=250
            FTC=50000
        else
            TRIALS=1000
            FTC=70000
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
    sudo kill $DAEMON_PID 2>/dev/null || true
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
        MEMBIND=2
        TRIALS=64
    elif [ "$SCALE" -le 20 ]; then
        TRIALS=300
    fi

    cat /proc/vmstat | grep numa > "$RESULTS_DIR/${KERNEL}_autonuma_vmstat_before.txt"
    numastat > "$RESULTS_DIR/${KERNEL}_autonuma_numastat_before.txt"

    # Start GAPBS workload WITHOUT daemon
    /usr/bin/time -v numactl --membind=${MEMBIND} --cpubind=0 \
        "$GAPBS_DIR/$KERNEL" -g "$SCALE" -n "$TRIALS" \
        > "$LOG_FILE" 2>&1

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
elif [ "$ML_ONLY" == "true" ]; then
    POLICIES=("ml")
fi

# Run workloads
for KERNEL in "${KERNELS[@]}"; do
    for POLICY in "${POLICIES[@]}"; do
        run_gapbs_kernel "$KERNEL" "$POLICY"
    done
    if [ "$TRACE_MODE" != "true" ] && [ "$ML_ONLY" != "true" ]; then
        run_gapbs_autonuma "$KERNEL"
    fi
done

echo "=========================================="
if [ "$TRACE_MODE" == "true" ]; then
    echo "GAPBS trace collection complete. Traces in ${PROJECT_ROOT}/ml/traces"
else
    echo "All GAPBS baselines complete. Results in $RESULTS_DIR"
fi
