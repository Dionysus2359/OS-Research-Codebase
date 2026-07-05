#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_ROOT="${SCRIPT_DIR}/../results/sweep"
mkdir -p "$RESULTS_ROOT"

SCALE=${1:-20}
# ABS_THRESHOLDS=(0.15 0.20 0.25)
# DEMOTE_MARGINS=(0.15 0.20 0.25)
ABS_THRESHOLDS=(0.65 0.70 0.80)
DEMOTE_MARGINS=(0.65 0.70 0.80)

for ABS in "${ABS_THRESHOLDS[@]}"; do
    for DEMOTE in "${DEMOTE_MARGINS[@]}"; do
        echo "=========================================="
        echo "SWEEP: ABS=$ABS  DEMOTE=$DEMOTE  Scale=$SCALE"
        echo "=========================================="
        
        "$SCRIPT_DIR/run_gapbs.sh" "$SCALE" \
            --abs-thresh "$ABS" --demote-margin "$DEMOTE" --ml-only
        
        # Copy results to sweep directory with descriptive names
        cp "${SCRIPT_DIR}/../results/gapbs/bfs_ml_summary.csv" \
           "${RESULTS_ROOT}/bfs_abs${ABS}_dem${DEMOTE}.csv" 2>/dev/null || true
    done
done

echo ""
echo "=== SWEEP SUMMARY ==="
echo "ABS        | DEMOTE     | Hit Rate     | Migrations"
echo "------------------------------------------------------"
for ABS in "${ABS_THRESHOLDS[@]}"; do
    for DEMOTE in "${DEMOTE_MARGINS[@]}"; do
        FILE="${RESULTS_ROOT}/bfs_abs${ABS}_dem${DEMOTE}.csv"
        if [ -f "$FILE" ]; then
            # Extract last line's hit_rate and total_migrations
            LAST=$(tail -1 "$FILE")
            HR=$(echo "$LAST" | cut -d',' -f5)
            MIG=$(echo "$LAST" | cut -d',' -f8)
            printf "%-10s | %-10s | %-12s | %s\n" "$ABS" "$DEMOTE" "$HR" "$MIG"
        fi
    done
done
