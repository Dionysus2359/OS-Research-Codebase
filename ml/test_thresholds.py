import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import precision_recall_curve
import sys

FEATURE_COLS = [
    "access_count", 
    "momentum", 
    "access_frequency_ratio",
    # "epochs_since_access"
]

try:
    df = pd.read_csv("labeled_dataset.csv")
except FileNotFoundError:
    print("Error: labeled_dataset.csv not found! Run label_and_train_v2.py first.")
    sys.exit(1)

X = df[FEATURE_COLS].values
y = df["label"].values

scaler = StandardScaler()
X_scaled = scaler.fit_transform(X)

model = LogisticRegression(C=0.01, class_weight='balanced', max_iter=2000)
model.fit(X_scaled, y)

probs = model.predict_proba(X_scaled)[:, 1]
precision, recall, thresholds = precision_recall_curve(y, probs)

print(f"--- Precision-Recall Curve (Features: {len(FEATURE_COLS)}) ---")
for target_recall in [0.95, 0.90, 0.85, 0.80, 0.70, 0.60, 0.50]:
    idx = (abs(recall - target_recall)).argmin()
    thresh = thresholds[idx] if idx < len(thresholds) else 1.0
    print(f"target recall={target_recall:.2f} -> threshold={thresh:.3f}, "
          f"actual recall={recall[idx]:.3f}, precision={precision[idx]:.3f}")
