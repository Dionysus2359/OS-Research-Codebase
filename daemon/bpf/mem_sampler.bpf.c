#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include "mem_sampler.h"

volatile int target_pid = 0;
volatile __u64 debug_total_hw_samples = 0;
volatile __u64 debug_pid_matches = 0;
volatile __u64 debug_addr_valid = 0;

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, MAX_PAGE_ENTRIES);
    __type(key, __u64);
    __type(value, __u64);
} page_counts SEC(".maps");

SEC("perf_event")
int sample_mem(struct bpf_perf_event_data *ctx)
{
    __sync_fetch_and_add(&debug_total_hw_samples, 1);

    __u64 id = bpf_get_current_pid_tgid();
    __u32 pid = id >> 32;

    if (pid != target_pid)
        return 0;

    __sync_fetch_and_add(&debug_pid_matches, 1);

    __u64 addr = ctx->addr;
    if (!addr)
        return 0;

    __sync_fetch_and_add(&debug_addr_valid, 1);

    __u64 page_va = addr & ~0xFFFULL;

    __u64 *count = bpf_map_lookup_elem(&page_counts, &page_va);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        __u64 init = 1;
        bpf_map_update_elem(&page_counts, &page_va, &init, BPF_NOEXIST);
    }

    return 0;
}

char LICENSE[] SEC("license") = "GPL";
