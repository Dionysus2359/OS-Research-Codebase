#!/bin/bash
# measure_hardware_baseline.sh — Use STREAM to measure raw hardware bandwidth
# Usage: ./measure_hardware_baseline.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKLOAD_DIR="${PROJECT_ROOT}/workload"
RESULTS_DIR="${PROJECT_ROOT}/results/hardware_baseline"

mkdir -p "$RESULTS_DIR"

echo "[*] Compiling STREAM with full optimizations (NTIMES=200, ARRAY_SIZE=40M)..."
gcc -O2 -fopenmp -DSTREAM_ARRAY_SIZE=40000000 -DNTIMES=200 \
    "$WORKLOAD_DIR/stream.c" -o "$WORKLOAD_DIR/stream" -lm

export OMP_NUM_THREADS=$(nproc)

echo "=========================================="
echo "FAST TIER (NODE 0) BANDWIDTH"
echo "=========================================="
numactl --membind=0 --cpubind=0 "$WORKLOAD_DIR/stream" > "$RESULTS_DIR/stream_node0.log"
grep "Triad:" "$RESULTS_DIR/stream_node0.log" | awk '{print "Node 0 Triad Bandwidth: " $2 " MB/s"}'

echo ""
echo "=========================================="
echo "SLOW TIER (NODE 1) BANDWIDTH"
echo "=========================================="
numactl --membind=1 --cpubind=0 "$WORKLOAD_DIR/stream" > "$RESULTS_DIR/stream_node1.log"
grep "Triad:" "$RESULTS_DIR/stream_node1.log" | awk '{print "Node 1 Triad Bandwidth: " $2 " MB/s"}'

echo "=========================================="
echo "Hardware characterization complete. Full logs in $RESULTS_DIR"
