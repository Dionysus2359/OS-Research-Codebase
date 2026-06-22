#ML-Assisted Memory Tiering for CXL Systems

An intelligent, eBPF-driven memory page placement daemon for heterogeneous DRAM/CXL memory systems. Coeus monitors page-level access patterns in real time via hardware performance counters (Intel PEBS) and uses a trained logistic regression model with CUSUM change-point detection to decide which pages belong in fast DRAM and which can safely reside in slower CXL-attached memory.

## Table of Contents

- [Motivation](#motivation)
- [Architecture](#architecture)
- [Workloads](#workloads)
- [ML Pipeline](#ml-pipeline)
- [CUSUM Change-Point Detection](#cusum-change-point-detection)
- [Results](#results)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Reproducing Results](#reproducing-results)
- [Retraining the Model](#retraining-the-model)
- [CloudLab Deployment](#cloudlab-deployment)
- [License](#license)

---

## Motivation

Modern data centers increasingly pair fast, expensive DRAM with slower, high-capacity CXL-attached memory. The operating system must decide which memory pages belong in each tier. The Linux kernel's default page placement (AutoNUMA) reacts to page faults but lacks predictive intelligence, leading to excessive migrations and latency spikes.

This project explores whether a lightweight ML model — trained offline on historical page-access traces collected via eBPF/PEBS — can make smarter promote/demote decisions than traditional heuristics (LRU, LFU, Decaying LFU) while minimizing costly `move_pages()` syscalls. We evaluate across **four diverse workloads** (Synthetic, Graph Analytics, Streaming, and Database) to demonstrate cross-workload generalization.

---

## Architecture

The system is composed of four cooperating subsystems:

```
┌──────────────────────┐
│     Workloads         │
│  ┌────────────────┐  │       ┌─────────────────────────────────┐
│  │ Synthetic      │  │       │     Coeus Monitoring Daemon      │
│  │ GAPBS (BFS/PR) │──┼──────▶│     (C++17, runs as root)       │
│  │ STREAM         │  │  IPC  │                                  │
│  │ Redis + YCSB   │  │       │  ┌────────────┐  ┌───────────┐  │
│  └────────────────┘  │       │  │eBPF Sampler│  │  CUSUM     │  │
└──────────────────────┘       │  │(PEBS/PMU)  │  │ Detector   │  │
                               │  └─────┬──────┘  └─────┬─────┘  │
                               │        │               │         │
                               │  ┌─────▼───────────────▼──────┐  │
                               │  │     Policy Engine           │  │
                               │  │  LRU / LFU / Decaying LFU  │  │
                               │  │  ML: sigmoid(w·x + b)      │  │
                               │  └─────────────┬──────────────┘  │
                               │           move_pages()           │
                               │          Node 1 ⇄ Node 0        │
                               └──────────┬──────────────────────┘
                                          │ weights
                               ┌──────────┴──────────────┐
                               │   ML Training Pipeline   │
                               │   (Python / scikit-learn) │
                               │   Logistic Regression     │
                               │   → ml_weights.h          │
                               └───────────────────────────┘
```

### How It Works (per 100ms epoch)

1. **Sample** — An eBPF program attached to the `PERF_COUNT_HW_CPU_CYCLES` PMU event captures memory access samples from the kernel. The userspace daemon reads a BPF hash map keyed by `(pid, page_address)` to determine which pages were accessed.
2. **Feature Extraction** — For each tracked page, 6 features are computed:
   - `access_count` — Cumulative access count
   - `smooth_frequency` — Exponentially-weighted moving average of access rate
   - `momentum` — First derivative of smooth frequency (acceleration)
   - `hot_ratio` — Fraction of epochs where the page was accessed
   - `access_frequency_ratio` — Page's access share relative to global mean
   - `aci` — Access Count Integral (cumulative area under access curve)
3. **Decide** — The active policy scores each page:
   - **Classical policies** (LRU, LFU, Decaying LFU): score based on recency/frequency
   - **ML policy**: applies `sigmoid(w · x + b)` using pre-trained, StandardScaler-normalized weights compiled into [`daemon/ml_weights.h`](daemon/ml_weights.h)
4. **Adapt** — The CUSUM change-point detector monitors the promotion rate signal. When a phase transition is detected (e.g., working set shift), it temporarily loosens migration thresholds to allow rapid adaptation, then tightens them to prevent thrashing.
5. **Migrate** — Top-scoring cold-tier pages are promoted to Node 0 (DRAM); lowest-scoring hot-tier pages are demoted to Node 1 (CXL). Migrations use the `move_pages()` syscall.

---

## Workloads

The system is evaluated across four diverse workloads to demonstrate generalization:

### 1. Synthetic Workload (`workload/workload.cpp`)

A custom 6-phase memory stress test that exercises distinct access patterns:

| Phase | Name | Description |
|:-----:|------|-------------|
| 1 | Sequential Scan | Linear sweep across all 2048 pages |
| 2 | Zipf Loop | Zipf(s=1.2) over 384-page hot set |
| 3 | Burst | 8 extreme hotspot pages amid uniform random noise |
| 4 | Pointer-Chase | Randomized linked-list traversal across all pages |
| 5 | Random Uniform | Uniform random access across entire address space |
| 6 | New Data Zipf | Working set shifts to the *last* 384 pages |

### 2. GAPBS — Graph Analytics (`workload/gapbs/`)

The [GAP Benchmark Suite](https://github.com/sbeamer/gapbs) provides real graph algorithm workloads:
- **BFS** (Breadth-First Search) — Irregular, frontier-driven access patterns
- **PR** (PageRank) — Iterative, convergence-driven access with high locality

Graphs are generated synthetically at configurable scale (e.g., Scale 20 = ~1M vertices, Scale 25 = ~33M vertices).

### 3. STREAM (`workload/stream.c`)

The [STREAM benchmark](https://www.cs.virginia.edu/stream/) measures sustained memory bandwidth with large sequential array operations (Copy, Scale, Add, Triad).

### 4. Redis + YCSB (`workload/ycsb/`)

[Redis](https://redis.io/) key-value store driven by [YCSB](https://github.com/brianfrankcooper/YCSB) (Yahoo Cloud Serving Benchmark) with Workload A (50/50 read/update, Zipfian key distribution). This tests real database access patterns. YCSB is automatically patched for Python 3 compatibility at runtime.

---

## ML Pipeline

### Training Data Collection

Training traces are collected by running the daemon in **trace mode** (`--trace`) with the `random` policy against each workload. This produces per-page, per-epoch CSV files with all 6 features.

### Labeling Strategy

The training script ([`ml/label_and_train_v2.py`](ml/label_and_train_v2.py)) uses **K-step lookahead labeling**:
- For each page at epoch *t*, look ahead *K=10* epochs
- If the page is accessed in ≥ 4 of the next 10 epochs → label **HOT** (promote)
- Otherwise → label **COLD** (demote)

This forward-looking labeling teaches the model to predict *future* hotness rather than react to past counts.

### Model

- **Algorithm**: Logistic Regression with `class_weight='balanced'`
- **Normalization**: StandardScaler (mean/std embedded into the C++ header)
- **Deployment**: Weights, bias, scaler parameters are exported as `constexpr` arrays in [`daemon/ml_weights.h`](daemon/ml_weights.h) — **zero runtime dependency on Python**
- **Inference cost**: A single dot product + sigmoid per page per epoch (~0ms overhead)

### Cross-Workload Validation (LOWO)

The training script supports **Leave-One-Workload-Out** cross-validation:
- Train on 3 workloads, test on the held-out workload
- Reports balanced accuracy and F1 per fold
- Validates that the model generalizes across fundamentally different access patterns

---

## CUSUM Change-Point Detection

The daemon uses an **Adaptive CUSUM (Cumulative Sum)** detector to sense workload phase transitions in real time. It monitors the epoch-over-epoch promotion rate as a signal.

When a change-point is detected (e.g., the working set abruptly shifts):
1. **React phase** (5 epochs): Thresholds are loosened to allow rapid migration to the new working set
2. **Transition phase** (20 epochs): Thresholds gradually tighten via linear interpolation
3. **Stable phase**: Conservative thresholds prevent unnecessary churn

The tuned parameters (`ABS_THRESHOLD=0.30`, `DEMOTE_MARGIN=0.40`) were found via grid sweep ([`scripts/sweep_live.sh`](scripts/sweep_live.sh)).

---

## Repository Structure

```
project/
├── daemon/                      # Core monitoring daemon (C++17)
│   ├── daemon.cpp               # Main loop: attach → sample → decide → migrate
│   ├── ebpf_sampler.cpp/.h      # eBPF/PEBS hardware sampling interface
│   ├── policy.cpp/.h            # Policy engine: LRU, LFU, Decaying LFU, ML
│   ├── tier_manager.cpp/.h      # NUMA page management, move_pages(), feature tracking
│   ├── cusum.cpp/.h             # Adaptive CUSUM change-point detector
│   ├── ml_weights.h             # Auto-generated model weights (DO NOT EDIT manually)
│   ├── bpf/
│   │   ├── mem_sampler.bpf.c    # eBPF kernel program (PEBS PMU sampling)
│   │   ├── mem_sampler.h        # Shared BPF/userspace structures
│   │   └── vmlinux.h            # Kernel BTF types (auto-generated, git-ignored)
│   └── Makefile
│
├── workload/                    # Workload programs
│   ├── workload.cpp/.h          # Synthetic 6-phase memory stress test
│   ├── stream.c                 # STREAM memory bandwidth benchmark
│   ├── gapbs/                   # GAP Benchmark Suite (BFS, PR, etc.)
│   │   └── src/                 # GAPBS source (compiled via its own Makefile)
│   ├── ycsb/                    # Yahoo Cloud Serving Benchmark (git-ignored, downloaded)
│   └── Makefile
│
├── ml/                          # ML training pipeline (Python)
│   ├── label_and_train_v2.py    # Multi-workload labeling, training, LOWO, weight export
│   ├── label_and_train.py       # Original single-workload training script
│   ├── requirements.txt         # Python dependencies: pandas, scikit-learn, numpy
│   └── traces/                  # Trace CSVs generated by daemon --trace (git-ignored)
│
├── scripts/                     # Automated benchmark runners
│   ├── run_baselines.sh         # Run all policies on the synthetic workload
│   ├── run_gapbs.sh             # Run GAPBS (BFS/PR) with all policies or trace mode
│   ├── run_redis.sh             # Run Redis+YCSB with all policies or trace mode
│   ├── run_stream.sh            # Run STREAM benchmark with all policies
│   ├── sweep_live.sh            # Grid sweep for CUSUM threshold tuning
│   ├── train_ml.sh              # End-to-end: collect traces → train → rebuild
│   └── ycsb_patched.py          # Python 3 patched YCSB runner (auto-injected)
│
├── results/                     # Benchmark outputs (git-ignored)
│   ├── compare_metrics.py       # Parse summary CSVs and print comparison tables
│   ├── gapbs/                   # GAPBS results (per-kernel, per-policy)
│   ├── redis/                   # Redis+YCSB results
│   └── stream/                  # STREAM results
│
└── README.md
```

---

## Prerequisites

### System Requirements

- **Linux** kernel ≥ 5.8 with BTF support (for eBPF CO-RE)
- **NUMA Hardware**: At least **2 NUMA nodes** (physical hardware or emulated via `numactl`). 
  - *Note on Large Workloads:* By default, the fast tier is Node 0 and the slow tier is Node 1. For massive memory workloads (e.g., GAPBS Scale ≥ 24, Redis Scale ≥ 2), the scripts will automatically detect and utilize Node 2 as the slow tier if your system has a 3+ node topology. If Node 2 is not found, they gracefully fall back to Node 1.
- **Root access** (daemon requires eBPF attachment and `move_pages()`)

### Build Dependencies

Install on **Arch Linux**:
```bash
sudo pacman -S base-devel numactl clang llvm bpf libbpf elfutils zlib
```

Install on **Ubuntu/Debian**:
```bash
sudo apt install build-essential libnuma-dev clang llvm libbpf-dev \
    libelf-dev zlib1g-dev bpftool linux-tools-$(uname -r)
```

### Workload Dependencies

| Workload | Requirement |
|----------|-------------|
| Synthetic | None (compiled from source) |
| GAPBS | None (compiled from source, included as submodule) |
| STREAM | `gcc` (compiled from source) |
| Redis + YCSB | `redis-server`, Java JDK ≥ 8, `python3` |

Install Redis and Java on **Arch Linux**:
```bash
sudo pacman -S redis jdk-openjdk
```

Install on **Ubuntu/Debian**:
```bash
sudo apt install redis-server default-jdk
```

### Python Dependencies (for ML training only)

```bash
pip install -r ml/requirements.txt
```

---

## Getting Started

### 1. Clone the Repository

### 2. Build Everything

```bash
# Build the synthetic workload
cd workload && make && cd ..

# Build GAPBS graph benchmarks
cd workload/gapbs && make && cd ../..

# Build the daemon (generates vmlinux.h on first build)
cd daemon && make LOCAL_DEV=1 && cd ..
```

> **Note:** Use `LOCAL_DEV=1` when building on a single-socket laptop/desktop that emulates CXL latency in software. Omit it for real 2-socket NUMA hardware (e.g., CloudLab).

### 3. Download YCSB (for Redis workload only)

```bash
cd workload
curl -O -L https://github.com/brianfrankcooper/YCSB/releases/download/0.17.0/ycsb-0.17.0.tar.gz
tar xzf ycsb-0.17.0.tar.gz
mv ycsb-0.17.0 ycsb
rm ycsb-0.17.0.tar.gz
cd ..
```

The `run_redis.sh` script automatically patches YCSB for Python 3 compatibility at runtime.

### 4. Verify NUMA Topology

```bash
numactl --hardware
# Should show at least 2 nodes
```

---

## Reproducing Results

All benchmark scripts handle building, cache-clearing, environment setup, daemon lifecycle, and result collection automatically. Just run them with `sudo`.

### Synthetic Workload (All Policies)

```bash
sudo ./scripts/run_baselines.sh
python3 results/compare_metrics.py
```

### GAPBS — Graph Analytics

```bash
# Scale 20 for quick local testing, Scale 24–25 for paper-quality results
sudo ./scripts/run_gapbs.sh 20
python3 results/compare_metrics.py gapbs
```

### Redis + YCSB

```bash
# Scale 1 = 1M records (~1GB), Scale 5 = 5M records (~5GB)
sudo ./scripts/run_redis.sh 1
python3 results/compare_metrics.py redis
```

### STREAM

```bash
sudo ./scripts/run_stream.sh
python3 results/compare_metrics.py stream
```

### What Each Script Does

Every `run_*.sh` script performs these steps automatically:
1. Compiles the daemon and workload from source
2. Disables AutoNUMA and Transparent Huge Pages
3. Drops filesystem caches and configures perf sample rates
4. Runs each policy (LRU → LFU → Decaying LFU → ML → AutoNUMA)
5. Saves per-epoch CSV summaries and stderr logs to `results/`
6. Re-enables system defaults on exit

---

## Retraining the Model

If you modify the daemon's feature extraction or want to train on new workloads:

### Step 1: Collect Traces

Run each workload in trace mode with the `random` policy. This outputs per-page, per-epoch feature CSVs to `ml/traces/`:

```bash
# Synthetic trace
sudo ./scripts/run_baselines.sh   # (uses the existing trace pipeline)

# GAPBS traces (BFS + PR)
sudo ./scripts/run_gapbs.sh 20 --trace

# Redis trace
sudo ./scripts/run_redis.sh 1 --trace
```

### Step 2: Train the Model

```bash
cd ml
python3 label_and_train_v2.py
```

This will:
1. Load all traces from `ml/traces/` (BFS, PR, Redis, and any Synthetic trace)
2. Apply K-step lookahead labeling
3. Train a Logistic Regression with balanced class weights
4. Run Leave-One-Workload-Out (LOWO) cross-validation
5. Export new weights to `daemon/ml_weights.h`

### Step 3: Rebuild the Daemon

```bash
cd daemon && make clean && make LOCAL_DEV=1
```

### Automated End-to-End

```bash
sudo ./scripts/train_ml.sh
```

---

## CloudLab Deployment

For paper-quality evaluation on real 2-socket NUMA hardware:

### 1. Provision a CloudLab Node

Request a node with 2 physical NUMA nodes (e.g., `c6525-25g` or `r650` profiles).

### 2. Build Without LOCAL_DEV

```bash
cd daemon && make clean && make   # No LOCAL_DEV flag — real NUMA latencies
```

### 3. Run at Full Scale

```bash
sudo ./scripts/run_gapbs.sh 25          # Scale 25 = ~33M vertices
sudo ./scripts/run_redis.sh 5 --large   # 5M records, large FTC
sudo ./scripts/run_stream.sh
sudo ./scripts/run_baselines.sh
```

### 4. Collect Results

```bash
python3 results/compare_metrics.py
python3 results/compare_metrics.py gapbs
python3 results/compare_metrics.py redis
python3 results/compare_metrics.py stream
```

---

## Tech Stack

| Component | Technology |
|-----------|------------|
| Daemon & Workload | C++17, Linux NUMA API (`libnuma`, `move_pages`, `mbind`) |
| Page Sampling | eBPF (CO-RE) + Intel PEBS via `PERF_COUNT_HW_CPU_CYCLES` PMU |
| Change-Point Detection | Adaptive CUSUM with Welford's online mean/variance |
| ML Training | Python 3, scikit-learn (Logistic Regression), pandas, NumPy |
| ML Deployment | Compile-time weight embedding via auto-generated C++ header |
| Graph Benchmarks | [GAP Benchmark Suite](https://github.com/sbeamer/gapbs) (BFS, PageRank) |
| Database Benchmark | [Redis](https://redis.io/) + [YCSB](https://github.com/brianfrankcooper/YCSB) |
| Memory Bandwidth | [STREAM](https://www.cs.virginia.edu/stream/) |
| Automation | Bash scripts with full lifecycle management |

---

## License

This project was developed as an academic systems research project. See repository for license details.
