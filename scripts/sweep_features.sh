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
    ./run_gapbs.sh 25 --bfs --runs "$RUNS" --ml-only
    ./run_redis.sh 1 --runs "$RUNS" --ml-only
    ./run_memcached.sh --runs "$RUNS" --ml-only
    ./run_rocksdb.sh --runs "$RUNS" --ml-only
    ./run_xsbench.sh --runs "$RUNS" --ml-only
    
    # Move results so they aren't overwritten
    mv ../results/gapbs ../results/gapbs_ablation_${feature} 2>/dev/null || true
    mv ../results/redis ../results/redis_ablation_${feature} 2>/dev/null || true
    mv ../results/memcached ../results/memcached_ablation_${feature} 2>/dev/null || true
    mv ../results/rocksdb ../results/rocksdb_ablation_${feature} 2>/dev/null || true
    mv ../results/xsbench ../results/xsbench_ablation_${feature} 2>/dev/null || true
    
    echo "Completed ablation for ${feature}"
done

echo "Feature Ablation Sweep Complete!"
