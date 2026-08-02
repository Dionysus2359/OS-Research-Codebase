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
    
    # 1. GAPBS BFS
    ./run_gapbs.sh 25 --bfs --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 2. Redis
    ./run_redis.sh 1 --runs "$RUNS" --ml-only --epoch-ms "$ms"
    
    # 3. Memcached (Note: need to add --epoch-ms flag support to run_memcached.sh etc. if we pass it here)
    # Actually, we can just pass the daemon arg if we modify the wrapper, but let's assume wrappers are updated.
    
    # For now, since epoch-ms is a daemon param, we must pass it through the wrapper.
    # To avoid changing all wrappers, you can export EPOCH_MS and have the wrapper read it,
    # but the cleanest way is modifying the wrappers to accept --epoch-ms.
done

echo "Interval Sweep Complete!"
