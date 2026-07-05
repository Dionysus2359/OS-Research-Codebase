import os
import sys
from sim.perf_model import Profile, PerfModel
from sim.memory import set_ml_margins
import pandas as pd

def run_margin_sweep():
    traces = {
        'bfs': ('traces/pin_traces/trace_bfs_128k.txt', 12400),
        'backprop': ('traces/pin_traces/trace_backprop_10000.txt', 9000)
    }
    
    ABS_THRESHOLDS = [0.10, 0.20, 0.30]
    DEMOTE_MARGINS = [0.10, 0.20, 0.30, 0.40]
    
    results = []
    
    for app, (trace_file, reqs) in traces.items():
        print(f"Loading Profile for {app}...")
        prof = Profile(trace_file)
        prof.init()
        
        for abs_thresh in ABS_THRESHOLDS:
            for margin in DEMOTE_MARGINS:
                print(f"--- Running {app}: ABS = {abs_thresh}, DEMOTE = {margin} ---")
                set_ml_margins(abs_thresh, margin)
                
                sim = PerfModel(prof, 'Fast:NearSlow', 'ml', 0.2, reqs)
                sim.init()
                sim.run()
                
                fast_hitrate = round(sim.stats['Fast_Hitrate'], 2)
                migrations = int(sim.stats['Migration_Overhead'] / 1000)
                slowdown = round(sim.stats['Slowdown_from_all_fast'], 2)
                
                results.append({
                    'App': app,
                    'ABS_Thresh': abs_thresh,
                    'Margin': margin,
                    'Fast_Hitrate(%)': fast_hitrate,
                    'Migrations': migrations,
                    'Slowdown(%)': slowdown
                })
                
    print("\n=== 2D Margin Sweep Results (Ratio 0.2) ===")
    print(f"{'App':<10} | {'ABS':<6} | {'Margin':<8} | {'Hitrate(%)':<12} | {'Migrations':<12} | {'Slowdown(%)':<12}")
    print("-" * 72)
    for res in results:
        print(f"{res['App']:<10} | {res['ABS_Thresh']:<6.2f} | {res['Margin']:<8.2f} | {res['Fast_Hitrate(%)']:<12.2f} | {res['Migrations']:<12} | {res['Slowdown(%)']:<12.2f}")

if __name__ == "__main__":
    run_margin_sweep()
