#include "tier_manager.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <fcntl.h>
#include <unistd.h>
#include <numaif.h>
#include <chrono>
#include <cerrno>
#include <cstring>

using namespace std;
using namespace std::chrono;

TierManager::TierManager(int pid, void* base_addr, int total_pages) 
    : target_pid(pid), start_addr(base_addr), num_pages(total_pages), fast_tier_count(0) {
    
    // Initialize metadata — assume all pages start on Node 1
    for (int i = 0; i < num_pages; ++i) {
        void* addr = static_cast<char*>(start_addr) + (i * PAGE_SIZE);
        PageMetadata meta = { addr, 1, 0, 0, 0.0, 0, false, 0.0, 0.0, 0, 0, 0.0, 0.0 };
        pages_meta[addr] = meta;
    }
    
    // Do an initial query to get REAL node placement
    update_page_nodes();
    cerr << "[TierManager] Init: " << num_pages << " pages tracked. "
         << fast_tier_count << " on Node 0, "
         << (num_pages - fast_tier_count) << " on Node 1." << endl;
}

void TierManager::clear_soft_dirty_bits() {
    string clear_refs_path = "/proc/" + to_string(target_pid) + "/clear_refs";
    ofstream clear_refs(clear_refs_path);
    if (clear_refs.is_open()) {
        clear_refs << "4\n"; // 4 = Clear soft-dirty bits
    } else {
        cerr << "[TierManager] WARNING: Cannot write to " << clear_refs_path << endl;
    }
}

void TierManager::read_pagemap_and_update(long current_time) {
    string pagemap_path = "/proc/" + to_string(target_pid) + "/pagemap";
    int fd = open(pagemap_path.c_str(), O_RDONLY);
    if (fd < 0) {
        cerr << "[TierManager] ERROR: Cannot open " << pagemap_path 
             << " (" << strerror(errno) << ")" << endl;
        return;
    }

    epoch_accesses = 0;
    epoch_hits = 0;

    for (int i = 0; i < num_pages; ++i) {
        void* addr = static_cast<char*>(start_addr) + (i * PAGE_SIZE);
        pages_meta[addr].prev_smooth_frequency = pages_meta[addr].smooth_frequency;
    }

    for (int i = 0; i < num_pages; ++i) {
        void* addr = static_cast<char*>(start_addr) + (i * PAGE_SIZE);
        uint64_t vaddr = reinterpret_cast<uint64_t>(addr);
        uint64_t offset = (vaddr / PAGE_SIZE) * sizeof(uint64_t);
        
        uint64_t pagemap_entry;
        if (pread(fd, &pagemap_entry, sizeof(uint64_t), offset) == sizeof(uint64_t)) {
            // Soft-dirty bit is bit 55
            bool accessed = (pagemap_entry >> 55) & 1;
            auto& meta = pages_meta[addr];
            meta.accessed_this_epoch = accessed;

            if (accessed) {
                meta.last_access_time = current_time;
                meta.access_count++;
                meta.smooth_frequency = 0.5 * meta.smooth_frequency + 1.0; //Exponentially Weighted Moving Average (EWMA)
                
                epoch_accesses++;
                if (meta.current_node == 0) epoch_hits++;
                meta.epochs_since_access = 0;
                meta.consecutive_hot_epochs++;
            } else {
                meta.smooth_frequency *= 0.95; // Decay
                meta.epochs_since_access++;
                meta.consecutive_hot_epochs = 0;
            }
            
            meta.momentum = meta.smooth_frequency - meta.prev_smooth_frequency;
        }
    }
    close(fd);

    double freq_sum = 0;
    for (auto& pair : pages_meta) {
        if (pair.second.accessed_this_epoch) {
            freq_sum += pair.second.smooth_frequency;
        }
    }
    double epoch_mean = (epoch_accesses > 0) ? freq_sum / epoch_accesses : 0.0;
    
    for (auto& pair : pages_meta) {
        if (pair.second.accessed_this_epoch && epoch_mean > 1e-10) {
            pair.second.hot_ratio = pair.second.smooth_frequency / epoch_mean;
        } else {
            pair.second.hot_ratio = 0.0;
        }
    }

    double max_sf = 0;
    for (auto& p : pages_meta) max_sf = max(max_sf, p.second.smooth_frequency);
    for (auto& p : pages_meta) {
        p.second.access_frequency_ratio = (max_sf > 1e-10) ? 
            p.second.smooth_frequency / max_sf : 0.0;
    }
}

void TierManager::detect_accesses() {
    auto now = duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
    read_pagemap_and_update(now);
    clear_soft_dirty_bits(); // Reset for next epoch
}

void TierManager::update_page_nodes() {
    // Query actual NUMA node for each page via move_pages(pid, ..., NULL, status, 0)
    vector<void*> addrs(num_pages);
    vector<int> status(num_pages);
    
    for (int i = 0; i < num_pages; ++i) {
        addrs[i] = static_cast<char*>(start_addr) + (i * PAGE_SIZE);
    }
    
    long ret = move_pages(target_pid, num_pages, const_cast<void**>(addrs.data()), NULL, status.data(), 0);
    
    if (ret == 0) {
        fast_tier_count = 0;
        for (int i = 0; i < num_pages; ++i) {
            if (status[i] >= 0) {
                // Valid node number
                pages_meta[addrs[i]].current_node = status[i];
                if (status[i] == 0) fast_tier_count++;
            }
            // Negative status = error for that page (e.g. -EFAULT), keep previous value
        }
    } else {
        cerr << "[TierManager] WARNING: move_pages query failed (ret=" << ret 
             << ", errno=" << errno << ": " << strerror(errno) << ")" << endl;
        // Keep previous fast_tier_count as-is — do NOT reset to 0
    }
}

void TierManager::migrate_pages(const vector<void*>& pages, int target_node) {
    if (pages.empty()) return;

    vector<void*> page_copy(pages.begin(), pages.end());
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
