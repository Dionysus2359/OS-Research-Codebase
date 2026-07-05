## ML-Assisted Memory Tiering for CXL Systems

An intelligent, eBPF-driven memory page placement daemon for heterogeneous DRAM/CXL memory systems. The daemon monitors page-level access patterns in real time via hardware performance counters (Intel PEBS) and uses a trained logistic regression model with CUSUM change-point detection to decide which pages belong in fast DRAM and which can safely reside in slower CXL-attached memory.

We evaluate our approach against **5 baselines** — LRU, LFU, Decaying LFU, AutoNUMA, and the state-of-the-art Kleio/Coeus hybrid schedulers — across **4 diverse workloads** (Synthetic, Graph Analytics, Streaming, and Database) using both a **trace-driven simulator** (adapted from the open-source [Coeus](https://github.com/GTkernel/coeus-sim) codebase) and a **real Linux daemon** on NUMA hardware.

## Table of Contents

- [Motivation](#motivation)
- [Architecture](#architecture)
- [Workloads](#workloads)
- [ML Pipeline](#ml-pipeline)
- [CUSUM Change-Point Detection](#cusum-change-point-detection)
- [Evaluation Metrics](#evaluation-metrics)
- [Simulator](#simulator)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Getting Started](#getting-started)
- [Reproducing Results](#reproducing-results)
- [Retraining the Model](#retraining-the-model)
- [CloudLab Deployment](#cloudlab-deployment)
- [References](#references)
- [License](#license)

---

## Motivation

Modern data centers increasingly pair fast, expensive DRAM with slower, high-capacity CXL-attached memory. The operating system must decide which memory pages belong in each tier. The Linux kernel's default page placement (AutoNUMA) reacts to page faults but lacks predictive intelligence, leading to excessive migrations and latency spikes.

This project explores whether a lightweight ML model — trained offline on historical page-access traces collected via eBPF/PEBS — can make smarter promote/demote decisions than traditional heuristics (LRU, LFU, Decaying LFU) while minimizing costly `move_pages()` syscalls.

---

## Architecture

The system is composed of four cooperating subsystems:

```
┌──────────────────────┐
│     Workloads         │
│  ┌────────────────┐  │       ┌─────────────────────────────────┐
│  │ Synthetic      │  │       │     ML Tiering Daemon            │
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
                               └───────────┬───────────────┘
                                           │
                               ┌───────────▼───────────────┐
                               │   Trace-Driven Simulator   │
                               │   (Python / Coeus/Kleio)  │
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
   - **ML policy**: applies `sigmoid(w · x + b)` using pre-trained, StandardScaler-normalized weights compiled into [`ml_weights.h`](daemon/ml_weights.h)
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

The training script ([`label_and_train_v2.py`](ml/label_and_train_v2.py)) uses **K-step lookahead labeling**:
- For each page at epoch *t*, look ahead *K=10* epochs
- If the page is accessed in ≥ 4 of the next 10 epochs → label **HOT** (promote)
- Otherwise → label **COLD** (demote)

This forward-looking labeling teaches the model to predict *future* hotness rather than react to past counts.

### Model

- **Algorithm**: Logistic Regression with `class_weight='balanced'`
- **Normalization**: StandardScaler (mean/std embedded into the C++ header)
- **Deployment**: Weights, bias, scaler parameters are exported as `constexpr` arrays in [`ml_weights.h`](daemon/ml_weights.h) — **zero runtime dependency on Python**
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

The tuned parameters (`ABS_THRESHOLD=0.30`, `DEMOTE_MARGIN=0.40`) were found via grid sweep ([`sweep_live.sh`](scripts/sweep_live.sh)).

---

## Evaluation Metrics

Both the real daemon and the trace-driven simulator report the following metrics:

| Metric | Description |
|--------|-------------|
| **Hit Ratio (%)** | Fraction of total memory accesses served from the fast tier (DRAM / Node 0) |
| **Misplaced (%)** | Normalized misplacement rate: `(Total Misplaced Epochs) / (Total Epochs × Fast Tier Capacity) × 100`. Measures the fraction of fast-tier slots occupied by cold pages across all epochs. Lower is better. |
| **Avg Latency (ns)** | Estimated average memory access latency, weighted by hit/miss ratio and platform parameters |
| **Total Migrations** | Total number of page migrations (promotions + demotions) across the entire run |
| **Migration Cost (ms)** | Cumulative time spent in `move_pages()` syscalls |
| **Slowdown (%)** | Simulated runtime slowdown compared to an all-fast-memory baseline (simulator only) |

### Misplacement Rate

The **Misplaced (%)** metric is the primary accuracy indicator. It is computed identically for all policies (LRU, LFU, ML, Kleio, Coeus) to ensure apples-to-apples comparison:

1. At the end of each epoch, the **Oracle** identifies the ideal set of hot pages (top-K pages by actual access count)
2. Any page in the Oracle's ideal set that the policy left in the slow tier counts as one misplacement event
3. The total misplacement events are divided by `(Total Epochs × Fast Tier Capacity)` to produce a normalized percentage

This normalization is critical because different policies (e.g., Kleio vs ML) may operate with different epoch durations, making raw counts incomparable.

---

## Simulator

The `simulator/` directory contains a Python-based trace-driven memory tiering simulator, cloned from the open-source [Coeus/Kleio simulator](https://github.com/GTkernel/coeus-sim) by Doudali et al. We adapted it to support Python 3, added our own policies (LRU, LFU, Decaying LFU, ML), and implemented a normalized misplacement metric for apples-to-apples comparison against the original Kleio and Coeus hybrid schedulers.

The simulator replays Intel Pin memory traces from 9 real-world applications (PARSEC, Rodinia, CORAL) and evaluates all policies under configurable DRAM/NVM capacity ratios.

### Policies Evaluated

| Policy | Type | Description |
|--------|------|-------------|
| **Oracle** | Upper Bound | Perfect future knowledge — places the truly hottest pages every epoch |
| **History** | Heuristic | Previous-epoch access counts as predictor (original Cori baseline) |
| **LRU** | Classical | Least Recently Used eviction |
| **LFU** | Classical | Least Frequently Used eviction |
| **Decaying LFU** | Classical | LFU with exponential decay to adapt to recency |
| **ML** | Learned | Our logistic regression model using the same 6 features as the daemon |
| **Kleio Hybrid** | State-of-art | LSTM-based predictor from Kleio (Doudali et al., HPDC 2019) |
| **Coeus Hybrid** | State-of-art | Page clustering mechanism from Coeus (Doudali et al., CCGrid 2022) |

### Running the Simulator

```bash
cd simulator

# Run all policies across all 9 apps with capacity sweeps
python3 run_gauntlet.py

# Parse results into comparative markdown tables
python3 parse_results.py
```

Output includes Hitrate, Runtime, Overhead, Migrations, Slowdown, and normalized Misplaced(%) for every policy × app × capacity ratio combination.

### Simulator Traces

The `simulator/traces/pin_traces/` directory contains Intel Pin memory access traces (~97MB total) for 9 applications from the PARSEC, Rodinia, and CORAL benchmark suites. These are the same traces used in the original Coeus/Kleio papers.

---

## Repository Structure

```
project/
├── daemon/                      # Core monitoring daemon (C++17)
│   ├── daemon.cpp               # Main loop: attach → sample → decide → migrate
│   ├── ebpf_sampler.cpp/.h      # eBPF/PEBS hardware sampling interface
│   ├── policy.cpp/.h            # Policy engine: LRU, LFU, Decaying LFU, ML, Random
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
│   └── ycsb/                    # Yahoo Cloud Serving Benchmark (git-ignored, downloaded)
│
├── ml/                          # ML training pipeline (Python)
│   ├── label_and_train_v2.py    # Multi-workload labeling, training, LOWO, weight export
│   ├── label_and_train.py       # Original single-workload training script
│   ├── requirements.txt         # Python dependencies: pandas, scikit-learn, numpy
│   └── traces/                  # Trace CSVs generated by daemon --trace (git-ignored)
│
├── scripts/                     # Automated benchmark runners & analysis
│   ├── run_baselines.sh         # Run all policies on the synthetic workload
│   ├── run_gapbs.sh             # Run GAPBS (BFS/PR) with all policies or trace mode
│   ├── run_redis.sh             # Run Redis+YCSB with all policies or trace mode
│   ├── run_stream.sh            # Run STREAM benchmark with all policies
│   ├── compare_metrics.py       # Parse daemon summary CSVs → comparison tables
│   ├── sweep_live.sh            # Grid sweep for CUSUM threshold tuning
│   ├── train_ml.sh              # End-to-end: collect traces → train → rebuild
│   └── ycsb_patched.py          # Python 3 patched YCSB runner (auto-injected)
│
├── simulator/                   # Trace-driven simulator (adapted from Coeus/Kleio)
│   ├── sim/                     # Core simulator engine (modified)
│   │   ├── scheduler.py         # Epoch-based scheduler with misplacement tracking
│   │   ├── memory.py            # Tiered memory model (added LRU, LFU, Decaying LFU, ML)
│   │   ├── perf_model.py        # Performance model and metrics computation
│   │   ├── profile.py           # Trace profile loader
│   │   └── traffic.py           # Memory traffic generator from traces
│   ├── kleio/                   # Original Kleio/Coeus hybrid scheduler (from authors)
│   │   ├── page_selector.py     # Page clustering and hybrid scheduling logic
│   │   └── lstm.py              # LSTM-based page access predictor (Kleio)
│   ├── run_gauntlet.py          # Our runner: all policies across all 9 apps + sweeps
│   ├── run_across_apps.py       # Original Kleio runner (from authors)
│   ├── run_cluster.py           # Original Coeus clustering analysis (from authors)
│   ├── parse_results.py         # Parse simulator CSVs → comparative markdown tables
│   ├── retrain_coeus.py         # Retrain Coeus features on new traces
│   ├── extract_coeus_features.py # Extract clustering features from traces
│   ├── sweep_margins.py         # Sweep ML margins in simulator
│   ├── ml_weights.h             # Simulator copy of ML weights for the ML policy
│   └── traces/
│       ├── pin_traces/          # Intel Pin memory traces for 9 apps (~97MB)
│       ├── memtrace.cpp         # Pin tool source for generating new traces
│       └── README.md            # Trace format documentation
│
├── results/                     # Daemon benchmark outputs (git-ignored, reproducible)
│
├── .gitignore
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

### Python Dependencies

For **ML training** and **simulator**:
```bash
pip install pandas scikit-learn numpy
```

---

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/Dionysus2359/OS-Research-Codebase.git
cd OS-Research-Codebase
```

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

### Daemon Evaluation (Real Hardware)

#### Synthetic Workload

```bash
sudo ./scripts/run_baselines.sh
python3 scripts/compare_metrics.py
```

#### GAPBS — Graph Analytics

```bash
# Scale 20 for quick local testing, Scale 24–25 for paper-quality results
sudo ./scripts/run_gapbs.sh 20
python3 scripts/compare_metrics.py results/gapbs
```

#### Redis + YCSB

```bash
# Scale 1 = 1M records (~1GB), Scale 5 = 5M records (~5GB)
sudo ./scripts/run_redis.sh 1
python3 scripts/compare_metrics.py results/redis
```

#### STREAM

```bash
sudo ./scripts/run_stream.sh
python3 scripts/compare_metrics.py results/stream
```

### Simulator Evaluation (Trace-Driven)

```bash
cd simulator

# Run all 8 policies across 9 apps with capacity sweeps (uses multiprocessing)
python3 run_gauntlet.py

# Parse and display results
python3 parse_results.py
```

### What Each `run_*.sh` Script Does

Every benchmark script performs these steps automatically:
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
python3 scripts/compare_metrics.py
python3 scripts/compare_metrics.py results/gapbs
python3 scripts/compare_metrics.py results/redis
python3 scripts/compare_metrics.py results/stream
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
| Simulator | Adapted from [Coeus/Kleio](https://github.com/GTkernel/coeus-sim) (Python, modified for Python 3 + our policies) |
| Graph Benchmarks | [GAP Benchmark Suite](https://github.com/sbeamer/gapbs) (BFS, PageRank) |
| Database Benchmark | [Redis](https://redis.io/) + [YCSB](https://github.com/brianfrankcooper/YCSB) |
| Memory Bandwidth | [STREAM](https://www.cs.virginia.edu/stream/) |
| Automation | Bash scripts with full lifecycle management |

---

## References

The trace-driven simulator in `simulator/` is adapted from the open-source code accompanying the following papers:

- **Coeus: Clustering (A)like Patterns for Practical Machine Intelligent Hybrid Memory Management.**
  Thaleia Dimitra Doudali, Ada Gavrilovska.
  *IEEE/ACM CCGrid 2022.* [[Code]](https://github.com/GTkernel/coeus-sim)

- **Cori: Dancing to the Right Beat of Periodic Data Movements over Hybrid Memory Systems.**
  Thaleia Dimitra Doudali, Daniel Zahka, Ada Gavrilovska.
  *IEEE IPDPS 2021.*

- **Kleio: a Hybrid Memory Page Scheduler with Machine Intelligence.**
  Thaleia Dimitra Doudali, Sergey Blagodurov, Abhinav Vishnu, Sudhanva Gurumurthi, Ada Gavrilovska.
  *ACM HPDC 2019.*

---

## License

This project was developed as an academic systems research project. See repository for license details.
