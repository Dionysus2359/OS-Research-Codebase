#include "perf_sampler.h"
#include <iostream>
#include <fstream>
#include <algorithm>
#include <chrono>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <dirent.h>
#include <cstring>
#include "../workload/workload.h"

PerfSampler::PerfSampler(int target_pid) : target_pid(target_pid), perf_pid(-1) {}

PerfSampler::~PerfSampler() {
    if (perf_pid > 0) {
        kill(perf_pid, SIGTERM);
        waitpid(perf_pid, nullptr, 0);
    }
}

bool PerfSampler::discover_workload_regions() {
    std::string maps_path = "/proc/" + std::to_string(target_pid) + "/maps";
    std::ifstream maps(maps_path);
    if (!maps.is_open()) {
        std::cerr << "[PerfSampler] Cannot open " << maps_path << std::endl;
        return false;
    }
    
    std::string line;
    size_t total_tracked = 0;
    while (std::getline(maps, line)) {
        uintptr_t start, end;
        char perms[5];
        unsigned long offset, inode;
        unsigned int dev_major, dev_minor;
        
        if (sscanf(line.c_str(), "%lx-%lx %4s %lx %x:%x %lu",
                   &start, &end, perms, &offset, &dev_major, &dev_minor, &inode) >= 7) {
            if (strcmp(perms, "rw-p") == 0 && inode == 0) {
                size_t size_kb = (end - start) / 1024;
                if (size_kb >= 4) {  // Skip tiny VMAs (< 1 page)
                    vma_regions.push_back({start, end});
                    total_tracked += (end - start);
                }
            }
        }
    }
    
    // Sort for potential future std::lower_bound optimization
    std::sort(vma_regions.begin(), vma_regions.end(),
              [](auto& a, auto& b) { return a.va_start < b.va_start; });
    
    std::cerr << "[PerfSampler] Discovered " << vma_regions.size() 
              << " workload VMAs (" << (total_tracked / (1024*1024)) << " MB total)"
              << std::endl;
    
    return !vma_regions.empty();
}

bool PerfSampler::start_recording() {
    perf_data_dir = "/tmp/perf_epoch";
    
    perf_pid = fork();
    if (perf_pid == 0) {
        execlp("perf", "perf", "record",
               "-e", "{cpu_core/mem-loads-aux/,cpu_core/mem-loads,ldlat=4/}:pp",
               "-d",
               "-p", std::to_string(target_pid).c_str(),
               "-c", "1000",
               "--switch-output=signal",
               "--switch-max-files=3",
               "-o", (perf_data_dir + ".data").c_str(),
               "--quiet",
               (char*)NULL);
        _exit(1);
    }
    
    usleep(200000);  // 200ms: let perf initialize ring buffers
    return perf_pid > 0;
}

std::string PerfSampler::find_latest_rotated_file() const {
    std::string latest_file = "";
    std::string prefix = "perf_epoch.data.";
    DIR* dir = opendir("/tmp");
    if (dir) {
        struct dirent* ent;
        while ((ent = readdir(dir)) != nullptr) {
            std::string name = ent->d_name;
            if (name.find(prefix) == 0 && name > latest_file) {
                latest_file = name;
            }
        }
        closedir(dir);
    }
    if (!latest_file.empty()) {
        return "/tmp/" + latest_file;
    }
    return "";
}

bool PerfSampler::is_workload_vma(uintptr_t va) const {
    for (const auto& region : vma_regions) {
        if (va >= region.va_start && va < region.va_end) {
            return true;
        }
    }
    return false;
}

void PerfSampler::reset() {
    page_samples.clear();
}

void PerfSampler::sample_epoch() {
    reset();
    
    auto t0 = std::chrono::high_resolution_clock::now();
    
    kill(perf_pid, SIGUSR2);
    usleep(10000);  // 10ms: let perf flush and create the new file
    
    std::string rotated_file = find_latest_rotated_file();
    if (rotated_file.empty()) return;
    
    std::string cmd = "perf script -i " + rotated_file + " 2>/dev/null";
    FILE* pipe = popen(cmd.c_str(), "r");
    if (!pipe) return;
    
    char buf[512];
    while (fgets(buf, sizeof(buf), pipe)) {
        char comm[64], event[64];
        int pid;
        double time;
        unsigned long weight;
        uintptr_t va;
        int cpu = 0;
        int parsed = sscanf(buf, "%63s %d [%d] %lf: %lu %63s %lx", comm, &pid, &cpu, &time, &weight, event, &va);
        if (parsed < 7) {
            parsed = sscanf(buf, "%63s %d %lf: %lu %63s %lx", comm, &pid, &time, &weight, event, &va);
        }
        
        if (parsed >= 6) {
            std::string ev_str(event);
            if (ev_str.find("mem-loads,ldlat") != std::string::npos) {
                if (is_workload_vma(va)) {
                    uintptr_t page_va = va & ~((uintptr_t)PAGE_SIZE - 1);
                    page_samples[page_va].sample_count++;
                    page_samples[page_va].total_latency_cycles += (double)weight;
                }
            }
        }
    }
    pclose(pipe);
    
    unlink(rotated_file.c_str());
    
    auto t1 = std::chrono::high_resolution_clock::now();
    last_parse_duration_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    
    if (last_parse_duration_ms > 50.0) {
        std::cerr << "[PerfSampler] WARNING: Parse took " 
                  << last_parse_duration_ms << "ms (budget: 50ms)" << std::endl;
    }
}

int PerfSampler::get_sample_count(uintptr_t page_va) const {
    auto it = page_samples.find(page_va);
    return it != page_samples.end() ? it->second.sample_count : 0;
}

double PerfSampler::get_avg_latency(uintptr_t page_va) const {
    auto it = page_samples.find(page_va);
    if (it != page_samples.end() && it->second.sample_count > 0) {
        return it->second.total_latency_cycles / it->second.sample_count;
    }
    return 0.0;
}
