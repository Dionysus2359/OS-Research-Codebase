import os
import csv
import sys
def parse_csv(filepath):
    total_accesses = 0
    total_hits = 0
    total_promotions = 0
    total_demotions = 0
    total_epochs = 0
    total_latency_ns = 0
    total_cxl_latency_ns = 0
    final_migration_cost = 0.0
    total_misplaced_pages = 0
    total_fast_tier_pages = 0
    
    if not os.path.exists(filepath):
        return None
        
    with open(filepath, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                acc = int(row['epoch_accesses'])
                hits = int(row['epoch_hits'])
                prom = int(row['epoch_promotions'])
                dem = int(row['epoch_demotions'])
                lat = float(row['estimated_latency_ns'])
                cxl_lat = float(row.get('cxl_estimated_latency_ns', lat)) # Fallback if missing
                mcost = float(row['migration_cost_ms'])
                misplaced = int(row.get('misplaced_pages', 0))
                ft_pages = int(row['fast_tier_pages'])
                
                total_accesses += acc
                total_hits += hits
                total_promotions += prom
                total_demotions += dem
                total_latency_ns += lat
                total_cxl_latency_ns += cxl_lat
                total_misplaced_pages += misplaced
                total_fast_tier_pages += ft_pages
                final_migration_cost = max(final_migration_cost, mcost)
                total_epochs += 1
            except ValueError:
                continue
                
    if total_accesses == 0:
        return {
            'hit_ratio': 0.0,
            'misplacement_ratio': 0.0,
            'avg_latency': 0.0,
            'cxl_latency': 0.0,
            'total_migrations': total_promotions + total_demotions,
            'total_migration_cost': final_migration_cost,
            'avg_promotions': 0.0 if total_epochs == 0 else total_promotions / total_epochs,
            'avg_demotions': 0.0 if total_epochs == 0 else total_demotions / total_epochs,
            'total_epochs': total_epochs,
        }
        
    return {
        'hit_ratio': total_hits / total_accesses,
        'misplacement_ratio': total_misplaced_pages / total_fast_tier_pages if total_fast_tier_pages > 0 else 0,
        'avg_latency': total_latency_ns / total_accesses,
        'cxl_latency': total_cxl_latency_ns / total_accesses,
        'total_migrations': total_promotions + total_demotions,
        'total_migration_cost': final_migration_cost,
        'avg_promotions': total_promotions / total_epochs,
        'avg_demotions': total_demotions / total_epochs,
        'total_epochs': total_epochs,
        'misplacement_ratio': total_misplaced_pages / total_fast_tier_pages if total_fast_tier_pages > 0 else 0,
        'app_time': None
    }


def main():
    if len(sys.argv) > 1:
        target_dir = sys.argv[1]
    else:
        target_dir = "results"
    policies = ['lru', 'lfu', 'decaying_lfu', 'ml']
    results = {}
    
    # Check if we are running for gapbs (which prefixes files with kernel name)
    # We will search for *_summary.csv
    import glob
    csv_files = glob.glob(os.path.join(target_dir, "*_summary.csv"))
    
    if not csv_files:
        print(f"No summary.csv files found in {target_dir}.")
        sys.exit(1)
        
    # Extract prefixes from files like bfs_lru_summary.csv or lru_summary.csv
    # This allows comparing all policies for a given prefix.
    prefixes = set()
    # Sort policies by length descending so we match 'decaying_lfu' before 'lfu'
    for f in csv_files:
        basename = os.path.basename(f)
        for p in sorted(policies, key=len, reverse=True):
            suffix = f"{p}_summary.csv"
            if basename.endswith(suffix):
                prefix = basename[:-len(suffix)]
                prefixes.add(prefix)
                break
                
    if not prefixes:
        prefixes.add("")
        
    for prefix in sorted(prefixes):
        if prefix:
            print(f"[{prefix.strip('_').upper()}]")
        results = {}
        for p in policies:
            filepath = os.path.join(target_dir, f"{prefix}{p}_summary.csv")
            res = parse_csv(filepath)
            if res:
                # Attempt to parse Application Time
                base_dir = os.path.basename(os.path.normpath(target_dir))
                
                stdout_path = os.path.join(target_dir, f"{prefix}{p}_stdout.log")
                    
                if os.path.exists(stdout_path):
                    try:
                        with open(stdout_path, 'r') as f:
                            for line in f:
                                if 'Average Time:' in line:
                                    res['app_time'] = float(line.split()[2])
                                elif line.startswith('Copy:'):
                                    res['app_time'] = float(line.split()[2])
                                elif '[OVERALL], RunTime(ms)' in line:
                                    res['app_time'] = float(line.split(',')[2].strip()) / 1000.0
                    except Exception:
                        pass
                        
                # Attempt to parse Microbenchmark overhead from stderr
                stderr_path = os.path.join(target_dir, f"{prefix}{p}_stderr.log")
                if os.path.exists(stderr_path):
                    try:
                        with open(stderr_path, 'r') as f:
                            sum_ov = 0.0
                            count_ov = 0
                            for line in f:
                                if '[Microbenchmark] ML Epoch Inference Time:' in line:
                                    val = float(line.split(':')[1].split()[0])
                                    sum_ov += val
                                    count_ov += 1
                            if count_ov > 0:
                                res['overhead_us'] = sum_ov / count_ov
                    except Exception:
                        pass
                results[p] = res
                
        if not results:
            continue
            
        print("=" * 60)
        print(" NUMA Tiering Policy Evaluation Metrics")
        print("=" * 60)
        
        # Print Markdown Table
        print("\n### Absolute Metrics")
        print(f"| {'Policy':<12} | {'App Time (s)':>12} | {'Hit Ratio':>10} | {'Misplaced(%)':>12} | {'Avg Lat (ns)':>12} | {'CXL Lat (ns)':>12} | {'Total Migrations':>16} | {'Mig Cost (ms)':>13} | {'Proms/Epoch':>11} | {'Dems/Epoch':>10} | {'Overhead(us)':>12} |")
        print(f"|{'-'*14}|{'-'*14}|{'-'*12}|{'-'*14}|{'-'*14}|{'-'*14}|{'-'*18}|{'-'*15}|{'-'*13}|{'-'*12}|{'-'*14}|")
        
        for p in policies:
            if p in results:
                r = results[p]
                app_time_str = f"{r['app_time']:.4f}" if r.get('app_time') is not None else "N/A"
                ov_str = f"{r['overhead_us']:.0f}" if r.get('overhead_us') is not None else "N/A"
                print(f"| {p:<12} | {app_time_str:>12} | {r['hit_ratio']*100:>9.2f}% | {r['misplacement_ratio']*100:>11.2f}% | {r['avg_latency']:>12.2f} | {r['cxl_latency']:>12.2f} | {r['total_migrations']:>16,d} | {r['total_migration_cost']:>13.2f} | {r['avg_promotions']:>11.2f} | {r['avg_demotions']:>10.2f} | {ov_str:>12} |")
                
        # Print Improvements (ML vs Decaying LFU)
        if 'ml' in results and 'decaying_lfu' in results:
            ml = results['ml']
            dlfu = results['decaying_lfu']
            
            print("\n### ML Policy Improvements vs Decaying LFU")
            
            hit_diff = (ml['hit_ratio'] - dlfu['hit_ratio']) * 100
            lat_diff = ((dlfu['avg_latency'] - ml['avg_latency']) / dlfu['avg_latency']) * 100 if dlfu['avg_latency'] > 0 else 0
            mig_diff = ((dlfu['total_migrations'] - ml['total_migrations']) / dlfu['total_migrations']) * 100 if dlfu['total_migrations'] > 0 else 0
            cost_diff = ((dlfu['total_migration_cost'] - ml['total_migration_cost']) / dlfu['total_migration_cost']) * 100 if dlfu['total_migration_cost'] > 0 else 0
            
            print(f"- **Hit Ratio**:      {abs(hit_diff):.2f}% {'higher (Better)' if hit_diff > 0 else 'lower (Worse)'}")
            
            if ml.get('app_time') is not None and dlfu.get('app_time') is not None:
                time_diff = ((dlfu['app_time'] - ml['app_time']) / dlfu['app_time']) * 100
                print(f"- **App Time**:       {abs(time_diff):.2f}% {'faster (Better)' if time_diff > 0 else 'slower (Worse)'}")
                
            print(f"- **Avg Latency**:    {abs(lat_diff):.2f}% {'better (lower)' if lat_diff > 0 else 'worse (higher)'}")
            print(f"- **Migrations**:     {abs(mig_diff):.2f}% {'fewer (Better)' if mig_diff > 0 else 'more (Worse)'}")
            print(f"- **Migration Cost**: {abs(cost_diff):.2f}% {'lower (Better)' if cost_diff > 0 else 'higher (Worse)'}")
            print("\n")
            
        # Parse AutoNUMA migrations
        autonuma_before = os.path.join(target_dir, f"{prefix}autonuma_vmstat_before.txt")
        autonuma_after = os.path.join(target_dir, f"{prefix}autonuma_vmstat_after.txt")
        
        # Fallbacks for synthetic runs
        if not os.path.exists(autonuma_before):
            base_dir = os.path.basename(os.path.normpath(target_dir))
            if base_dir == "results" or target_dir == ".":
                autonuma_before = os.path.join(target_dir, "autonuma_before.txt")
                autonuma_after = os.path.join(target_dir, "autonuma_after.txt")
        
        if os.path.exists(autonuma_before) and os.path.exists(autonuma_after):
            before_mig = 0
            after_mig = 0
            try:
                with open(autonuma_before, 'r') as f:
                    for line in f:
                        if 'numa_pages_migrated' in line:
                            before_mig = int(line.split()[1])
                with open(autonuma_after, 'r') as f:
                    for line in f:
                        if 'numa_pages_migrated' in line:
                            after_mig = int(line.split()[1])
                            
                total_autonuma_mig = after_mig - before_mig
                print(f"### AutoNUMA (Kernel-Managed)")
                print(f"- **Total Migrations**: {total_autonuma_mig:,}")
                
                # Try to parse execution time for autonuma
                base_dir = os.path.basename(os.path.normpath(target_dir))
                autonuma_stdout = os.path.join(target_dir, f"{prefix}autonuma_stdout.log")
                    
                auto_time = None
                if os.path.exists(autonuma_stdout):
                    with open(autonuma_stdout, 'r') as f:
                        for line in f:
                            if 'Average Time:' in line:
                                auto_time = float(line.split()[2])
                            elif line.startswith('Copy:'):
                                auto_time = float(line.split()[2])
                            elif '[OVERALL], RunTime(ms)' in line:
                                auto_time = float(line.split(',')[2].strip()) / 1000.0
                
                if auto_time is not None:
                    print(f"- **App Time (s)**:     {auto_time:.2f}")
                
                if 'ml' in results:
                    ml_mig = results['ml']['total_migrations']
                    if total_autonuma_mig > 0:
                        mig_diff = ((total_autonuma_mig - ml_mig) / total_autonuma_mig) * 100
                        print(f"- **ML vs AutoNUMA Mig**: {abs(mig_diff):.2f}% {'fewer migrations (Better)' if mig_diff > 0 else 'more migrations (Worse)'}")
                        
                    if auto_time is not None and results['ml'].get('app_time') is not None:
                        ml_time = results['ml']['app_time']
                        t_diff = ((auto_time - ml_time) / auto_time) * 100
                        print(f"- **ML vs AutoNUMA Time**: {abs(t_diff):.2f}% {'faster (Better)' if t_diff > 0 else 'slower (Worse)'}")
                print("\n")
            except Exception as e:
                print(f"Error parsing AutoNUMA stats: {e}")
if __name__ == '__main__':
    main()