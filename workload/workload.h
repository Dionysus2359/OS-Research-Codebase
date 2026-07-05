#ifndef WORKLOAD_H
#define WORKLOAD_H

#include <cstdint>

// Configuration per implementation plan
constexpr int PAGE_SIZE = 4096;
constexpr int TOTAL_PAGES = 2048;           // 8MB base memory
extern int FAST_TIER_CAPACITY;
constexpr int NEW_DATA_PAGES = 384;         // Extra for phase 6
constexpr int HOTSPOT_PAGES = 384;          // Used in Loop phase

// Latency constants from CXL literature (for computed metrics)
constexpr int FAST_LATENCY_NS = 80;         // DRAM latency
constexpr int SLOW_LATENCY_NS = 400;        // CXL read latency
constexpr int SLOW_WRITE_LATENCY_NS = 550;  // CXL write latency (PCIe flit overhead)
constexpr double WRITE_RATIO = 0.30;        // Fraction of accesses that are writes

// Path to share workload info with the daemon
constexpr const char* WORKLOAD_INFO_PATH = "/tmp/workload_info";

struct WorkloadInfo {
    int pid;
    void* base_address;
    int total_pages;
    int current_phase;
};

#endif // WORKLOAD_H
