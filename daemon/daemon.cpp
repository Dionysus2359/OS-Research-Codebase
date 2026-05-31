#include "tier_manager.h"
#include "policy.h"
#include "../workload/workload.h"
#include <iostream>
#include <fstream>
#include <string>
#include <unistd.h>
#include <csignal>
#include <sys/types.h>
#include <signal.h>

using namespace std;

bool keep_running = true;

void signal_handler(int signum) {
    (void)signum;
    keep_running = false;
}

bool read_workload_info(WorkloadInfo& info) {
    try {
        ifstream infile(WORKLOAD_INFO_PATH);
        if (!infile.is_open()) return false;
        
        infile >> info.pid;
        string addr_str;
        infile >> addr_str;
        if (addr_str.empty()) return false;
        info.base_address = (void*)stoull(addr_str, nullptr, 16);
        infile >> info.total_pages;
        infile >> info.current_phase;
        
        return (info.pid > 0 && info.total_pages > 0);
    } catch (...) {
        // File was partially written during a phase transition — retry next cycle
        return false;
    }
}

int main(int argc, char** argv) {
    if (argc < 2) {
        cerr << "Usage: sudo ./daemon <policy> (lru|lfu|decaying_lfu)\n";
        return 1;
    }
    
    string policy_name = argv[1];
    bool trace_mode = false;
    if (argc >= 3 && string(argv[2]) == "--trace") {
        trace_mode = true;
    }
    Policy* policy = get_policy(policy_name);
    if (!policy) {
        cerr << "Unknown policy: " << policy_name << "\n";
        return 1;
    }

    if (geteuid() != 0) {
        cerr << "ERROR: Daemon must run as root (sudo) for /proc/pid/pagemap access.\n";
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // === Wait for workload to start ===
    cerr << "[Daemon] Waiting for workload..." << endl;
    WorkloadInfo info;
    while (keep_running) {
        if (read_workload_info(info) && info.current_phase >= 0) break;
        usleep(200000); // 200ms poll
    }
    if (!keep_running) return 0;

    cerr << "[Daemon] Attached to PID " << info.pid 
         << " | Policy: " << policy_name 
         << " | Pages: " << info.total_pages << endl;

    // Disable AutoNUMA so only OUR policy controls migrations
    system("echo 0 > /proc/sys/kernel/numa_balancing 2>/dev/null");
    
    TierManager mgr(info.pid, info.base_address, info.total_pages);
    mgr.clear_soft_dirty_bits(); // Initialize — clear stale bits

    int epoch = 0;
    int last_phase = -1;
    
    // Print CSV header to stdout (daemon results are stdout, diagnostics are stderr)
    cout << "epoch,phase,epoch_accesses,epoch_hits,page_hit_rate,fast_tier_pages,"
         << "total_migrations,epoch_promotions,epoch_demotions,"
         << "migration_cost_ms,estimated_latency_ns" << endl;

    ofstream trace_file;
    if (trace_mode) {
        string trace_path = "/root/results/trace_" + policy_name + ".csv";
        trace_file.open(trace_path);
        if (trace_file.is_open()) {
            trace_file << "epoch,phase,page_idx,current_node,accessed,access_count,smooth_frequency,momentum,migration_history,epochs_since_access,hot_ratio,access_frequency_ratio\n";
            cerr << "[Daemon] Trace mode ON. Outputting to " << trace_path << endl;
        } else {
            cerr << "[Daemon] WARNING: Cannot open trace file " << trace_path << ". Trace disabled." << endl;
            trace_mode = false;
        }
    }

    while (keep_running) {
        // Check if workload is still alive
        read_workload_info(info);
        if (info.current_phase < 0 || kill(info.pid, 0) != 0) {
            cerr << "[Daemon] Workload finished. Exiting." << endl;
            break;
        }

        // Detect phase transitions
        if (info.current_phase != last_phase) {
            if (last_phase != -1) {
                cerr << "[Daemon] === Phase transition: " << last_phase 
                     << " -> " << info.current_phase << " ===" << endl;
            }
            last_phase = info.current_phase;
        }

        // Reset per-epoch counters
        mgr.epoch_promotions = 0;
        mgr.epoch_demotions = 0;

        // === Core daemon cycle ===
        // 1. Sample: read soft-dirty bits to detect which pages were accessed
        mgr.detect_accesses();
        
        // 2. Query: get actual NUMA node for each page (PRE-migration snapshot)
        mgr.update_page_nodes();
        
        // Skip logging and policy if no accesses detected
        if (mgr.epoch_accesses == 0) {
            usleep(100000);
            epoch++;
            continue;
        }

        if (trace_mode && trace_file.is_open()) {
            int page_idx = 0;
            for (auto& pair : mgr.get_metadata()) {
                auto& pm = pair.second;
                trace_file << epoch << ","
                           << info.current_phase << ","
                           << page_idx++ << ","
                           << pm.current_node << ","
                           << pm.accessed_this_epoch << ","
                           << pm.access_count << ","
                           << pm.smooth_frequency << ","
                           << pm.momentum << ","
                           << pm.migration_history << ","
                           << pm.epochs_since_access << ","
                           << pm.hot_ratio << ","
                           << pm.access_frequency_ratio << "\n";
            }
        }

        // 3. Compute PRE-migration metrics
        double page_hit_rate = (double)mgr.epoch_hits / mgr.epoch_accesses;
        long est_latency_ns = (long)mgr.epoch_hits * FAST_LATENCY_NS 
                            + (long)(mgr.epoch_accesses - mgr.epoch_hits) * SLOW_LATENCY_NS;
        
        // 4. Decide + Migrate: run the active policy
        policy->execute(mgr);
        
        // 5. Re-query node placement after migrations (for next epoch's state tracking)
        mgr.update_page_nodes();
        
        // 6. Output CSV row (stdout)
        cout << epoch << "," 
             << info.current_phase << ","
             << mgr.epoch_accesses << ","
             << mgr.epoch_hits << ","
             << page_hit_rate << ","
             << mgr.get_fast_tier_count() << ","
             << mgr.total_migrations << ","
             << mgr.epoch_promotions << ","
             << mgr.epoch_demotions << ","
             << mgr.total_migration_latency_ms << ","
             << est_latency_ns << endl;
        
        // Human-readable summary to stderr
        cerr << "E" << epoch 
             << " P" << info.current_phase
             << " | Hit: " << (int)(page_hit_rate * 100) << "%"
             << " | Fast: " << mgr.get_fast_tier_count() << "/" << FAST_TIER_CAPACITY
             << " | Mig: +" << mgr.epoch_promotions << "/-" << mgr.epoch_demotions
             << " (total=" << mgr.total_migrations << ")"
             << " | Est.Lat: " << est_latency_ns << "ns"
             << " | Cost: " << mgr.total_migration_latency_ms << "ms" << endl;

        epoch++;
        usleep(100000); // 100ms cycle
    }

    // Re-enable AutoNUMA on exit
    system("echo 1 > /proc/sys/kernel/numa_balancing 2>/dev/null");
    
    delete policy;
    return 0;
}
