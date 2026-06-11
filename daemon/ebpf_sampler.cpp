#include "ebpf_sampler.h"
#include "../workload/workload.h"
#include "bpf/mem_sampler.skel.h"
#include <algorithm>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

using namespace std;
using namespace std::chrono;

EbpfSampler::EbpfSampler(int target_pid)
    : target_pid(target_pid), skel(nullptr) {}

EbpfSampler::~EbpfSampler() {
  for (int fd : perf_fds) {
    if (fd >= 0)
      close(fd);
  }
  perf_fds.clear();

  for (struct bpf_link *link : links) {
    if (link)
      bpf_link__destroy(link);
  }
  links.clear();

  if (skel)
    mem_sampler_bpf__destroy(skel);
}

bool EbpfSampler::discover_workload_regions() {
  std::string maps_path = "/proc/" + std::to_string(target_pid) + "/maps";
  std::ifstream maps(maps_path);
  if (!maps.is_open()) {
    std::cerr << "[EbpfSampler] Cannot open " << maps_path << std::endl;
    return false;
  }

  std::string line;
  size_t total_tracked = 0;
  while (std::getline(maps, line)) {
    uintptr_t start, end;
    char perms[5];
    unsigned long offset, inode;
    unsigned int dev_major, dev_minor;

    if (sscanf(line.c_str(), "%lx-%lx %4s %lx %x:%x %lu", &start, &end, perms,
               &offset, &dev_major, &dev_minor, &inode) >= 7) {
      if (strcmp(perms, "rw-p") == 0 && inode == 0) {
        size_t size_kb = (end - start) / 1024;
        if (size_kb >= 4) {
          vma_regions.push_back({start, end});
          total_tracked += (end - start);
          std::cerr << "[EbpfSampler] VMA: 0x" << std::hex << start << " - 0x"
                    << end << std::dec << " (" << size_kb << " KB)"
                    << std::endl;
        }
      }
    }
  }

  std::sort(vma_regions.begin(), vma_regions.end(),
            [](auto &a, auto &b) { return a.va_start < b.va_start; });

  std::cerr << "[EbpfSampler] Discovered " << vma_regions.size()
            << " workload VMAs (" << (total_tracked / (1024 * 1024))
            << " MB total)" << std::endl;

  return !vma_regions.empty();
}

bool EbpfSampler::start_recording() {
  skel = mem_sampler_bpf__open_and_load();
  if (!skel) {
    std::cerr << "[EbpfSampler] Failed to open and load BPF skeleton\n";
    return false;
  }

  skel->bss->target_pid = target_pid;

  int num_possible = libbpf_num_possible_cpus();

  // Attach to all online CPUs
  for (int cpu = 0; cpu < num_possible; cpu++) {
    struct perf_event_attr attr = {};
    attr.type = 4;
    attr.config = 0x1cd;
    attr.config1 = 4;
    attr.size = sizeof(attr);
    attr.freq = 1;
    attr.sample_freq = 40000;
    attr.sample_type = PERF_SAMPLE_ADDR | PERF_SAMPLE_IP | PERF_SAMPLE_TID;
    attr.precise_ip = 2;
    attr.disabled = 1;

    int fd = syscall(SYS_perf_event_open, &attr, -1, cpu, -1, 0);
    if (fd < 0) {
      continue;
    }

    struct bpf_link *link =
        bpf_program__attach_perf_event(skel->progs.sample_mem, fd);
    if (libbpf_get_error(link)) {
      std::cerr << "[EbpfSampler] Failed to attach BPF to perf event on CPU "
                << cpu << "\n";
      close(fd);
      continue;
    }

    ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
    perf_fds.push_back(fd);
    links.push_back(link);
  }

  if (perf_fds.empty()) {
    std::cerr << "[EbpfSampler] Failed to open perf_event on any CPU\n";
    return false;
  }

  return true;
}

bool EbpfSampler::is_workload_vma(uintptr_t va) const {
  for (const auto &region : vma_regions) {
    if (va >= region.va_start && va < region.va_end) {
      return true;
    }
  }
  return false;
}

void EbpfSampler::reset() { page_samples.clear(); }

void EbpfSampler::sample_epoch() {
  reset();
  auto t0 = high_resolution_clock::now();

  int map_fd = bpf_map__fd(skel->maps.page_counts);
  int num_possible = libbpf_num_possible_cpus();
  std::vector<uint64_t> per_cpu_values(num_possible);
  std::vector<uint64_t> keys_to_process;

  // PASS 1: Collect keys
  uint64_t key = 0, next_key;
  bool first = true;
  while (true) {
    int ret;
    if (first) {
      ret = bpf_map_get_next_key(map_fd, NULL, &next_key);
      first = false;
    } else {
      ret = bpf_map_get_next_key(map_fd, &key, &next_key);
    }
    if (ret != 0)
      break;

    keys_to_process.push_back(next_key);
    key = next_key;
  }

  // PASS 2: Aggregate and delete
  int passed_filter = 0;
  for (uint64_t k : keys_to_process) {
    if (bpf_map_lookup_elem(map_fd, &k, per_cpu_values.data()) == 0) {
      uint64_t total = 0;
      for (int i = 0; i < num_possible; i++) {
        total += per_cpu_values[i];
      }

      if (total > 0 && is_workload_vma((uintptr_t)k)) {
        page_samples[(uintptr_t)k].sample_count += (int)total;
        passed_filter++;
      }
    }
    bpf_map_delete_elem(map_fd, &k);
  }

  auto t1 = high_resolution_clock::now();
  last_parse_duration_ms = duration<double, milli>(t1 - t0).count();

  // Debug output if we have an abnormally low number of pages
  if (page_samples.size() > 0 && page_samples.size() < 100) {
    std::cerr << "[EbpfSampler] DEBUG: map_keys=" << keys_to_process.size()
              << ", passed_filter=" << passed_filter
              << ", final_tracked=" << page_samples.size()
              << " | BPF Telemetry: HW=" << skel->bss->debug_total_hw_samples
              << ", PID_match=" << skel->bss->debug_pid_matches
              << ", Addr_valid=" << skel->bss->debug_addr_valid << std::endl;
  }
}

int EbpfSampler::get_sample_count(uintptr_t page_va) const {
  auto it = page_samples.find(page_va);
  return it != page_samples.end() ? it->second.sample_count : 0;
}

double EbpfSampler::get_avg_latency(uintptr_t /*page_va*/) const { return 0.0; }
