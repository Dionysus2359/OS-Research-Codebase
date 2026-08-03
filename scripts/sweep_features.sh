#!/bin/bash
# sweep_features.sh - Automates the feature ablation study
# Usage: ./sweep_features.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

FEATURES=("none" "epochs_since_access" "access_count" "access_frequency_ratio" "momentum")
RUNS=3

echo "Starting Feature Ablation Sweep..."

for feature in "${FEATURES[@]}"; do
    echo "=========================================="
    if [ "$feature" == "none" ]; then
        echo "Running Main Model (All Features)"
    else
        echo "Running Ablation: Dropping ${feature}"
    fi
    echo "=========================================="
    
    # 1. Retrain the model
    cd ../ml
    if [ "$feature" == "none" ]; then
        python3 train_only.py --trace-file traces/trace_random.csv
    else
        python3 train_only.py --trace-file traces/trace_random.csv --drop-feature "$feature"
    fi
    cd ../scripts
    
    # 2. Recompile the daemon to pick up the new logistic_weights.bin
    # (train_only.py writes to ../daemon/logistic_weights.bin)
    make -C ../daemon clean && make -C ../daemon
    
    # 3. Run workload
    export RESULTS_DIR_SUFFIX="_ablation_${feature}"
    # 1. GAPBS BFS
    ./run_gapbs.sh 27 --bfs --runs "$RUNS" --ml-only
    
    # 2. Redis
    ./run_redis.sh 5 --runs "$RUNS" --ml-only
    ./run_memcached.sh --scale 5 --runs "$RUNS" --ml-only
    # 4. RocksDB
    ./run_rocksdb.sh --scale 10 --runs "$RUNS" --ml-only
    
    # 5. XSBench
    ./run_xsbench.sh --runs "$RUNS" --ml-only
    
    # 6. Synthetic Workload
    ./run_baselines.sh --runs "$RUNS" --ml-only
    unset RESULTS_DIR_SUFFIX
    
    echo "Completed ablation for ${feature}"
done

echo "Feature Ablation Sweep Complete!"
