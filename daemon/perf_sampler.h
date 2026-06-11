#ifndef PERF_SAMPLER_H
#define PERF_SAMPLER_H

#include <vector>
#include <string>
#include <unordered_map>
#include <sys/types.h>
#include <cstdint>

// Public so TierManager can iterate over epoch samples
struct PageSample {
    int sample_count = 0;
    double total_latency_cycles = 0.0;
};

class PerfSampler {
    int target_pid;
    pid_t perf_pid;             // PID of the long-lived perf record process
    std::string perf_data_dir;  // Directory for rotated perf.data files
    
    // Valid workload VMA ranges (anonymous rw-p mappings)
    struct VMRegion {
        uintptr_t va_start;
        uintptr_t va_end;
    };
    std::vector<VMRegion> vma_regions;  // sorted by va_start
    
    // Key = page-aligned virtual address of the sampled page
    std::unordered_map<uintptr_t, PageSample> page_samples;
    
    // Epoch timing measurement
    double last_parse_duration_ms = 0;

    bool is_workload_vma(uintptr_t va) const;
    std::string find_latest_rotated_file() const;
    
public:
    PerfSampler(int target_pid);
    ~PerfSampler();  // Kills the long-lived perf process
    
    bool discover_workload_regions(); // Finds ALL workload anonymous rw-p mappings
    bool start_recording();           // Fork perf record once at startup
    void sample_epoch();              // SIGUSR2 + parse rotated file
    
    int get_sample_count(uintptr_t page_va) const;
    double get_avg_latency(uintptr_t page_va) const;
    double get_last_parse_duration_ms() const { return last_parse_duration_ms; }
    void reset();
    
    const std::unordered_map<uintptr_t, PageSample>& get_all_samples() const { return page_samples; }
};

#endif
