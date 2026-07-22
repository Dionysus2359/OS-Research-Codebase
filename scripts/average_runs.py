import os
import sys
import glob
from collections import defaultdict
import statistics

def parse_csv(filepath):
    import csv
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
                cxl_lat = float(row.get('cxl_estimated_latency_ns', lat))
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
            'avg_promotions': total_promotions / total_epochs if total_epochs > 0 else 0,
            'avg_demotions': total_demotions / total_epochs if total_epochs > 0 else 0,
            'total_epochs': total_epochs,
        }
        
    return {
        'hit_ratio': total_hits / total_accesses,
        'misplacement_ratio': total_misplaced_pages / total_fast_tier_pages if total_fast_tier_pages > 0 else 0,
        'avg_latency': total_latency_ns / total_accesses,
        'cxl_latency': total_cxl_latency_ns / total_accesses,
        'total_migrations': total_promotions + total_demotions,
        'total_migration_cost': final_migration_cost,
        'avg_promotions': total_promotions / total_epochs if total_epochs > 0 else 0,
        'avg_demotions': total_demotions / total_epochs if total_epochs > 0 else 0,
        'total_epochs': total_epochs,
        'app_time': None,
        'overhead_us': None
    }

def main():
    if len(sys.argv) > 1:
        target_dir = sys.argv[1]
    else:
        print("Usage: python3 average_runs.py <workload_results_dir>")
        sys.exit(1)
        
    runs_dirs = glob.glob(os.path.join(target_dir, "run_*"))
    if not runs_dirs:
        print(f"No run_* directories found in {target_dir}.")
        sys.exit(1)
        
    policies = ['lru', 'lfu', 'decaying_lfu', 'ml', 'autonuma']
    
    # Prefix -> Policy -> list of metrics dictionaries
    aggregated_results = defaultdict(lambda: defaultdict(list))
    
    for run_dir in runs_dirs:
        csv_files = glob.glob(os.path.join(run_dir, "*_summary.csv"))
        for f in csv_files:
            basename = os.path.basename(f)
            prefix = ""
            policy = ""
            for p in sorted(policies, key=len, reverse=True):
                suffix = f"{p}_summary.csv"
                if basename.endswith(suffix):
                    prefix = basename[:-len(suffix)]
                    policy = p
                    break
            
            if not policy:
                continue
                
            res = parse_csv(f)
            if res:
                # App time parsing
                stdout_log = os.path.join(run_dir, f"{prefix}{policy}_stdout.log")
                if os.path.exists(stdout_log):
                    with open(stdout_log, 'r') as outf:
                        content = outf.read()
                        import re
                        if "redis" in target_dir.lower():
                            m = re.search(r'\[OVERALL\], RunTime\(ms\), ([\d\.]+)', content)
                            if m:
                                res['app_time'] = float(m.group(1)) / 1000.0
                        elif "gapbs" in target_dir.lower():
                            m = re.search(r'Average Time:\s+([\d\.]+)', content)
                            if m:
                                res['app_time'] = float(m.group(1))
                        else:
                            m = re.search(r'User: ([\d\.]+)', content)
                            if m:
                                res['app_time'] = float(m.group(1))
                
                # Overhead parsing
                stderr_log = os.path.join(run_dir, f"{prefix}{policy}_stderr.log")
                if os.path.exists(stderr_log):
                    try:
                        with open(stderr_log, 'r') as errf:
                            lines = errf.readlines()
                            sum_ov = 0
                            count_ov = 0
                            for line in lines:
                                if "[Microbenchmark]" in line:
                                    parts = line.split()
                                    for i, part in enumerate(parts):
                                        if part == "Time:" and i + 1 < len(parts):
                                            sum_ov += float(parts[i+1])
                                            count_ov += 1
                            if count_ov > 0:
                                res['overhead_us'] = sum_ov / count_ov
                    except Exception:
                        pass
                
                aggregated_results[prefix][policy].append(res)
                
                # AutoNUMA parsing for average_runs
                if policy == 'ml':  # Only parse once per run
                    autonuma_before = os.path.join(run_dir, f"{prefix}autonuma_vmstat_before.txt")
                    autonuma_after = os.path.join(run_dir, f"{prefix}autonuma_vmstat_after.txt")
                    if not os.path.exists(autonuma_before):
                        if os.path.exists(os.path.join(run_dir, "autonuma_before.txt")):
                            autonuma_before = os.path.join(run_dir, "autonuma_before.txt")
                            autonuma_after = os.path.join(run_dir, "autonuma_after.txt")
                    
                    if os.path.exists(autonuma_before) and os.path.exists(autonuma_after):
                        before_mig = 0
                        after_mig = 0
                        try:
                            with open(autonuma_before, 'r') as f:
                                for l in f:
                                    if 'numa_pages_migrated' in l:
                                        before_mig = int(l.split()[1])
                            with open(autonuma_after, 'r') as f:
                                for l in f:
                                    if 'numa_pages_migrated' in l:
                                        after_mig = int(l.split()[1])
                            if 'autonuma' not in aggregated_results[prefix]:
                                aggregated_results[prefix]['autonuma'] = []
                            
                            auto_res = {'total_migrations': after_mig - before_mig}
                            
                            autonuma_stdout = os.path.join(run_dir, f"{prefix}autonuma_stdout.log")
                            if not os.path.exists(autonuma_stdout):
                                if os.path.exists(os.path.join(run_dir, "autonuma_workload_stdout.log")):
                                    autonuma_stdout = os.path.join(run_dir, "autonuma_workload_stdout.log")
                                elif os.path.exists(os.path.join(run_dir, "autonuma_stdout.log")):
                                    autonuma_stdout = os.path.join(run_dir, "autonuma_stdout.log")
                                
                            if os.path.exists(autonuma_stdout):
                                with open(autonuma_stdout, 'r') as f:
                                    content = f.read()
                                    import re
                                    if "redis" in target_dir.lower():
                                        m = re.search(r'\[OVERALL\], RunTime\(ms\), ([\d\.]+)', content)
                                        if m: auto_res['app_time'] = float(m.group(1)) / 1000.0
                                    elif "gapbs" in target_dir.lower():
                                        m = re.search(r'Average Time:\s+([\d\.]+)', content)
                                        if m: auto_res['app_time'] = float(m.group(1))
                                    else:
                                        m = re.search(r'User: ([\d\.]+)', content)
                                        if m: auto_res['app_time'] = float(m.group(1))
                            
                            aggregated_results[prefix]['autonuma'].append(auto_res)
                        except Exception:
                            pass
    for prefix, policy_runs in aggregated_results.items():
        title = prefix.strip('_')
        if not title:
            title = os.path.basename(target_dir.rstrip('/'))
            
        print("=" * 100)
        print(f" {title.upper()} - AVERAGED METRICS ACROSS {len(runs_dirs)} RUNS")
        print("=" * 100)
        
        print(f"\n### Absolute Metrics (Mean ± StdDev)")
        print(f"| {'Policy':<12} | {'App Time (s)':>19} | {'Hit Ratio (%)':>15} | {'Misplaced (%)':>15} | {'Avg Lat (ns)':>19} | {'CXL Lat (ns)':>19} | {'Total Migrations':>20} | {'Mig Cost (ms)':>15} | {'Overhead (us)':>15} |")
        print(f"|{'-'*14}|{'-'*21}|{'-'*17}|{'-'*17}|{'-'*21}|{'-'*21}|{'-'*22}|{'-'*17}|{'-'*17}|")
        
        for p in policies:
            if p in policy_runs:
                runs = policy_runs[p]
                
                def calc_stat(key):
                    vals = [r[key] for r in runs if r.get(key) is not None]
                    if not vals:
                        return "N/A"
                    if len(vals) == 1:
                        return f"{vals[0]:.4f}"
                    mean = statistics.mean(vals)
                    std = statistics.stdev(vals)
                    return f"{mean:.4f}±{std:.4f}"
                    
                def calc_stat_pct(key):
                    vals = [r[key]*100 for r in runs if r.get(key) is not None]
                    if not vals:
                        return "N/A"
                    if len(vals) == 1:
                        return f"{vals[0]:.2f}"
                    mean = statistics.mean(vals)
                    std = statistics.stdev(vals)
                    return f"{mean:.2f}±{std:.2f}"
                
                def calc_stat_int(key):
                    vals = [r[key] for r in runs if r.get(key) is not None]
                    if not vals:
                        return "N/A"
                    if len(vals) == 1:
                        return f"{int(vals[0])}"
                    mean = statistics.mean(vals)
                    std = statistics.stdev(vals)
                    return f"{int(mean)}±{int(std)}"

                app_time = calc_stat('app_time')
                hit_ratio = calc_stat_pct('hit_ratio')
                misplaced = calc_stat_pct('misplacement_ratio')
                avg_lat = calc_stat('avg_latency')
                cxl_lat = calc_stat('cxl_latency')
                migs = calc_stat_int('total_migrations')
                mig_cost = calc_stat('total_migration_cost')
                ov = calc_stat_int('overhead_us')
                
                print(f"| {p:<12} | {app_time:>19} | {hit_ratio:>15} | {misplaced:>15} | {avg_lat:>19} | {cxl_lat:>19} | {migs:>20} | {mig_cost:>15} | {ov:>15} |")
                
if __name__ == '__main__':
    main()
