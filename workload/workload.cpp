#include "workload.h"
#include <iostream>
#include <fstream>
#include <vector>
#include <chrono>
#include <random>
#include <algorithm>
#include <sys/mman.h>
#include <unistd.h>
#include <cstring>
#include <numaif.h>

using namespace std;
using namespace std::chrono;

void update_shared_info(WorkloadInfo& info, int current_phase) {
    info.current_phase = current_phase;
    ofstream outfile(WORKLOAD_INFO_PATH);
    if (outfile.is_open()) {
        outfile << info.pid << "\n"
                << info.base_address << "\n"
                << info.total_pages << "\n"
                << info.current_phase << "\n";
        outfile.close();
    }
}

int main() {
    cout << "=========================================" << endl;
    cout << "[Workload] Real Memory Workload Generator" << endl;
    cout << "[Workload] PID: " << getpid() << endl;
    cout << "[Workload] Config: " << TOTAL_PAGES << " pages (" 
         << (TOTAL_PAGES * PAGE_SIZE / 1024) << " KB), "
         << "Fast Tier Capacity: " << FAST_TIER_CAPACITY << " pages" << endl;
    cout << "=========================================" << endl;

    // 1. Allocate Base Memory via mmap
    size_t total_size = TOTAL_PAGES * PAGE_SIZE;
    void* base_addr = mmap(NULL, total_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base_addr == MAP_FAILED) {
        perror("mmap failed");
        return 1;
    }

    // Initialize pointer-chase shuffle array (for Phase 4)
    vector<int> chase_indices(TOTAL_PAGES);
    for (int i = 0; i < TOTAL_PAGES; ++i) chase_indices[i] = i;
    mt19937 gen(42);
    shuffle(chase_indices.begin(), chase_indices.end(), gen);

    // Bind ALL pages to Node 1 (Slow Tier) initially
    unsigned long nodemask = (1UL << 1); // Node 1
    if (mbind(base_addr, total_size, MPOL_BIND, &nodemask, sizeof(nodemask)*8, MPOL_MF_MOVE) != 0) {
        perror("mbind failed (make sure you have NUMA node 1)");
    } else {
        cout << "[Workload] All " << TOTAL_PAGES << " pages bound to Node 1 (Slow Tier)." << endl;
    }

    // Force physical allocation by touching every page
    char* memory = static_cast<char*>(base_addr);
    for (int i = 0; i < TOTAL_PAGES; ++i) {
        memory[i * PAGE_SIZE] = 1;
    }

    // Write workload info for daemon IPC
    WorkloadInfo info;
    info.pid = getpid();
    info.base_address = base_addr;
    info.total_pages = TOTAL_PAGES;
    update_shared_info(info, 0);

    // Phase runner: each phase runs for exactly 10 seconds
    auto run_phase = [&](int phase_id, const string& name, auto access_logic) {
        update_shared_info(info, phase_id);
        cout << "\n[Phase " << phase_id << "] " << name << " (10s)..." << flush;
        
        auto start = high_resolution_clock::now();
        long touches = 0;
        
        while (duration_cast<seconds>(high_resolution_clock::now() - start).count() < 10) {
            int page_idx = access_logic(touches, gen);
            if (page_idx >= 0 && page_idx < TOTAL_PAGES) {
                volatile char* page_ptr = memory + (page_idx * PAGE_SIZE);
                *page_ptr = *page_ptr + 1;
            }
            touches++;
        }
        
        double duration_s = duration_cast<milliseconds>(high_resolution_clock::now() - start).count() / 1000.0;
        double throughput = touches / duration_s;
        
        cout << "\n         Done. " << touches << " accesses | "
             << "Duration: " << duration_s << "s | "
             << "Throughput: " << (long)throughput << " acc/s" << endl;
        
        // 500ms pause between phases (clean epoch boundary for daemon)
        usleep(500000);
    };

    // ============ RUN ALL 6 PHASES ============

    // Pre-compute Zipf CDF for HOTSPOT_PAGES with s=1.2
    vector<double> zipf_cdf(HOTSPOT_PAGES);
    {
        double s = 1.2;
        double sum = 0;
        for (int i = 0; i < HOTSPOT_PAGES; i++) sum += 1.0 / pow(i + 1, s);
        double cumulative = 0;
        for (int i = 0; i < HOTSPOT_PAGES; i++) {
            cumulative += (1.0 / pow(i + 1, s)) / sum;
            zipf_cdf[i] = cumulative;
        }
    }

    // Helper: sample one page from Zipf distribution using binary search on CDF
    auto sample_zipf = [&](mt19937& g) -> int {
        uniform_real_distribution<> u(0.0, 1.0);
        double r = u(g);
        return (int)(lower_bound(zipf_cdf.begin(), zipf_cdf.end(), r) - zipf_cdf.begin());
    };

    // Phase 1: Sequential scan (read across all pages linearly)
    run_phase(1, "Sequential Scan", [](long touches, mt19937& g) {
        (void)g;
        return (int)(touches % TOTAL_PAGES);
    });

    // Phase 2: Zipf over 384 pages — throttled to create real frequency differentiation
    run_phase(2, "Zipf Loop (384-page working set, throttled)", [&](long touches, mt19937& g) {
        (void)touches;
        usleep(150); // throttle: ~6,600 accesses/second = ~660 touches/100ms epoch
        return sample_zipf(g); // returns 0-383 following Zipf(s=1.2)
    });

    // Phase 3: Burst (spike 8 hotspot pages amid random, R/W)
    run_phase(3, "Burst (8 Hotspots amid random)", [&](long touches, mt19937& g) {
        uniform_int_distribution<> unif(0, TOTAL_PAGES - 1);
        uniform_int_distribution<> burst(0, 7);
        return (touches % 10 < 8) ? burst(g) : unif(g);
    });

    // Phase 4: Pointer-chase (randomized linked list walk, R)
    run_phase(4, "Pointer-chase (Random walk)", [&](long touches, mt19937& g) {
        (void)g;
        return chase_indices[touches % TOTAL_PAGES];
    });

    // Phase 5: Random (uniform random page access, R/W)
    run_phase(5, "Random Uniform Access", [&](long touches, mt19937& g) {
        (void)touches;
        uniform_int_distribution<> unif(0, TOTAL_PAGES - 1);
        return unif(g);
    });

    // Phase 6: New Data (shift working set to last 384 pages, completely cold since Phase 1)
    // By remaining in the tracked base_addr region, the daemon can detect the shift
    // and must migrate out the stale working set to promote the new one.
    run_phase(6, "New Data Zipf (last 384 pages, throttled)", [&](long touches, mt19937& g) {
        (void)touches;
        usleep(150);
        // Apply Zipf within the 384-page window
        return (TOTAL_PAGES - NEW_DATA_PAGES) + sample_zipf(g);
    });

    // Cleanup
    cout << "\n=========================================" << endl;
    cout << "[Workload] All 6 phases complete." << endl;
    update_shared_info(info, -1); // Signal daemon: workload finished
    munmap(base_addr, total_size);
    unlink(WORKLOAD_INFO_PATH);
    
    return 0;
}
