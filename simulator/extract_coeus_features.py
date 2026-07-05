import sys
import pandas as pd
from sim.perf_model import Profile

def extract_features(trace_file, reqs_per_ep, output_csv):
    prof = Profile(trace_file)
    prof.init()
    
    memory = prof.hmem
    traffic = prof.traffic
    num_periods = (traffic.num_reqs // reqs_per_ep) + 1
    
    # Track features per page per epoch
    # records = [(epoch, page_id, features_dict), ...]
    records = []
    
    # We also need to know exact accesses per epoch to compute future labels.
    # memory.counts_ep has the accesses per epoch for each page!
    memory.init_cnts(num_periods, 'ml')
    
    # Run the simulation loop without tiering, just to collect features
    curr_ep = 0
    
    for req in traffic.req_seq:
        if req.id % reqs_per_ep == 0 and req.id != 0:
            # End of epoch! Update features and record them
            memory.update_ml_features(reqs_per_ep)
            
            for page in memory.page_list:
                if page.accessed_this_epoch:
                    feat = {
                        'epoch': curr_ep,
                        'page_id': page.id,
                        'access_count': page.access_count,
                        'smooth_frequency': page.smooth_frequency,
                        'momentum': page.momentum,
                        'migration_history': page.migration_history,
                        'epochs_since_access': page.epochs_since_access,
                        'hot_ratio': page.hot_ratio,
                        'access_frequency_ratio': page.access_frequency_ratio,
                        'aci': page.aci
                    }
                    records.append(feat)
            
            curr_ep += 1
            
        page = memory.page_list[req.page_id]
        page.increase_cnt(curr_ep)
        page.epoch_access_count += 1
    
    # Final epoch
    memory.update_ml_features(reqs_per_ep)
    for page in memory.page_list:
        if page.accessed_this_epoch:
            feat = {
                'epoch': curr_ep,
                'page_id': page.id,
                'access_count': page.access_count,
                'smooth_frequency': page.smooth_frequency,
                'momentum': page.momentum,
                'migration_history': page.migration_history,
                'epochs_since_access': page.epochs_since_access,
                'hot_ratio': page.hot_ratio,
                'access_frequency_ratio': page.access_frequency_ratio,
                'aci': page.aci
            }
            records.append(feat)
            
    print(f"Extracted {len(records)} feature rows. Now labeling...")
    
    # Labeling: K-step lookahead
    K = 10
    THRESHOLD = 4
    
    labeled_records = []
    for r in records:
        ep = r['epoch']
        pid = r['page_id']
        page = memory.page_list[pid]
        
        # Look ahead K epochs
        future_accesses = 0
        for i in range(1, K + 1):
            if ep + i < num_periods:
                future_accesses += page.counts_ep[ep + i]
                
        is_hot = 1 if future_accesses >= THRESHOLD else 0
        r['is_hot'] = is_hot
        labeled_records.append(r)
        
    df = pd.DataFrame(labeled_records)
    df.to_csv(output_csv, index=False)
    print(f"Saved to {output_csv}")

if __name__ == "__main__":
    # Extract from multiple traces and combine
    traces = [
        ('bfs_128k', 12400),
        ('backprop_10000', 9000),
        ('hotspot_256', 24900)
    ]
    
    for app, reqs in traces:
        print(f"Processing {app}...")
        extract_features(f'traces/pin_traces/trace_{app}.txt', reqs, f'train_{app}.csv')
