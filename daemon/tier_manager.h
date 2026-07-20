#ifndef TIER_MANAGER_H
#define TIER_MANAGER_H

#include <vector>
#include <map>
#include <cstdint>
#include <string>

#include "../workload/workload.h"

extern int MAX_PROMOTIONS_PER_EPOCH;
extern int MAX_DEMOTIONS_PER_EPOCH;

extern int SLOW_NODE;

struct PageMetadata {
    uintptr_t page_va;           // Page-aligned virtual address in workload
    int current_node;            // 0 = Fast, 1 = Slow
    long last_access_time;
    int access_count;
    double smooth_frequency;
    int migration_history;
    bool accessed_this_epoch;
    
    // --- ML features ---
    double prev_smooth_frequency;
    double momentum;
    int epochs_since_access;
    int consecutive_hot_epochs;
    double hot_ratio;
    double access_frequency_ratio;
    double avg_latency_cycles;     // AOL proxy: avg PEBS weight for this page
    double aci;                    // Access Criticality Index
};

class TierManager {
public:
    TierManager(int target_pid);
    
    void detect_accesses(class EbpfSampler& sampler);
    void update_page_nodes();
    void calculate_misplaced_pages();
    void migrate_pages(const std::vector<uintptr_t>& pages, int target_node);
    
    std::map<uintptr_t, PageMetadata>& get_metadata() { return pages_meta; }
    int get_node(uintptr_t page_va) const;
    int get_fast_tier_count() const { return fast_tier_count; }
    int get_tracked_page_count() const { return (int)pages_meta.size(); }
    
    // Per-epoch metrics
    long total_migrations = 0;
    double total_migration_latency_ms = 0;
    int epoch_accesses = 0;
    int epoch_hits = 0;
    int epoch_misplaced_pages = 0;

    // Per-epoch migration counters (reset by daemon each epoch)
    int epoch_promotions = 0;
    int epoch_demotions = 0;
    double epoch_density = 1.0;

private:
    int target_pid;
    int fast_tier_count;
    
    std::map<uintptr_t, PageMetadata> pages_meta;
};

#endif
