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
    
    # 3. Extract the metrics from the generated CSV
    # run_redis.sh outputs to results/redis/run_1/redis_ml_summary.csv
    SUMMARY_CSV="${PROJECT_ROOT}/results/redis/run_1/redis_ml_summary.csv"
    STDERR_LOG="${PROJECT_ROOT}/results/redis/run_1/redis_ml_stderr.log"
    
    # Copy files to our sweep folder so they don't get overwritten
    cp "$SUMMARY_CSV" "${RESULTS_DIR}/summary_${PROMOTE}_${DEMOTE}.csv" 2>/dev/null || true
    cp "$STDERR_LOG" "${RESULTS_DIR}/stderr_${PROMOTE}_${DEMOTE}.log" 2>/dev/null || true
    
    # Parse the metrics using compare_metrics.py to grab App Time and other stats
    echo "Extracting metrics..."
    # We can just extract the last line of the CSV directly for our summary table
    if [ -f "$SUMMARY_CSV" ]; then
        LAST_LINE=$(tail -n 1 "$SUMMARY_CSV")
        # CSV format: epoch,phase,accesses,hits,hit_rate,fast_tier,tracked,migrations,proms,dems,mig_latency,est_lat,cxl_lat,misplaced,overhead,app_time
        HIT_RATE=$(echo "$LAST_LINE" | cut -d',' -f5)
        MIGS=$(echo "$LAST_LINE" | cut -d',' -f8)
        OVERHEAD=$(echo "$LAST_LINE" | cut -d',' -f15)
        APP_TIME=$(echo "$LAST_LINE" | cut -d',' -f16)
        
        # Multiply Hit Rate by 100 for readability
        HIT_PCT=$(printf "%.2f%%" $(echo "$HIT_RATE * 100" | bc -l))
        
        printf "%-7s | %-6s | %-12s | %-8s | %-16s | %s\n" "$PROMOTE" "$DEMOTE" "$APP_TIME" "$HIT_PCT" "$MIGS" "$OVERHEAD" >> "$SUMMARY_FILE"
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
