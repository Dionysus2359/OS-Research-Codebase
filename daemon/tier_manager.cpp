#include "tier_manager.h"
#include <iostream>
#include <fcntl.h>
#include <unistd.h>
#include <numaif.h>
#include <chrono>
#include <cerrno>
#include <cstring>
#include <algorithm>
#include "perf_sampler.h"

using namespace std;
using namespace std::chrono;

TierManager::TierManager(int target_pid) 
    : target_pid(target_pid), fast_tier_count(0) {
    cerr << "[TierManager] Init: tracking Workload PID " << target_pid 
         << ". Pages will be discovered dynamically via PEBS." << endl;
}

void TierManager::detect_accesses(PerfSampler& sampler) {
    auto now = duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
    
    // Save previous smooth_frequency for momentum; reset accessed flag
    for (auto& [page_va, meta] : pages_meta) {
        meta.prev_smooth_frequency = meta.smooth_frequency;
        meta.accessed_this_epoch = false;
    }
    
    epoch_accesses = 0;
    epoch_hits = 0;
    
    // Process PEBS samples — dynamically discover new pages
    for (auto& [page_va, sample] : sampler.get_all_samples()) {
        if (sample.sample_count == 0) continue;
        
        auto it = pages_meta.find(page_va);
        if (it == pages_meta.end()) {
            // First time seeing this page — create metadata
            PageMetadata new_meta = {};
            new_meta.page_va = page_va;
            new_meta.current_node = 1;  // assume slow tier initially
            pages_meta[page_va] = new_meta;
            it = pages_meta.find(page_va);
        }
        
        auto& meta = it->second;
        meta.accessed_this_epoch = true;
        meta.last_access_time = now;
        meta.access_count += sample.sample_count;
        // EWMA uses actual sample count instead of binary 0/1
        meta.smooth_frequency = 0.5 * meta.smooth_frequency + (double)sample.sample_count;
        meta.epochs_since_access = 0;
        meta.consecutive_hot_epochs++;
        meta.avg_latency_cycles = sample.total_latency_cycles / sample.sample_count;


        epoch_accesses += sample.sample_count;
        if (meta.current_node == 0) epoch_hits += sample.sample_count;
    }
    
    // Decay pages NOT accessed this epoch, and compute momentum for ALL pages
    for (auto& [page_va, meta] : pages_meta) {
        if (!meta.accessed_this_epoch) {
            meta.smooth_frequency *= 0.95;
            meta.epochs_since_access++;
            meta.consecutive_hot_epochs = 0;
            // Keep previous avg_latency_cycles (stale but informative)
        }
        meta.momentum = meta.smooth_frequency - meta.prev_smooth_frequency;
    }

    // Recompute hot_ratio
    double freq_sum = 0;
    for (auto& [page_va, meta] : pages_meta) {
        if (meta.accessed_this_epoch) {
            freq_sum += meta.smooth_frequency;
        }
    }
    double epoch_mean = (epoch_accesses > 0) ? freq_sum / epoch_accesses : 0.0;
    
    for (auto& [page_va, meta] : pages_meta) {
        if (meta.accessed_this_epoch && epoch_mean > 1e-10) {
            meta.hot_ratio = meta.smooth_frequency / epoch_mean;
        } else {
            meta.hot_ratio = 0.0;
        }
    }

    // Recompute access_frequency_ratio, epoch_density, and ACI
    double max_sf = 0;
    for (auto& [page_va, meta] : pages_meta) max_sf = max(max_sf, meta.smooth_frequency);
    
    size_t unique_pages_accessed = 0;
    for (auto& [page_va, meta] : pages_meta) {
        meta.access_frequency_ratio = (max_sf > 1e-10) ? 
            meta.smooth_frequency / max_sf : 0.0;
        if (meta.accessed_this_epoch) unique_pages_accessed++;
    }

    epoch_density = (unique_pages_accessed > 0)
        ? (double)epoch_accesses / unique_pages_accessed
        : 1.0;

    constexpr double LATENCY_PENALTY_NS = 400.0 - 80.0; // Slow - Fast tier
    for (auto& [page_va, meta] : pages_meta) {
        meta.aci = meta.smooth_frequency * LATENCY_PENALTY_NS * epoch_density;
    }
}

void TierManager::update_page_nodes() {
    if (pages_meta.empty()) return;
    
    // Query actual NUMA node for each tracked page via move_pages query
    vector<void*> addrs;
    addrs.reserve(pages_meta.size());
    for (auto& [page_va, meta] : pages_meta) {
        addrs.push_back((void*)page_va);
    }
    
    vector<int> status(addrs.size());
    
    long ret = move_pages(target_pid, addrs.size(), 
                          const_cast<void**>(addrs.data()), NULL, status.data(), 0);
    
    if (ret == 0) {
        fast_tier_count = 0;
        int i = 0;
        for (auto& [page_va, meta] : pages_meta) {
            if (status[i] >= 0) {
                meta.current_node = status[i];
                if (status[i] == 0) fast_tier_count++;
            }
            // Negative status = error for that page, keep previous value
            i++;
        }
    } else {
        cerr << "[TierManager] WARNING: move_pages query failed (ret=" << ret 
             << ", errno=" << errno << ": " << strerror(errno) << ")" << endl;
        // Keep previous fast_tier_count as-is
    }
}

void TierManager::migrate_pages(const vector<uintptr_t>& pages, int target_node) {
    if (pages.empty()) return;

    vector<void*> page_copy;
    page_copy.reserve(pages.size());
    for (auto va : pages) page_copy.push_back((void*)va);
    vector<int> nodes(pages.size(), target_node);
    vector<int> status(pages.size());

    auto start = high_resolution_clock::now();
    
    long result = move_pages(target_pid, page_copy.size(), page_copy.data(), nodes.data(), status.data(), MPOL_MF_MOVE);
    
    auto end = high_resolution_clock::now();
    double latency = duration_cast<microseconds>(end - start).count() / 1000.0;

    // Count only pages that actually succeeded
    int succeeded = 0;
    for (size_t i = 0; i < pages.size(); ++i) {
        if (status[i] == target_node || status[i] >= 0) {
            pages_meta[pages[i]].current_node = target_node;
            pages_meta[pages[i]].migration_history++;
            succeeded++;
        }
    }
    
    if (succeeded > 0) {
        total_migrations += succeeded;
        total_migration_latency_ms += latency;
        if (target_node == 0) epoch_promotions += succeeded;
        else epoch_demotions += succeeded;
    }
    
    if (result != 0) {
        cerr << "[TierManager] migrate_pages partial failure: " << succeeded 
             << "/" << pages.size() << " succeeded" << endl;
    }
}

int TierManager::get_node(uintptr_t page_va) const {
    auto it = pages_meta.find(page_va);
    if (it != pages_meta.end()) return it->second.current_node;
    return -1;
}
