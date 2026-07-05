import sys
import os
import glob
import pandas as pd

def parse_results(resdir='results_gauntlet'):
    csv_files = glob.glob(os.path.join(resdir, '*.csv'))
    if not csv_files:
        print("No results found.")
        return

    data = []
    for f in csv_files:
        filename = os.path.basename(f)
        parts = filename.replace('.csv', '').split('_')
        # format: app_ratio_policy.csv (e.g., bfs_0.2_ml.csv)
        app = parts[0]
        ratio = parts[1]
        policy = "_".join(parts[2:])

        if 'kleio' in ratio:
            ratio_num = ratio.replace('kleio', '')
            policy = f"kleio_{policy}"
            ratio = ratio_num
        elif 'coeus' in ratio:
            ratio_num = ratio.replace('coeus', '')
            policy = f"coeus_{policy}"
            ratio = ratio_num

        df = pd.read_csv(f, header=None, names=['Metric', 'Value'])
        metrics = dict(zip(df['Metric'], df['Value']))
        
        fast_hitrate = float(metrics.get('Fast_Hitrate', 0.0))
        migrations = float(metrics.get('Migration_Overhead', 0.0)) / 1000.0  # 1000ns per migr
        slowdown = float(metrics.get('Slowdown_from_all_fast', 0.0))
        
        # New metrics requested
        runtime_ms = float(metrics.get('Runtime', 0.0)) / 1_000_000.0
        
        period_oh = float(metrics.get('Period_Overhead', 0.0))
        mig_oh = float(metrics.get('Migration_Overhead', 0.0))
        q_oh = float(metrics.get('Queue_Overhead', 0.0))
        
        alg_overhead_ms = (period_oh + q_oh) / 1_000_000.0
        mig_overhead_ms = mig_oh / 1_000_000.0        
        num_pages = float(metrics.get('Num_Pages', 1.0))
        total_misplaced_epochs = float(metrics.get('Total_Misplaced_Epochs', 0.0))
        num_periods = float(metrics.get('Number_of_Periods', 1.0))
        
        l1_pages = int(num_pages * float(ratio))
        total_possible = num_periods * l1_pages
        misplaced_ratio = (total_misplaced_epochs / total_possible) * 100.0 if total_possible > 0 else 0.0

        data.append({
            'App': app,
            'Ratio': ratio,
            'Policy': policy,
            'Hitrate(%)': round(fast_hitrate, 2),
            'Misplaced(%)': round(misplaced_ratio, 3),
            'Runtime(ms)': int(runtime_ms),
            'Alg_OH(ms)': int(alg_overhead_ms),
            'Mig_OH(ms)': int(mig_overhead_ms),
            'Migrations': int(migrations),
            'Slowdown(%)': round(slowdown, 2)
        })

    df = pd.DataFrame(data)

    print("=== Phase A: Baseline (0.2 Ratio) ===")
    df_a = df[df['Ratio'] == '0.2']
    # Group by App, then show Policies
    for app in df_a['App'].unique():
        print(f"\n--- App: {app} ---")
        sub = df_a[df_a['App'] == app].sort_values('Slowdown(%)')
        print(f"{'Policy':<15} | {'Hitrate(%)':<10} | {'Runtime(ms)':<12} | {'Alg_OH(ms)':<10} | {'Mig_OH(ms)':<10} | {'Migrations':<10} | {'Slowdown(%)':<12} | {'Misplaced(%)':<12}")
        print("-" * 115)
        for _, row in sub.iterrows():
            print(f"{row['Policy']:<15} | {row['Hitrate(%)']:<10.2f} | {row['Runtime(ms)']:<12} | {row['Alg_OH(ms)']:<10} | {row['Mig_OH(ms)']:<10} | {row['Migrations']:<10} | {row['Slowdown(%)']:<12.2f} | {row['Misplaced(%)']:<12.3f}")

    print("\n=== Phase B: Capacity Sweep ===")
    df_b = df[df['Ratio'] != '0.2']
    if not df_b.empty:
        for app in df_b['App'].unique():
            print(f"\n--- App: {app} ---")
            sub = df_b[df_b['App'] == app].sort_values(['Ratio', 'Slowdown(%)'])
            print(f"{'Ratio':<6} | {'Policy':<15} | {'Hitrate(%)':<10} | {'Runtime(ms)':<12} | {'Alg_OH(ms)':<10} | {'Mig_OH(ms)':<10} | {'Migrations':<10} | {'Slowdown(%)':<12} | {'Misplaced(%)':<12}")
            print("-" * 125)
            for _, row in sub.iterrows():
                print(f"{row['Ratio']:<6} | {row['Policy']:<15} | {row['Hitrate(%)']:<10.2f} | {row['Runtime(ms)']:<12} | {row['Alg_OH(ms)']:<10} | {row['Mig_OH(ms)']:<10} | {row['Migrations']:<10} | {row['Slowdown(%)']:<12.2f} | {row['Misplaced(%)']:<12.3f}")

if __name__ == "__main__":
    parse_results()
