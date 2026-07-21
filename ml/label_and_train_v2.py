import pandas as pd
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import f1_score, balanced_accuracy_score, classification_report
import os

traces = {
    'synthetic': 'traces/trace_random.csv',
    'bfs':       'traces/trace_random_bfs.csv',
    'pagerank':  'traces/trace_random_pr.csv',
    'redis':     'traces/trace_random_redis.csv'
}

print("Loading trace data and processing workloads one by one...")

def get_label_params(workload_name):
    if workload_name == "bfs":
        return 5, 3  # Tight window for frontier searches
    else:
        return 10, 4 # Standard for PR and Synthetic

FEATURE_COLS = [
    "access_count",
    "momentum",
    "access_frequency_ratio"
]

all_balanced_dfs = []
MAX_SAMPLES = 330000

for name, path in traces.items():
    if not os.path.exists(path):
        print(f"WARNING: Trace file {path} not found. Skipping {name}.")
        continue
        
    print(f"\n--- Processing Workload: {name} ---")
    print(f"  Loading {path}...")
    df_wl = pd.read_csv(path)
    df_wl['workload'] = name
    
    # Workload-aware filtering
    if name == 'synthetic':
        df_filtered = df_wl[df_wl['phase'].isin([2, 6])].copy()
    else:
        df_filtered = df_wl.copy()
        
    print("  Building indices for lookup...")
    df_lookup = df_wl.set_index(["epoch", "page_va"]).sort_index()
    phase_max_epoch = df_wl.groupby("phase")["epoch"].max().to_dict()
    
    df_filtered["access_count"] = np.log1p(df_filtered["access_count"])
    
    print("  Labeling data...")
    records = []
    total_rows = len(df_filtered)
    
    for i, row in enumerate(df_filtered.itertuples(index=False)):
        if i % 5000000 == 0 and i > 0:
            print(f"    Processed {i}/{total_rows} rows...")
            
        epoch = row.epoch
        page_va = row.page_va
        phase_at_T = row.phase
        
        lookahead_k, threshold = get_label_params(name)
        
        if epoch + lookahead_k > phase_max_epoch[phase_at_T]:
            continue
            
        count = 0
        for k in range(1, lookahead_k + 1):
            target_epoch = epoch + k
            try:
                future_row = df_lookup.loc[(target_epoch, page_va)]
                count += int(future_row["accessed"])
            except KeyError:
                pass
                
        label = 1 if count >= threshold else 0
        
        records.append({
            "workload": name,
            "access_count": row.access_count,
            "momentum": row.momentum,
            "access_frequency_ratio": row.access_frequency_ratio,
            "label": label,
        })
        
    df_labeled_wl = pd.DataFrame(records)
    
    print("  Applying stratified downsampling...")
    df_pos = df_labeled_wl[df_labeled_wl["label"] == 1]
    df_neg = df_labeled_wl[df_labeled_wl["label"] == 0]
    
    print(f"    Total Positives: {len(df_pos)}")
    print(f"    Total Negatives: {len(df_neg)}")
    
    neg_to_keep = max(0, MAX_SAMPLES - len(df_pos))
    
    if len(df_neg) > neg_to_keep:
        print(f"    Downsampling negatives from {len(df_neg)} to {neg_to_keep}...")
        df_neg_sampled = df_neg.sample(n=neg_to_keep, random_state=42)
    else:
        df_neg_sampled = df_neg
        
    df_balanced = pd.concat([df_pos, df_neg_sampled], ignore_index=True)
    print(f"  {name} balanced samples: {len(df_balanced)} ({np.mean(df_balanced['label']):.3f} positive rate)")
    
    all_balanced_dfs.append(df_balanced)
    
    del df_wl, df_filtered, df_lookup, records, df_labeled_wl, df_pos, df_neg, df_balanced, df_neg_sampled

if not all_balanced_dfs:
    print("No traces processed. Exiting.")
    exit(1)

df_labeled = pd.concat(all_balanced_dfs, ignore_index=True)
print(f"\nTotal labeled samples across all workloads: {len(df_labeled)}")

print("\n--- Feature Correlation Matrix ---")
print(df_labeled[FEATURE_COLS + ["label"]].corr())

import sys
if "--corr-only" in sys.argv:
    print("\nExiting early (correlation check only).")
    sys.exit(0)

def train_and_eval(train_df, test_df, name):
    X_tr = train_df[FEATURE_COLS].values
    y_tr = train_df["label"].values
    X_te = test_df[FEATURE_COLS].values
    y_te = test_df["label"].values
    
    scaler = StandardScaler()
    X_tr_scaled = scaler.fit_transform(X_tr)
    X_te_scaled = scaler.transform(X_te)
    
    model = LogisticRegression(C=0.01, class_weight='balanced', max_iter=2000)
    model.fit(X_tr_scaled, y_tr)
    
    y_pred = model.predict(X_te_scaled)
    acc = balanced_accuracy_score(y_te, y_pred)
    f1 = f1_score(y_te, y_pred)
    print(f"[{name}] Balanced Acc: {acc:.3f} | F1: {f1:.3f}")
    return model, scaler

workloads = sorted(df_labeled['workload'].unique())
print("\n--- Leave-One-Workload-Out Cross-Validation ---")
for held_out in workloads:
    train_wls = [w for w in workloads if w != held_out]
    if len(train_wls) > 0:
        train_and_eval(
            df_labeled[df_labeled['workload'].isin(train_wls)],
            df_labeled[df_labeled['workload'] == held_out],
            f"Train: {'+'.join(train_wls)} -> Test: {held_out}"
        )

print("\n--- Final Model (Combined Data) ---")
train_df, test_df = train_test_split(df_labeled, test_size=0.2, stratify=df_labeled["label"], random_state=42)
final_model, final_scaler = train_and_eval(train_df, test_df, "Train: Combined -> Test: 20% Held-out")

print("\nWeight analysis (Final Model):")
weights = final_model.coef_[0]
bias = final_model.intercept_[0]
means = final_scaler.mean_
stds = final_scaler.scale_

for i, col in enumerate(FEATURE_COLS):
    print(f"  {col:25s} -> weight = {weights[i]:+.4f}")
print(f"  {'bias':25s} -> {bias:+.4f}")

# Guard: if any std is near-zero, clamp to 1.0
for i in range(len(stds)):
    if stds[i] < 1e-10:
        stds[i] = 1.0

out_path = "../daemon/ml_weights.h"
with open(out_path, "w") as f:
    f.write("#pragma once\n")
    f.write("// Auto-generated by ml/label_and_train_v2.py — DO NOT EDIT\n")
    f.write(f'// Feature order: {", ".join(FEATURE_COLS)}\n')
    f.write(f"constexpr int ML_NUM_FEATURES = {len(FEATURE_COLS)};\n\n")
    f.write(f'constexpr double ML_WEIGHTS[ML_NUM_FEATURES] = {{{", ".join(f"{w:.10f}" for w in weights)}}};\n')
    f.write(f"constexpr double ML_BIAS = {bias:.10f};\n\n")
    f.write(f'constexpr double ML_SCALER_MEAN[ML_NUM_FEATURES] = {{{", ".join(f"{m:.10f}" for m in means)}}};\n')
    f.write(f'constexpr double ML_SCALER_STD[ML_NUM_FEATURES]  = {{{", ".join(f"{s:.10f}" for s in stds)}}};\n')

print(f"\nExported to {out_path}")
