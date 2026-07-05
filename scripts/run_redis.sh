#!/bin/bash
# run_redis.sh — Run Redis + YCSB benchmark with all tiering policies
# Usage: ./run_redis.sh [--trace] [--abs-thresh X] [--demote-margin X] [--ml-only] [--large]
set -e

cleanup_on_exit() {
    kill $(jobs -p) 2>/dev/null || true
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKLOAD_DIR="${PROJECT_ROOT}/workload"
YCSB_DIR="${WORKLOAD_DIR}/ycsb"
DAEMON_DIR="${PROJECT_ROOT}/daemon"
RESULTS_DIR="${PROJECT_ROOT}/results/redis"

mkdir -p "$RESULTS_DIR"

TRACE_MODE=false
LARGE_MODE=false
ABS_THRESH=""
DEMOTE_MARGIN=""
ML_ONLY=false
SCALE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --trace) TRACE_MODE=true; mkdir -p "${PROJECT_ROOT}/ml/traces" ;;
        --abs-thresh) ABS_THRESH="$2"; shift ;;
        --demote-margin) DEMOTE_MARGIN="$2"; shift ;;
        --ml-only) ML_ONLY=true ;;
        --large) LARGE_MODE=true ;;
        *) 
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                SCALE=$1
            fi
            ;;
    esac
    shift
done

# Calculate records and operations based on scale
# Scale 1 = 1 million records (~1GB) and 2 million operations
RECORD_COUNT=$((SCALE * 1000000))
OPERATION_COUNT=$((SCALE * 2000000))

# Force PMU settings and watchdog disable
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
echo 0 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null || true

# Build daemon
make -C "$DAEMON_DIR" clean && make -C "$DAEMON_DIR" LOCAL_DEV=1

cleanup() {
    sudo killall daemon 2>/dev/null || true
    sudo killall redis-server 2>/dev/null || true
    sync && sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 2
}

run_redis_workload() {
    POLICY=$1
    echo "=========================================="
    echo "Redis+YCSB | Policy: ${POLICY} | Large: ${LARGE_MODE}"
    echo "=========================================="
    cleanup

    # Disable AutoNUMA & THP
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true

    LOG_FILE="${RESULTS_DIR}/redis_${POLICY}_stdout.log"

    MEMBIND=1
    FTC=60000
    if [ "$LARGE_MODE" == "true" ]; then
        if numactl -H | grep -q "node 2"; then
            MEMBIND=2
        else
            echo "[WARN] Large mode requested but Node 2 not found! Falling back to Node 1."
            MEMBIND=1
        fi
        FTC=70000
    fi

    # TRAP 1: Start Redis with BGSAVE disabled (--save "") on the slow node
    echo "[*] Starting Redis server on Node ${MEMBIND}..."
    numactl --membind=${MEMBIND} --cpubind=0 \
        redis-server --save "" --appendonly no --protected-mode no --port 6380 \
        > "${RESULTS_DIR}/redis_server_${POLICY}.log" 2>&1 &
    REDIS_PID=$!
    
    # Wait for Redis to start
    sleep 2

    # TRAP 2: JVM Heap Restriction for YCSB
    export JAVA_OPTS="-Xmx1g -Xms1g"

    # Inject the patched YCSB runner for Python 3 compatibility
    if [ -f "${PROJECT_ROOT}/scripts/ycsb_patched.py" ]; then
        echo "[*] Injecting Python 3 patched YCSB runner..."
        cp "${PROJECT_ROOT}/scripts/ycsb_patched.py" "$YCSB_DIR/bin/ycsb"
        chmod +x "$YCSB_DIR/bin/ycsb"
    fi

    # Pre-load dataset (YCSB load phase) BEFORE daemon starts
    echo "[*] Loading YCSB dataset (${RECORD_COUNT} records)..."
    numactl --cpubind=0 \
        "$YCSB_DIR/bin/ycsb" load redis -s \
        -P "$YCSB_DIR/workloads/workloada" \
        -p "redis.host=127.0.0.1" -p "redis.port=6380" \
        -p "recordcount=${RECORD_COUNT}" \
        > /dev/null 2>&1

    # Now write workload_info so daemon knows the PID
    # Format: PID BASE_ADDR TOTAL_PAGES PHASE
    echo "$REDIS_PID 0 1000000 1" > /tmp/workload_info
    
    DAEMON_ARGS=("--slow-node" "$MEMBIND" "--fast-tier-capacity" "$FTC" "--max-promotions" "4096" "--max-demotions" "4096")
    if [ -n "$ABS_THRESH" ]; then
        DAEMON_ARGS+=("--abs-thresh" "$ABS_THRESH")
    fi
    if [ -n "$DEMOTE_MARGIN" ]; then
        DAEMON_ARGS+=("--demote-margin" "$DEMOTE_MARGIN")
    fi
    if [ "$TRACE_MODE" == "true" ]; then
        DAEMON_ARGS+=("--trace" "--trace-dir" "${PROJECT_ROOT}/ml/traces")
    fi

    echo "[*] Starting daemon (Policy: ${POLICY})..."
    sudo "$DAEMON_DIR/daemon" "$POLICY" --pid "$REDIS_PID" "${DAEMON_ARGS[@]}" \
        > "${RESULTS_DIR}/redis_${POLICY}_summary.csv" \
        2> "${RESULTS_DIR}/redis_${POLICY}_stderr.log" &
    DAEMON_PID=$!

    # Wait for daemon to attach and discover regions
    sleep 2

    echo "[*] Running YCSB workload (${OPERATION_COUNT} operations)..."
    # TRAP 3/Dataset: Operations scaled to ensure steady-state execution
    numactl --cpubind=0 \
        "$YCSB_DIR/bin/ycsb" run redis -s \
        -P "$YCSB_DIR/workloads/workloada" \
        -p "redis.host=127.0.0.1" -p "redis.port=6380" \
        -p "recordcount=${RECORD_COUNT}" -p "operationcount=${OPERATION_COUNT}" \
        > "$LOG_FILE" 2>&1

    echo "[*] Workload finished."
    
    sudo kill -SIGINT "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    
    if [ "$TRACE_MODE" == "true" ]; then
        sudo chown $USER:$USER "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" 2>/dev/null || true
        mv "${PROJECT_ROOT}/ml/traces/trace_${POLICY}.csv" "${PROJECT_ROOT}/ml/traces/trace_${POLICY}_redis.csv" 2>/dev/null || true
    fi

    cleanup
    echo "Done: redis_${POLICY}"
}

run_redis_autonuma() {
    echo "=========================================="
    echo "Redis+YCSB | Policy: autonuma"
    echo "=========================================="
    cleanup

    # ENABLE AutoNUMA
    echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true

    LOG_FILE="${RESULTS_DIR}/redis_autonuma_stdout.log"

    MEMBIND=1
    if [ "$LARGE_MODE" == "true" ]; then
        if numactl -H | grep -q "node 2"; then
            MEMBIND=2
        else
            echo "[WARN] Large mode requested but Node 2 not found! Falling back to Node 1."
            MEMBIND=1
        fi
    fi

    echo "[*] Starting Redis server on Node ${MEMBIND}..."
    numactl --membind=${MEMBIND} --cpubind=0 \
        redis-server --save "" --appendonly no --protected-mode no --port 6380 \
        > "${RESULTS_DIR}/redis_server_autonuma.log" 2>&1 &
    REDIS_PID=$!
    sleep 2

    export JAVA_OPTS="-Xmx1g -Xms1g"

    echo "[*] Loading YCSB dataset (${RECORD_COUNT} records)..."
    numactl --cpubind=0 \
        "$YCSB_DIR/bin/ycsb" load redis -s \
        -P "$YCSB_DIR/workloads/workloada" \
        -p "redis.host=127.0.0.1" -p "redis.port=6380" \
        -p "recordcount=${RECORD_COUNT}" \
        > /dev/null 2>&1

    echo "[*] Running YCSB workload (${OPERATION_COUNT} operations)..."
    numactl --cpubind=0 \
        "$YCSB_DIR/bin/ycsb" run redis -s \
        -P "$YCSB_DIR/workloads/workloada" \
        -p "redis.host=127.0.0.1" -p "redis.port=6380" \
        -p "recordcount=${RECORD_COUNT}" -p "operationcount=${OPERATION_COUNT}" \
        > "$LOG_FILE" 2>&1

    echo "[*] Workload finished. Waiting for kernel AutoNUMA threads to flush..."
    sleep 2

    cat /proc/vmstat | grep numa > "${RESULTS_DIR}/redis_autonuma_vmstat_after.txt"
    numastat > "${RESULTS_DIR}/redis_autonuma_numastat_after.txt"

    # DISABLE AutoNUMA
    echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null || true
    echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null || true
    
    cleanup
    echo "Done: redis_autonuma"
}

POLICIES=("lru" "lfu" "decaying_lfu" "ml")

if [ "$TRACE_MODE" == "true" ]; then
    POLICIES=("random")
elif [ "$ML_ONLY" == "true" ]; then
    POLICIES=("ml")
fi

for POLICY in "${POLICIES[@]}"; do
    run_redis_workload "$POLICY"
done

if [ "$TRACE_MODE" != "true" ] && [ "$ML_ONLY" != "true" ]; then
    run_redis_autonuma
fi

echo "=========================================="
if [ "$TRACE_MODE" == "true" ]; then
    echo "Redis trace collection complete. Trace in ${PROJECT_ROOT}/ml/traces"
else
    echo "All Redis baselines complete. Results in $RESULTS_DIR"
fi
