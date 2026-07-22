import pandas as pd
import sys

def measure_gaps(trace_path):
    print(f"\n--- Measuring reuse gaps for {trace_path} ---")
    try:
        df = pd.read_csv(trace_path)
    except FileNotFoundError:
        print(f"Error: {trace_path} not found.")
        return

    df = df.sort_values(["page_va", "epoch"])
    df["gap"] = df.groupby("page_va")["epoch"].diff()
    gaps = df["gap"].dropna()
    
    if len(gaps) == 0:
        print("No gaps found (no pages were reused).")
        return
        
    print(gaps.quantile([0.5, 0.75, 0.9, 0.95, 0.99, 0.999]))
    print(f"Max gap: {gaps.max()}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        for path in sys.argv[1:]:
            measure_gaps(path)
    else:
        # Default to checking all traces
        measure_gaps("traces/trace_random_bfs.csv")
        measure_gaps("traces/trace_random_pr.csv")
        measure_gaps("traces/trace_random_redis.csv")
        measure_gaps("traces/trace_random.csv")
