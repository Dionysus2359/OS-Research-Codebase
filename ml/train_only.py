import pandas as pd
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import f1_score, balanced_accuracy_score
import os

# --- YOU CAN INSTANTLY TEST FEATURES HERE ---
FEATURE_COLS = [
    "access_count",
    "momentum",
    "access_frequency_ratio",
    # "smooth_frequency",
    # "aci"
]

print("Loading pre-labeled dataset...")
if not os.path.exists("labeled_dataset.csv"):
    print("Error: labeled_dataset.csv not found! Run label_and_train_v2.py first.")
    exit(1)

df_labeled = pd.read_csv("labeled_dataset.csv")

def train_and_eval(train_df, test_df, name):
    X_tr = train_df[FEATURE_COLS].values
    y_tr = train_df["label"].values
    X_te = test_df[FEATURE_COLS].values
    y_te = test_df["label"].values
    
    scaler = StandardScaler()
    X_tr_sc = scaler.fit_transform(X_tr)
    X_te_sc = scaler.transform(X_te)
    
    # YOU CAN CHANGE REGULARIZATION (C) HERE!
    model = LogisticRegression(class_weight='balanced', max_iter=1000, C=1.0)
    model.fit(X_tr_sc, y_tr)
    
    preds = model.predict(X_te_sc)
    
    b_acc = balanced_accuracy_score(y_te, preds)
    f1 = f1_score(y_te, preds, zero_division=0)
    print(f"[{name}] Balanced Acc: {b_acc:.3f} | F1: {f1:.3f}")
    return model, scaler

print("\n--- Leave-One-Workload-Out Cross-Validation ---")
workloads = df_labeled['workload'].unique()

for target_wl in workloads:
    test_df = df_labeled[df_labeled['workload'] == target_wl]
    train_df = df_labeled[df_labeled['workload'] != target_wl]
    train_wls = "+".join([w for w in workloads if w != target_wl])
    train_and_eval(train_df, test_df, f"Train: {train_wls} -> Test: {target_wl}")

print("\n--- Final Model (Combined Data) ---")
df_train, df_test = train_test_split(df_labeled, test_size=0.2, random_state=42, stratify=df_labeled['label'])
model, scaler = train_and_eval(df_train, df_test, "Train: Combined -> Test: 20% Held-out")

print("\nWeight analysis (Final Model):")
for f, w in zip(FEATURE_COLS, model.coef_[0]):
    print(f"  {f:<25} -> weight = {w:+.4f}")
print(f"  {'bias':<25} -> {model.intercept_[0]:+.4f}")
