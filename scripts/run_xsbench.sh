#!/bin/bash
# run_xsbench.sh - Run XSBench with tiering daemon
set -e
cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_BASE="${PROJECT_ROOT}/results/xsbench"

FTC_RATIO=100
RUNS=3
EPOCH_MS=100
ML_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --ftc-ratio) FTC_RATIO="$2"; shift ;;
        --runs) RUNS="$2"; shift ;;
        --epoch-ms) EPOCH_MS="$2"; shift ;;
        --ml-only) ML_ONLY=true ;;
    esac
    shift
done

MEMBIND=2
if ! numactl -H | grep -q "node 2"; then
    echo "[WARN] Node 2 not found! Falling back to Node 1."
    MEMBIND=1
fi


# XSBench Large is ~6GB. FTC = 20% = ~1.2GB = ~300,000 pages
FTC=300000
if [ "$FTC_RATIO" != "100" ]; then
    FTC=$((FTC * FTC_RATIO / 100))
    RESULTS_BASE="${PROJECT_ROOT}/results/xsbench_capacity_${FTC_RATIO}"
fi

if [ -n "$RESULTS_DIR_SUFFIX" ]; then
    RESULTS_BASE="${RESULTS_BASE}${RESULTS_DIR_SUFFIX}"
fi

sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR"

POLICIES=("lru" "lfu" "decaying_lfu" "autonuma" "heuristic" "ml")
if [ "$ML_ONLY" == "true" ]; then
    POLICIES=("ml")
fi

# Assuming XSBench is cloned to workload/XSBench/openmp-threading and compiled
XSBENCH_BIN="${PROJECT_ROOT}/workload/XSBench/openmp-threading/XSBench"

for POLICY in "${POLICIES[@]}"; do
    for RUN in $(seq 1 $RUNS); do
        RESULTS_DIR="${RESULTS_BASE}/run_${RUN}"
        mkdir -p "$RESULTS_DIR"
        
        echo "Running XSBench (Run $RUN) with policy $POLICY..."
        
        if [ "$POLICY" == "autonuma" ]; then
            echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
            numactl --membind=${MEMBIND} --cpubind=0 "$XSBENCH_BIN" -s large -m event > "${RESULTS_DIR}/xsbench_${POLICY}_stdout.log" &
            wait $!
            continue
        fi
        
        echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
        numactl --membind=${MEMBIND} --cpubind=0 "$XSBENCH_BIN" -s large -m event > "${RESULTS_DIR}/xsbench_${POLICY}_stdout.log" &
        PID=$!
        sleep 2
        
        # Write mock workload_info so daemon breaks out of its polling loop
        echo -e "${PID}\n0x0\n1\n1" | sudo tee /tmp/workload_info > /dev/null
        
        sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$PID" --slow-node ${MEMBIND} --fast-tier-capacity "$FTC" --max-promotions 1024 --max-demotions 1024 --epoch-ms "$EPOCH_MS" > "${RESULTS_DIR}/xsbench_${POLICY}_summary.csv" 2> "${RESULTS_DIR}/xsbench_${POLICY}_stderr.log" &
        DAEMON_PID=$!
        
        wait $PID
        sudo kill -INT $DAEMON_PID 2>/dev/null || true
        wait $DAEMON_PID 2>/dev/null || true
    done
done
echo "XSBench evaluation complete!"
