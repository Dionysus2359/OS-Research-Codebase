#!/bin/bash
# run_rocksdb.sh - Run RocksDB db_bench with tiering daemon
set -e
cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_BASE="${PROJECT_ROOT}/results/rocksdb"

FTC_RATIO=100
RUNS=3
MEMBIND=2
EPOCH_MS=100
ML_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --ftc-ratio) FTC_RATIO="$2"; shift ;;
        --runs) RUNS="$2"; shift ;;
        --epoch-ms) EPOCH_MS="$2"; shift ;;
        --scale) SCALE="$2"; shift ;;
        --ml-only) ML_ONLY=true ;;
    esac
    shift
done

SCALE=${SCALE:-10}
NUM_KEYS=$((SCALE * 1000000))

# RocksDB dataset ~10GB for 10M keys. FTC = 20% = ~2GB = 500,000 pages for 10M keys
# FTC scales linearly with SCALE
FTC=$((50000 * SCALE))
if [ "$FTC_RATIO" != "100" ]; then
    FTC=$((FTC * FTC_RATIO / 100))
    RESULTS_BASE="${PROJECT_ROOT}/results/rocksdb_capacity_${FTC_RATIO}"
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
DB_BENCH="${PROJECT_ROOT}/workload/rocksdb/db_bench"

for POLICY in "${POLICIES[@]}"; do
    for RUN in $(seq 1 $RUNS); do
        RESULTS_DIR="${RESULTS_BASE}/run_${RUN}"
        mkdir -p "$RESULTS_DIR"
        
        echo "Running RocksDB (Run $RUN) with policy $POLICY..."
        
        # Phase 1: Load (No Daemon)
        echo " -> [Phase 1] Populating database..."
        numactl --membind=${MEMBIND} --cpubind=0 "$DB_BENCH" --db=/tmp/rocksdb_bench --benchmarks="fillseq" --num=$NUM_KEYS --value_size=1024 --use_existing_db=0 > "${RESULTS_DIR}/rocksdb_load_${POLICY}.log" 2>&1
        
        echo " -> Dropping OS page cache..."
        sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
        sleep 2
        
        # Phase 2: Run (With Daemon)
        echo " -> [Phase 2] Executing read workload..."
        if [ "$POLICY" == "autonuma" ]; then
            echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
            numactl --membind=${MEMBIND} --cpubind=0 "$DB_BENCH" --db=/tmp/rocksdb_bench --benchmarks="readrandom" --num=$NUM_KEYS --value_size=1024 --use_existing_db=1 --duration=300 > "${RESULTS_DIR}/rocksdb_run_${POLICY}.log" 2>&1 &
            wait $!
            continue
        fi

        echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
        numactl --membind=${MEMBIND} --cpubind=0 "$DB_BENCH" --db=/tmp/rocksdb_bench --benchmarks="readrandom" --num=$NUM_KEYS --value_size=1024 --use_existing_db=1 --duration=300 > "${RESULTS_DIR}/rocksdb_run_${POLICY}.log" 2>&1 &
        PID=$!
        
        sleep 1
        
        sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$PID" --slow-node ${MEMBIND} --fast-tier-capacity "$FTC" --epoch-ms "$EPOCH_MS" > "${RESULTS_DIR}/${POLICY}_summary.csv" 2> "${RESULTS_DIR}/${POLICY}_stderr.log" &
        DAEMON_PID=$!
        
        wait $PID
        sudo kill -INT $DAEMON_PID 2>/dev/null || true
        wait $DAEMON_PID 2>/dev/null || true
    done
done
echo "RocksDB evaluation complete!"
