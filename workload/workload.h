#ifndef WORKLOAD_H
#define WORKLOAD_H

#include <cstdint>

// Configuration per implementation plan
constexpr int PAGE_SIZE = 4096;
constexpr int TOTAL_PAGES = 2048;           // 8MB base memory
extern int FAST_TIER_CAPACITY;
constexpr int NEW_DATA_PAGES = 384;         // Extra for phase 6
constexpr int HOTSPOT_PAGES = 384;          // Used in Loop phase

// Real measured latencies from r650 (via MLC --latency_matrix)
// TODO: Replace with actual measured values on CloudLab r650
constexpr int FAST_LATENCY_NS = 89;         // Measured local DRAM on r650
constexpr int SLOW_LATENCY_NS = 155;        // Measured remote DRAM on r650
constexpr int SLOW_WRITE_LATENCY_NS = 195;  // Measured remote write on r650

// CXL literature projection constants (kept for dual-column reporting)
constexpr int CXL_FAST_LATENCY_NS = 80;
constexpr int CXL_SLOW_LATENCY_NS = 400;
constexpr int CXL_SLOW_WRITE_LATENCY_NS = 550;

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
