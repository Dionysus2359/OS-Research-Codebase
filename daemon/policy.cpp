#include "policy.h"
#include <vector>
#include <algorithm>
#include <iostream>
#include <cmath>
#include "ml_weights.h"

using namespace std;

// Core promote/demote logic shared by all baseline policies.
// 'comp' defines the policy: comp(a, b) = true means 'a' is hotter than 'b'.
template<typename Compare>
void promote_and_demote(TierManager& mgr, Compare comp) {
    auto& meta = mgr.get_metadata();
    vector<PageMetadata*> fast_pages;
    vector<PageMetadata*> slow_hot_pages;  // Only slow pages accessed this epoch
    
    for (auto& pair : meta) {
        if (pair.second.current_node == 0) {
            fast_pages.push_back(&pair.second);
        } else if (pair.second.accessed_this_epoch) {
            // Only consider slow-tier pages that were ACTUALLY accessed this epoch
            slow_hot_pages.push_back(&pair.second);
        }
    }
    
    // Nothing to promote? Skip entirely.
    if (slow_hot_pages.empty()) return;
    
    // Sort slow hot pages descending by policy metric (hottest first)
    sort(slow_hot_pages.begin(), slow_hot_pages.end(), comp);
    
    // Sort fast pages ascending by policy metric (coldest first — eviction candidates)
    sort(fast_pages.begin(), fast_pages.end(), [&](PageMetadata* a, PageMetadata* b) { 
        return comp(b, a); 
    });
    
    vector<void*> to_promote;
    vector<void*> to_demote;
    
    int free_fast_slots = FAST_TIER_CAPACITY - mgr.get_fast_tier_count();
    
    size_t demote_idx = 0;
    for (size_t i = 0; i < slow_hot_pages.size() && (int)to_promote.size() < MIGRATION_BATCH_SIZE; ++i) {
        PageMetadata* candidate = slow_hot_pages[i];
        
        if (free_fast_slots > 0) {
            // Fast tier has room — promote directly
            to_promote.push_back(candidate->addr);
            free_fast_slots--;
        } else {
            // Fast tier is FULL — only swap if candidate is hotter than coldest fast page
            if (demote_idx < fast_pages.size()) {
                PageMetadata* victim = fast_pages[demote_idx];
                
                if (comp(candidate, victim)) {
                    // Candidate IS hotter than the coldest fast page — swap them
                    to_demote.push_back(victim->addr);
                    to_promote.push_back(candidate->addr);
                    demote_idx++;
                } else {
                    // Candidate is NOT hotter — since list is sorted, no remaining 
                    // candidates will be hotter either. Stop.
                    break;
                }
            } else {
                break; // No more victims available
            }
        }
    }
    
    // Execute: demote first (make room), then promote
    mgr.migrate_pages(to_demote, 1);
    mgr.migrate_pages(to_promote, 0);
}

// ===== LRU: Promote most-recently-accessed, evict least-recently-accessed =====
// Tiebreaker: when timestamps collide (same epoch), use access_count
void LRUPolicy::execute(TierManager& mgr) {
    promote_and_demote(mgr, [](PageMetadata* a, PageMetadata* b) {
        if (a->last_access_time != b->last_access_time)
            return a->last_access_time > b->last_access_time;
        return a->access_count > b->access_count; // tiebreaker
    });
}

// ===== LFU: Promote most-frequently-accessed, evict least-frequently-accessed =====
// Tiebreaker: when counts are equal, prefer more recently accessed
void LFUPolicy::execute(TierManager& mgr) {
    promote_and_demote(mgr, [](PageMetadata* a, PageMetadata* b) {
        if (a->access_count != b->access_count)
            return a->access_count > b->access_count;
        return a->last_access_time > b->last_access_time; // tiebreaker
    });
}

// ===== Decaying LFU: Promote highest smooth_frequency, evict lowest =====
// Tiebreaker: when frequencies are very close, prefer higher raw count
void DecayingLFUPolicy::execute(TierManager& mgr) {
    promote_and_demote(mgr, [](PageMetadata* a, PageMetadata* b) {
        double diff = a->smooth_frequency - b->smooth_frequency;
        if (diff > 0.001 || diff < -0.001)
            return a->smooth_frequency > b->smooth_frequency;
        return a->access_count > b->access_count; // tiebreaker
    });
}

// ===== MLPolicy: Score pages using Logistic Regression =====
double MLPolicy::score_page(const PageMetadata& meta) const {
    // Feature order MUST match FEATURE_COLS in label_and_train.py
    // and the comment in ml_weights.h
    double features[] = {
        meta.smooth_frequency,            // index 0
        (double)meta.access_count,        // index 1
        meta.momentum,                    // index 2
        (double)meta.migration_history,   // index 3
        (double)meta.epochs_since_access, // index 4
        meta.hot_ratio,                   // index 5
        meta.access_frequency_ratio       // index 6
    };
    
    double dot = ML_BIAS;
    for (int i = 0; i < ML_NUM_FEATURES; i++) {
        double normalized = 0.0;
        if (ML_SCALER_STD[i] > 1e-10) {  // guard against zero/near-zero std
            normalized = (features[i] - ML_SCALER_MEAN[i]) / ML_SCALER_STD[i];
        }
        // If std ≈ 0, normalized stays 0.0 → this feature contributes nothing
        dot += ML_WEIGHTS[i] * normalized;
    }
    
    return 1.0 / (1.0 + exp(-dot));  // sigmoid → probability in [0, 1]
}

void MLPolicy::execute(TierManager& mgr) {
    auto& meta = mgr.get_metadata();
    
    struct ScoredPage { void* addr; double score; };
    vector<ScoredPage> slow_candidates;
    vector<ScoredPage> fast_pages;
    
    for (auto& pair : meta) {
        auto& pm = pair.second;
        double s = score_page(pm);
        if (pm.current_node == 1 && pm.accessed_this_epoch) {
            slow_candidates.push_back({pm.addr, s});
        } else if (pm.current_node == 0) {
            fast_pages.push_back({pm.addr, s});
        }
    }
    
    // Slow candidates descending by score (hottest first for promotion)
    sort(slow_candidates.begin(), slow_candidates.end(),
         [](const ScoredPage& a, const ScoredPage& b) { return a.score > b.score; });
    
    // Fast pages ascending by score (coldest first for demotion/victim selection)
    sort(fast_pages.begin(), fast_pages.end(),
         [](const ScoredPage& a, const ScoredPage& b) { return a.score < b.score; });
    
    vector<void*> to_promote;
    vector<void*> to_demote;
    
    int free_fast_slots = FAST_TIER_CAPACITY - mgr.get_fast_tier_count();
    size_t demote_idx = 0;
    
    // Score margin: only swap if the candidate is meaningfully hotter
    // than the victim. Prevents churn when all pages have similar scores
    // (analogous to DLFU's 0.001 smooth_frequency tolerance band).
    const double PROMOTE_MARGIN = 0.01;   // for eviction swaps
    const double DEMOTE_MARGIN  = 0.05;   // victim must be clearly worse

    for (size_t i = 0; i < slow_candidates.size()
         && (int)to_promote.size() < MIGRATION_BATCH_SIZE;  // batch cap
         ++i) {
        
        if (free_fast_slots > 0) {
            to_promote.push_back(slow_candidates[i].addr);
            free_fast_slots--;
        } else if (demote_idx < fast_pages.size()) {
            if (slow_candidates[i].score > fast_pages[demote_idx].score + PROMOTE_MARGIN &&
                fast_pages[demote_idx].score < slow_candidates[i].score - DEMOTE_MARGIN) {
                to_demote.push_back(fast_pages[demote_idx].addr);
                to_promote.push_back(slow_candidates[i].addr);
                demote_idx++;
            } else {
                break;  // sorted — no remaining candidates beat remaining victims
            }
        } else {
            break;
        }
    }
    
    mgr.migrate_pages(to_demote, 1);  // demote first (make room)
    mgr.migrate_pages(to_promote, 0); // then promote
}

Policy* get_policy(const string& name) {
    if (name == "lru") return new LRUPolicy();
    if (name == "lfu") return new LFUPolicy();
    if (name == "decaying_lfu") return new DecayingLFUPolicy();
    if (name == "ml") return new MLPolicy();
    return nullptr;
}
