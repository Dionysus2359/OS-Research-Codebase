import matplotlib.pyplot as plt
import pandas as pd
import numpy as np
import os
import glob
import sys

def parse_results(base_dir):
    data = []
    # Search for summary.csv across all runs
    csv_files = glob.glob(os.path.join(base_dir, "**", "*_summary.csv"), recursive=True)
    
    for f in csv_files:
        # File naming convention: {POLICY}_summary.csv or {workload}_{POLICY}_summary.csv
        basename = os.path.basename(f)
        policy = basename.split("_summary.csv")[0]
        if "redis_" in policy: policy = policy.replace("redis_", "")
        if "gapbs_" in policy: policy = policy.replace("gapbs_", "")
        if "memcached_" in policy: policy = policy.replace("memcached_", "")
        if "rocksdb_" in policy: policy = policy.replace("rocksdb_", "")
        if "xsbench_" in policy: policy = policy.replace("xsbench_", "")
        
        try:
            df = pd.read_csv(f)
            total_migrations = df["total_migrations"].max()
            
            # Find runtime from stderr log
            log_f = f.replace("_summary.csv", "_stderr.log")
            runtime = np.nan
            if os.path.exists(log_f):
                with open(log_f, 'r') as log:
                    for line in log:
                        if "Time:" in line or "runtime" in line.lower() or "elapsed" in line.lower():
                            try:
                                runtime = float(''.join(c for c in line.split()[-1] if c.isdigit() or c == '.'))
                            except: pass
            
            data.append({"Policy": policy, "Migrations": total_migrations, "Runtime": runtime})
        except Exception as e:
            print(f"Failed to parse {f}: {e}")
            
    return pd.DataFrame(data)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python plot_design_space.py <results_dir>")
        sys.exit(1)
        
    df = parse_results(sys.argv[1])
    if df.empty:
        print("No data found!")
        sys.exit(1)
        
    # Aggregate by policy
    agg = df.groupby("Policy").mean().reset_index()
    print(agg)
    
    plt.figure(figsize=(10, 7))
    for i, row in agg.iterrows():
        plt.scatter(row["Migrations"], row["Runtime"], s=200, label=row["Policy"])
        plt.text(row["Migrations"], row["Runtime"] * 1.02, row["Policy"], fontsize=12)
        
    plt.xlabel("Total Migrations (Cost)", fontsize=14)
    plt.ylabel("Application Runtime (s)", fontsize=14)
    plt.title("Design Space: Performance vs. Migration Overhead", fontsize=16)
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.legend()
    plt.tight_layout()
    plt.savefig("design_space.png", dpi=300)
    print("Saved plot to design_space.png")
