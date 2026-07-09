#!/bin/bash
set -e
cleanup_on_exit() {
    echo 25 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null 2>&1
}
trap cleanup_on_exit INT TERM EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "Phase 3: ML Offline Training (Decaying LFU)"
echo "=========================================="

# Force the kernel ceiling up and disable PMU auto-throttling
sudo sysctl -w kernel.perf_event_max_sample_rate=50000 > /dev/null 2>&1 || true
echo 0 | sudo tee /proc/sys/kernel/perf_cpu_time_max_percent > /dev/null || true

echo "[*] Compiling workload and daemon..."
make -C ../workload clean && make -C ../workload
make -C ../daemon clean && make -C ../daemon

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

sudo ../daemon/daemon random --pid $WL_PID --trace --trace-dir ../ml > /dev/null &
DAEMON_PID=$!

wait $WL_PID 2>/dev/null || true
sleep 2
sudo kill $DAEMON_PID 2>/dev/null || true
wait $DAEMON_PID 2>/dev/null || true

echo "[*] Trace collected. Please run label_and_train_v2.py manually."
# Fix permissions since daemon ran as root
REAL_USER=${SUDO_USER:-$USER}
sudo chown $REAL_USER:$REAL_USER ../ml/trace_random.csv 2>/dev/null || true

echo "[*] Recompiling daemon with new weights..."
cd ../daemon
make clean && make

echo 1 | sudo tee /proc/sys/kernel/numa_balancing > /dev/null
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null
echo "[*] Training complete! You can now run ./run_baselines.sh"
