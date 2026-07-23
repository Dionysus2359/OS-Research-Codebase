#!/bin/bash
# scripts/sweep_react.sh
# Sweeps REACT_ABS_THRESHOLD over different values to test phase-change reaction.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CUSUM_H="${PROJECT_ROOT}/daemon/cusum.h"
RESULTS_DIR="${PROJECT_ROOT}/results/sweep_react"

mkdir -p "$RESULTS_DIR"

# The thresholds to test (0.10 is the baseline)
THRESHOLDS=(0.10 0.370 0.587 0.720)

for THRESH in "${THRESHOLDS[@]}"; do
    echo "=========================================="
    echo "SWEEPING REACT_ABS_THRESHOLD = $THRESH"
    echo "=========================================="
    
    # 1. Safely use sed to patch the REACT_ABS_THRESHOLD in cusum.h
    sed -i -E "s/static constexpr double REACT_ABS_THRESHOLD = [0-9.]+;/static constexpr double REACT_ABS_THRESHOLD = $THRESH;/" "$CUSUM_H"
    
    # 2. Rebuild the daemon
    make -C "${PROJECT_ROOT}/daemon" clean > /dev/null
    make -C "${PROJECT_ROOT}/daemon" > /dev/null
    
    # 3. Run the synthetic workload (which finishes in seconds)
    echo "Running synthetic workload..."
    sudo sed -i 's/NUM_RUNS=3/NUM_RUNS=1/g' "${SCRIPT_DIR}/run_baselines.sh"
    sudo "${SCRIPT_DIR}/run_baselines.sh" --ml-only > /dev/null
    sudo sed -i 's/NUM_RUNS=1/NUM_RUNS=3/g' "${SCRIPT_DIR}/run_baselines.sh"
    
    # 4. Save the stderr log so we can analyze the [CUSUM] reaction window
    cp "${PROJECT_ROOT}/results/synthetic/run_1/ml_stderr.log" "${RESULTS_DIR}/react_${THRESH}.log" 2>/dev/null || true
    echo "Saved to ${RESULTS_DIR}/react_${THRESH}.log"
done

# Restore the original value just to be clean
sed -i -E "s/static constexpr double REACT_ABS_THRESHOLD = [0-9.]+;/static constexpr double REACT_ABS_THRESHOLD = 0.10;/" "$CUSUM_H"
make -C "${PROJECT_ROOT}/daemon" clean > /dev/null
make -C "${PROJECT_ROOT}/daemon" > /dev/null

echo "Sweep complete! Check results/sweep_react/ for the logs."
