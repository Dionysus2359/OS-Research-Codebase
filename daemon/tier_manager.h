#ifndef TIER_MANAGER_H
#define TIER_MANAGER_H

#include <vector>
#include <map>
#include <cstdint>
#include <string>

#include "../workload/workload.h"
constexpr int MIGRATION_BATCH_SIZE = 32;

struct PageMetadata {
    void* addr;
    int current_node;        // 0 = Fast, 1 = Slow
    long last_access_time;
    int access_count;
    double smooth_frequency;
    int migration_history;
    bool accessed_this_epoch;
    
    // --- NEW for ML ---
    double prev_smooth_frequency;  // Previous epoch's smooth_frequency
    double momentum;               // smooth_frequency delta between epochs
    int epochs_since_access;       // Consecutive epochs without access
    int consecutive_hot_epochs;    // Consecutive epochs accessed
    double hot_ratio;              // page smooth_freq / epoch mean smooth_freq
    double access_frequency_ratio; // page smooth_freq / max(smooth_freq of all pages)
};

class TierManager {
public:
    TierManager(int pid, void* base_addr, int total_pages);
    
    void detect_accesses();
    void update_page_nodes();
    void migrate_pages(const std::vector<void*>& pages, int target_node);
    void clear_soft_dirty_bits();
    
    std::map<void*, PageMetadata>& get_metadata() { return pages_meta; }
    int get_fast_tier_count() const { return fast_tier_count; }
    
    // Per-epoch metrics (reset each detect_accesses() call)
    long total_migrations = 0;
    double total_migration_latency_ms = 0;
    int epoch_accesses = 0;     // Pages with soft-dirty bit set this epoch
    int epoch_hits = 0;         // Of those, how many were on Node 0

    // Per-epoch migration counters (reset by daemon each epoch)
    int epoch_promotions = 0;
    int epoch_demotions = 0;

private:
    int target_pid;
    void* start_addr;
    int num_pages;
    int fast_tier_count;
    
    std::map<void*, PageMetadata> pages_meta;
    void read_pagemap_and_update(long current_time);
};

#endif
