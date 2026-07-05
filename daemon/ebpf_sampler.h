#ifndef EBPF_SAMPLER_H
#define EBPF_SAMPLER_H

#include <vector>
#include <string>
#include <unordered_map>
#include <cstdint>

struct PageSample {
    int sample_count = 0;
    double total_latency_cycles = 0.0;
};

struct VMRegion {
    uintptr_t va_start;
    uintptr_t va_end;
};

struct mem_sampler_bpf;
struct bpf_link;

class EbpfSampler {
    int target_pid;
    
    struct mem_sampler_bpf *skel;
    std::vector<int> perf_fds;
    std::vector<struct bpf_link*> links;
    
    std::vector<VMRegion> vma_regions;
    std::unordered_map<uintptr_t, PageSample> page_samples;
    
    double last_parse_duration_ms = 0;

    bool is_workload_vma(uintptr_t va) const;

public:
    EbpfSampler(int target_pid);
    ~EbpfSampler();

    bool discover_workload_regions();
    bool start_recording();
    void sample_epoch();

    int get_sample_count(uintptr_t page_va) const;
    double get_avg_latency(uintptr_t page_va) const;
    double get_last_parse_duration_ms() const { return last_parse_duration_ms; }
    void reset();

    const std::unordered_map<uintptr_t, PageSample>& get_all_samples() const {
        return page_samples;
    }
};

#endif
