#!/bin/bash
# scripts/sweep_margins.sh
# Sweeps stable_promote and stable_demote margins on a short Redis run.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CUSUM_H="${PROJECT_ROOT}/daemon/cusum.h"
RESULTS_DIR="${PROJECT_ROOT}/results/sweep_margins"

mkdir -p "$RESULTS_DIR"

# Array of margin pairs: "promote_margin:demote_margin"
MARGIN_PAIRS=(
    "0.10:0.20"
    "0.20:0.40"
    "0.30:0.60"
    "0.05:0.10"
    "0.20:0.20"
    "0.30:0.50"
)

# Create a temporary summary file to print a nice table at the end
SUMMARY_FILE="${RESULTS_DIR}/sweep_summary.txt"
echo "PROMOTE | DEMOTE | APP TIME (s) | HIT RATE | TOTAL MIGRATIONS | OVERHEAD (us)" > "$SUMMARY_FILE"
echo "-------------------------------------------------------------------------------" >> "$SUMMARY_FILE"

for PAIR in "${MARGIN_PAIRS[@]}"; do
    PROMOTE="${PAIR%%:*}"
    DEMOTE="${PAIR##*:}"
    
    echo "======================================================"
    echo "SWEEPING MARGINS: Promote=$PROMOTE, Demote=$DEMOTE"
    echo "======================================================"
    
    # 1. Safely use sed to patch the margins in cusum.h
    sed -i -E "s/double stable_promote = [0-9.]+;/double stable_promote = $PROMOTE;/" "$CUSUM_H"
    sed -i -E "s/double stable_demote = [0-9.]+;/double stable_demote = $DEMOTE;/" "$CUSUM_H"
    
    # 2. Run the reduced Redis benchmark (Scale 1 = ~2 minutes).
    # run_redis.sh automatically runs 'make clean && make' so we don't need to do it here.
    sudo sed -i 's/NUM_RUNS=3/NUM_RUNS=1/g' "${SCRIPT_DIR}/run_redis.sh"
    sudo "${SCRIPT_DIR}/run_redis.sh" 1 --ml-only
    sudo sed -i 's/NUM_RUNS=1/NUM_RUNS=3/g' "${SCRIPT_DIR}/run_redis.sh"
    # 3. Extract the metrics using compare_metrics.py
    # compare_metrics parses the entire workload lifespan properly
    python3 "${SCRIPT_DIR}/compare_metrics.py" "${PROJECT_ROOT}/results/redis/run_1" > "${RESULTS_DIR}/compare_${PROMOTE}_${DEMOTE}.txt"
    
    # Grab the line starting with "| ml" from the markdown table
    ML_LINE=$(grep "^| ml" "${RESULTS_DIR}/compare_${PROMOTE}_${DEMOTE}.txt" | tr -s ' ' || true)
    
    if [ ! -z "$ML_LINE" ]; then
        # Example format: | ml | 120.4560 | 98.55% | 8.34% | 90.10 | ...
        APP_TIME=$(echo "$ML_LINE" | cut -d'|' -f3 | xargs)
        HIT_PCT=$(echo "$ML_LINE" | cut -d'|' -f4 | xargs)
        MIGS=$(echo "$ML_LINE" | cut -d'|' -f8 | xargs)
        OVERHEAD=$(echo "$ML_LINE" | cut -d'|' -f12 | xargs)
        
        printf "%-7s | %-6s | %-12s | %-8s | %-16s | %s\n" "$PROMOTE" "$DEMOTE" "$APP_TIME" "$HIT_PCT" "$MIGS" "$OVERHEAD" >> "$SUMMARY_FILE"
    else
        printf "%-7s | %-6s | %-12s | %-8s | %-16s | %s\n" "$PROMOTE" "$DEMOTE" "ERR" "ERR" "ERR" "ERR" >> "$SUMMARY_FILE"
    fi
done

# Restore the original baseline values
sed -i -E "s/double stable_promote = [0-9.]+;/double stable_promote = 0.20;/" "$CUSUM_H"
sed -i -E "s/double stable_demote = [0-9.]+;/double stable_demote = 0.40;/" "$CUSUM_H"
make -C "${PROJECT_ROOT}/daemon" clean > /dev/null
make -C "${PROJECT_ROOT}/daemon" > /dev/null

echo "======================================================"
echo "                   SWEEP COMPLETE                     "
echo "======================================================"
cat "$SUMMARY_FILE"
