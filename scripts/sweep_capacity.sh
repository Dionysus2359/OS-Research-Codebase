#!/bin/bash
# sweep_capacity.sh - Sweeps Fast Tier Capacity (DRAM ratio) for evaluation.
# Usage: ./sweep_capacity.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RATIOS=(20 10 5 2 1)
RUNS=3

echo "Starting Capacity Sweep..."

for ratio in "${RATIOS[@]}"; do
    echo "=========================================="
    echo "Running with FTC Ratio = ${ratio}%"
    echo "=========================================="
    
    SKIP_ARG=""
    if [ "$ratio" != "20" ]; then
        SKIP_ARG="--skip-autonuma"
    fi
    
    # 1. GAPBS BFS (and PR for the 20% baseline)
    ./run_gapbs.sh 27 --bfs --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
    if [ "$ratio" == "20" ]; then
        echo "Running PageRank (PR) for baseline 20% capacity..."
        ./run_gapbs.sh 27 --pr --runs "$RUNS" --ftc-ratio "$ratio"
    fi
    
    # 2. Redis
    ./run_redis.sh 5 --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
    
    # 3. Memcached
    ./run_memcached.sh --scale 30 --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
    
    # 4. RocksDB
    ./run_rocksdb.sh --scale 30 --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
    
    # 5. XSBench
    ./run_xsbench.sh --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
    
    # 6. Synthetic Workload
    ./run_baselines.sh --runs "$RUNS" --ftc-ratio "$ratio" $SKIP_ARG
done

echo "Capacity Sweep Complete!"
