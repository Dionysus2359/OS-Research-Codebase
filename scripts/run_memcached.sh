#!/bin/bash
# run_memcached.sh - Run Memcached with tiering daemon
set -e
cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_BASE="${PROJECT_ROOT}/results/memcached"

FTC_RATIO=100
RUNS=3
POLICY="lru"
MEMBIND=2
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

# Memcached typically configured for ~10GB. FTC = 20% = ~2GB = 500,000 pages
FTC=500000
if [ "$FTC_RATIO" != "100" ]; then
    FTC=$((FTC * FTC_RATIO / 100))
    RESULTS_BASE="${PROJECT_ROOT}/results/memcached_capacity_${FTC_RATIO}"
fi

sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR"

POLICIES=("lru" "lfu" "decaying_lfu" "autonuma" "heuristic" "ml")
if [ "$ML_ONLY" == "true" ]; then
    POLICIES=("ml")
fi

for POLICY in "${POLICIES[@]}"; do
    for RUN in $(seq 1 $RUNS); do
        RESULTS_DIR="${RESULTS_BASE}/run_${RUN}"
        mkdir -p "$RESULTS_DIR"
        
        echo "Running Memcached (Run $RUN) with policy $POLICY..."
        
        if [ "$POLICY" == "autonuma" ]; then
            echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
        else
            echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
        fi

        numactl --membind=${MEMBIND} --cpubind=0 memcached -m 10240 -p 11211 -u root > "${RESULTS_DIR}/memcached_${POLICY}.log" 2>&1 &
        PID=$!
        
        sleep 2
        
        if [ "$POLICY" != "autonuma" ]; then
            sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$PID" --slow-node ${MEMBIND} --fast-tier-capacity "$FTC" --epoch-ms "$EPOCH_MS" > "${RESULTS_DIR}/${POLICY}_summary.csv" 2> "${RESULTS_DIR}/${POLICY}_stderr.log" &
            DAEMON_PID=$!
        fi
        
        # Run memtier_benchmark
        memtier_benchmark -p 11211 -P memcache_binary -n 100000 -c 50 -t 4 --ratio=1:10 > "${RESULTS_DIR}/memtier_${POLICY}.log"
        
        kill -INT $PID 2>/dev/null || true
        if [ "$POLICY" != "autonuma" ]; then
            sudo kill -INT $DAEMON_PID 2>/dev/null || true
        fi
        wait
    done
done
echo "Memcached evaluation complete!"
