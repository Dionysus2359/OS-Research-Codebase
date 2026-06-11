#include "tier_manager.h"
#include "policy.h"
#include "ebpf_sampler.h"
#include "../workload/workload.h"
#include <iostream>
#include <fstream>
#include <string>
#include <unistd.h>
#include <chrono>

#include <sys/types.h>
#include <signal.h>

using namespace std;
using namespace std::chrono;

bool keep_running = true;

void signal_handler(int signum) {
    (void)signum;
    keep_running = false;
}

void print_usage() {
    cerr << "Usage: sudo ./daemon <policy_name> --pid <workload_pid> [--trace]" << endl;
    cerr << "Available policies: lru, lfu, decaying_lfu, ml" << endl;
}

// Reads /tmp/workload_info — written by the local workload process.
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
        
        return (info.total_pages > 0);
    } catch (...) {
        return false;
    }
}

int main(int argc, char* argv[]) {
    if (argc < 4 || string(argv[2]) != "--pid") {
        print_usage();
        return 1;
    }

    string policy_name = argv[1];
    int target_pid = stoi(argv[3]);
    
    bool trace_mode = false;
    if (argc >= 5 && string(argv[4]) == "--trace") {
        trace_mode = true;
    }
    
    Policy* policy = get_policy(policy_name);
    if (!policy) {
        cerr << "Unknown policy: " << policy_name << "\n";
        return 1;
    }

    if (geteuid() != 0) {
        cerr << "ERROR: Daemon must run as root (sudo).\n";
        return 1;
    }

    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // Wait for workload_info (synced from guest by IPC sync script)
    cerr << "[Daemon] Waiting for workload..." << endl;
    WorkloadInfo info;
    while (keep_running) {
        if (read_workload_info(info) && info.current_phase >= 0) break;
        usleep(200000); // 200ms poll
    }
    if (!keep_running) return 0;

    cerr << "[Daemon] Workload detected (guest phase=" << info.current_phase << ")" << endl;

    TierManager mgr(target_pid);
    EbpfSampler sampler(target_pid);
    
    if (!sampler.discover_workload_regions()) {
        cerr << "[Daemon] Failed to discover workload memory regions." << endl;
        return 1;
    }
    if (!sampler.start_recording()) {
        cerr << "[Daemon] Failed to start perf recording." << endl;
        return 1;
    }

    system("echo 0 > /proc/sys/kernel/numa_balancing 2>/dev/null");

    int epoch = 0;
    int last_phase = -1;
    
    cout << "epoch,phase,epoch_accesses,epoch_hits,page_hit_rate,fast_tier_pages,"
         << "tracked_pages,total_migrations,epoch_promotions,epoch_demotions,"
         << "migration_cost_ms,estimated_latency_ns" << endl;

    // Trace file (for ML training data collection)
    ofstream trace_file;
    if (trace_mode) {
        system("mkdir -p /root/results 2>/dev/null");
        string trace_path = "/root/results/trace_" + policy_name + ".csv";
        trace_file.open(trace_path);
        if (trace_file.is_open()) {
            trace_file << "epoch,phase,page_va,current_node,accessed,"
                       << "smooth_frequency,momentum,migration_history,"
                       << "epochs_since_access,hot_ratio,access_frequency_ratio,"
                       << "epoch_density,aci,parse_time_ms\n";
            cerr << "[Daemon] Trace mode ON. Outputting to " << trace_path << endl;
        } else {
            cerr << "[Daemon] WARNING: Cannot open trace file " << trace_path 
                 << ". Trace disabled." << endl;
            trace_mode = false;
        }
    }

    while (keep_running) {
        auto epoch_start = high_resolution_clock::now();

        read_workload_info(info);
        // Only check phase for exit — guest PID doesn't exist on host
        if (info.current_phase < 0) {
            cerr << "[Daemon] Workload finished (phase=-1). Exiting." << endl;
            break;
        }

        if (info.current_phase != last_phase) {
            if (last_phase != -1) {
                cerr << "[Daemon] === Phase transition: " << last_phase 
                     << " -> " << info.current_phase << " ===" << endl;
            }
            last_phase = info.current_phase;
        }

        mgr.epoch_promotions = 0;
        mgr.epoch_demotions = 0;

        sampler.sample_epoch();
        mgr.detect_accesses(sampler);
        mgr.update_page_nodes();
        
        if (mgr.epoch_accesses == 0) {
            epoch++;
            auto epoch_end = high_resolution_clock::now();
            double epoch_ms = duration<double, std::milli>(epoch_end - epoch_start).count();
            if (epoch_ms < 100.0) usleep((int)((100.0 - epoch_ms) * 1000));
            continue;
        }

        // Write per-page trace data for ML training
        if (trace_mode && trace_file.is_open()) {
            auto& meta_map = mgr.get_metadata();
            for (auto& [addr, pm] : meta_map) {
                trace_file << epoch << ","
                           << info.current_phase << ","
                           << "0x" << std::hex << pm.page_va << std::dec << ","
                           << pm.current_node << ","
                           << pm.accessed_this_epoch << ","
                           << pm.smooth_frequency << ","
                           << pm.momentum << ","
                           << pm.migration_history << ","
                           << pm.epochs_since_access << ","
                           << pm.hot_ratio << ","
                           << pm.access_frequency_ratio << ","
                           << mgr.epoch_density << ","
                           << pm.aci << ","
                           << sampler.get_last_parse_duration_ms() << "\n";
            }
            trace_file.flush();
        }

        double page_hit_rate = (double)mgr.epoch_hits / mgr.epoch_accesses;
        long est_latency_ns = (long)mgr.epoch_hits * FAST_LATENCY_NS 
                            + (long)(mgr.epoch_accesses - mgr.epoch_hits) * SLOW_LATENCY_NS;
        
        policy->execute(mgr);
        mgr.update_page_nodes();
        
        cout << epoch << "," 
             << info.current_phase << ","
             << mgr.epoch_accesses << ","
             << mgr.epoch_hits << ","
             << page_hit_rate << ","
             << mgr.get_fast_tier_count() << ","
             << mgr.get_tracked_page_count() << ","
             << mgr.total_migrations << ","
             << mgr.epoch_promotions << ","
             << mgr.epoch_demotions << ","
             << mgr.total_migration_latency_ms << ","
             << est_latency_ns << endl;
        
        cerr << "E" << epoch 
             << " P" << info.current_phase
             << " | Hit: " << (int)(page_hit_rate * 100) << "%"
             << " | Fast: " << mgr.get_fast_tier_count() << "/" << FAST_TIER_CAPACITY
             << " | Tracked: " << mgr.get_tracked_page_count()
             << " | Mig: +" << mgr.epoch_promotions << "/-" << mgr.epoch_demotions
             << " (total=" << mgr.total_migrations << ")"
             << " | Est.Lat: " << est_latency_ns << "ns"
             << " | Cost: " << mgr.total_migration_latency_ms << "ms" << endl;

        epoch++;
        
        auto epoch_end = high_resolution_clock::now();
        double epoch_ms = duration<double, std::milli>(epoch_end - epoch_start).count();
        if (epoch_ms < 100.0) {
            usleep((int)((100.0 - epoch_ms) * 1000));
        } else {
            cerr << "[Daemon] WARNING: Epoch " << epoch 
                 << " took " << epoch_ms << "ms (over budget)" << endl;
        }
    }

    system("echo 1 > /proc/sys/kernel/numa_balancing 2>/dev/null");
    
    delete policy;
    return 0;
}
