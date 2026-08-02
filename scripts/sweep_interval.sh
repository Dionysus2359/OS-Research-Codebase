#!/bin/bash
# sweep_interval.sh - Sweeps daemon polling interval.
# Usage: ./sweep_interval.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

INTERVALS=(50 100 250 500)
RUNS=3

echo "Starting Epoch Interval Sweep..."

for ms in "${INTERVALS[@]}"; do
    echo "=========================================="
    echo "Running with Epoch Interval = ${ms}ms"
    echo "=========================================="
    
    export RESULTS_DIR_SUFFIX="_interval_${ms}"
    # 1. GAPBS BFS
    ./run_gapbs.sh 25 --bfs --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 2. Redis
    ./run_redis.sh 1 --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 3. Memcached
    ./run_memcached.sh --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 4. RocksDB
    ./run_rocksdb.sh --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 5. XSBench
    ./run_xsbench.sh --runs "$RUNS" --ml-only --epoch-ms "$ms"
    unset RESULTS_DIR_SUFFIX
done

echo "Interval Sweep Complete!"
