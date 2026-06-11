#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Phase 3: ML Offline Training (Decaying LFU)"
echo "=========================================="

# Force the kernel ceiling up before the run to prevent PMU auto-throttling
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1

echo "[*] Compiling workload and daemon..."
make -C ../workload clean && make -C ../workload
make -C ../daemon clean && make -C ../daemon LOCAL_DEV=1

echo "[*] Starting workload for trace collection..."
echo 0 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
numactl --membind=1 --cpubind=0 ../workload/workload &
WL_PID=$!

echo "[*] Starting daemon in trace mode..."
for i in $(seq 1 20); do
    [ -f /tmp/workload_info ] && break
    sleep 0.25
done

sudo ../daemon/daemon decaying_lfu --pid $WL_PID --trace > /dev/null &
DAEMON_PID=$!

wait $WL_PID 2>/dev/null || true
sleep 2
sudo kill $DAEMON_PID 2>/dev/null || true
wait $DAEMON_PID 2>/dev/null || true

echo "[*] Trace collected. Training ML Model..."
sudo cp /root/results/trace_decaying_lfu.csv ../ml/trace_decaying_lfu.csv
sudo chown $(whoami):$(whoami) ../ml/trace_decaying_lfu.csv
cd ../ml
python label_and_train.py

echo "[*] Recompiling daemon with new weights..."
cd ../daemon
make clean && make LOCAL_DEV=1

echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
echo "[*] Training complete! You can now run ./run_baselines.sh"
