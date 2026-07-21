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

print("Loading trace data...")
dfs = []
for name, path in traces.items():
    if os.path.exists(path):
        df = pd.read_csv(path)
        df['workload'] = name
        dfs.append(df)
    else:
        print(f"WARNING: Trace file {path} not found. Skipping {name}.")

if not dfs:
    print("No trace files found. Exiting.")
    exit(1)

df_all = pd.concat(dfs, ignore_index=True)

# Workload-aware filtering
# Synthetic: discriminative phases (2, 6)
# PageRank/BFS: all phases (it only has phase 1)
df_filtered = df_all[
    ((df_all['workload'] == 'synthetic') & (df_all['phase'].isin([2, 6]))) |
    (df_all['workload'].isin(['pagerank', 'bfs', 'redis']))
].copy()

print("Building indices...")
df_lookup = df_all.set_index(["workload", "epoch", "page_va"]).sort_index()

# Max epoch per workload-phase to prevent boundary crossing
phase_max_epoch = df_all.groupby(["workload", "phase"])["epoch"].max().to_dict()

def get_label_params(workload_name):
    if workload_name == "bfs":
        return 5, 3  # Tight window for frontier searches
    else:
        return 10, 4 # Standard for PR and Synthetic

def label_page(workload, epoch, page_va, phase_at_T):
    lookahead_k, threshold = get_label_params(workload)
    
    # Guard against phase boundary crossing
    if epoch + lookahead_k > phase_max_epoch[(workload, phase_at_T)]:
        return None

    count = 0
    for k in range(1, lookahead_k + 1):
        target_epoch = epoch + k
        try:
            row = df_lookup.loc[(workload, target_epoch, page_va)]
            count += int(row["accessed"])
        except KeyError:
            pass
            
    return 1 if count >= threshold else 0

FEATURE_COLS = [
    "access_count",
    "smooth_frequency",
    "momentum",
    "hot_ratio",
    "access_frequency_ratio",
    "aci",
]

df_all["access_count"] = np.log1p(df_all["access_count"])

print("Downsampling data before labeling to prevent OOM...")
MAX_SAMPLES = 330000

balanced_dfs = []
for w in df_filtered['workload'].unique():
    df_w = df_filtered[df_filtered['workload'] == w]
    if len(df_w) > MAX_SAMPLES:
        print(f"  Downsampling {w} from {len(df_w)} to {MAX_SAMPLES}")
        df_w = df_w.sample(n=MAX_SAMPLES, random_state=42)
    balanced_dfs.append(df_w)

df_filtered_sampled = pd.concat(balanced_dfs, ignore_index=True)

print("Labeling downsampled data...")
records = []
total_rows = len(df_filtered_sampled)

for i, row in enumerate(df_filtered_sampled.itertuples(index=False)):
    if i % 100000 == 0 and i > 0:
        print(f"  Processed {i}/{total_rows} rows...")
        
    workload = row.workload
    epoch = row.epoch
    page_va = row.page_va
    phase_at_T = row.phase
    
    lookahead_k, threshold = get_label_params(workload)
    
    if epoch + lookahead_k > phase_max_epoch[(workload, phase_at_T)]:
        continue
        
    count = 0
    for k in range(1, lookahead_k + 1):
        target_epoch = epoch + k
        try:
            future_row = df_lookup.loc[(workload, target_epoch, page_va)]
            count += int(future_row["accessed"])
        except KeyError:
            pass
            
    label = 1 if count >= threshold else 0
    
    records.append({
        "workload": workload,
        "access_count": row.access_count,
        "smooth_frequency": row.smooth_frequency,
        "momentum": row.momentum,
        "hot_ratio": row.hot_ratio,
        "access_frequency_ratio": row.access_frequency_ratio,
        "aci": row.aci,
        "label": label,
    })

df_labeled = pd.DataFrame(records)
print(f"\nTotal labeled samples: {len(df_labeled)}")
for wl in df_labeled['workload'].unique():
    subset = df_labeled[df_labeled['workload'] == wl]
    print(f"  {wl}: {len(subset)} samples ({np.mean(subset['label']):.3f} positive rate)")

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
