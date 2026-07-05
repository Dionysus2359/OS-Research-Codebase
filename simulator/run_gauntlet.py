import sys
import csv
import os
from multiprocessing import Process
from sim.perf_model import Profile, PerfModel
from kleio.page_selector import PageSelector

def run_kleio_coeus(prof, cap_ratio, reqs_per_ep, resdir_prefix):
    page_selector = PageSelector(prof, 'Fast:NearSlow', cap_ratio, reqs_per_ep, resdir_prefix)
    page_selector.run_same_rnn_number()

def run_standard_policy(prof, policy, cap_ratio, reqs_per_ep, resdir_prefix):
    sim = PerfModel(prof, 'Fast:NearSlow', policy, cap_ratio, reqs_per_ep)
    sim.init()
    sim.run()
    sim.dump_stats(f'{resdir_prefix}_{policy}.csv')

def process_app(app_idx, app, app_label, cori_req, trace_dir, resdir, cap_ratio, run_kleio=True):
    print(f"[{app_label}] Starting Simulation...")
    trace_file = os.path.join(trace_dir, f'trace_{app}.txt')
    prof = Profile(trace_file)
    prof.init()

    # 1. Run Standard Policies
    policies = ['history', 'oracle', 'lru', 'lfu', 'decaying_lfu', 'ml']
    for policy in policies:
        print(f"[{app_label}] Running {policy}...")
        run_standard_policy(prof, policy, cap_ratio, cori_req, f'{resdir}/{app_label}_{cap_ratio}')

    # 2. Run Kleio & Coeus (hybrid and hybrid-group)
    if run_kleio:
        print(f"[{app_label}] Running Kleio/Coeus...")
        run_kleio_coeus(prof, cap_ratio, 100, f'{resdir}/{app_label}_{cap_ratio}')
    
    print(f"[{app_label}] Done.")

if __name__ == "__main__":
    trace_dir = 'traces/pin_traces/'
    resdir = 'results_gauntlet'
    
    os.makedirs(resdir, exist_ok=True)
    
    apps = ['backprop_10000', 'kmeans_5000', 'hotspot_256', 'quicksilver_500', 'cpd_10000', 'lud_512', 'bfs_128k', 'bptree_100k', 'pennant_leblanc']
    app_labels = ['backprop', 'kmeans', 'hotspot', 'quicksilver', 'cpd', 'lud', 'bfs', 'bptree', 'pennant']
    cori_best_perf_reqs_apps = [9000, 26000, 24900, 31100, 35500, 23200, 12400, 27600, 11700]

    # Phase A: Apples-to-Apples Baseline (0.2 ratio)
    print("=== Phase A: Baseline (0.2 ratio) ===")
    cap_ratio = 0.2
    threads = []
    for app_idx in range(len(apps)):
        app = apps[app_idx]
        app_label = app_labels[app_idx]
        cori_req = cori_best_perf_reqs_apps[app_idx]
        
        p = Process(target=process_app, args=(app_idx, app, app_label, cori_req, trace_dir, resdir, cap_ratio, True))
        p.start()
        threads.append(p)
        
    for thr in threads:
        thr.join()

    # Phase B: Capacity Sweep
    print("=== Phase B: Capacity Sweep ===")
    sweep_apps = ['bfs_128k', 'hotspot_256']
    sweep_labels = ['bfs', 'hotspot']
    sweep_reqs = [12400, 24900]
    
    sweep_ratios = [0.1, 0.3, 0.5, 0.8] # 0.2 already done
    
    for cap_ratio in sweep_ratios:
        print(f"=== Sweeping Capacity Ratio: {cap_ratio} ===")
        threads = []
        for app_idx in range(len(sweep_apps)):
            app = sweep_apps[app_idx]
            app_label = sweep_labels[app_idx]
            cori_req = sweep_reqs[app_idx]
            
            p = Process(target=process_app, args=(app_idx, app, app_label, cori_req, trace_dir, resdir, cap_ratio, False)) # Skip Kleio for sweep
            p.start()
            threads.append(p)
            
        for thr in threads:
            thr.join()
            
    print("All simulations completed.")
