CXX = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17
LDFLAGS = -lnuma -lm -lbpf -lelf -lz



TARGET = daemon

SRCS = daemon.cpp tier_manager.cpp policy.cpp ebpf_sampler.cpp cusum.cpp
OBJS = $(SRCS:.cpp=.o)

# BPF build artifacts
BPF_DIR = bpf
BPF_SKEL = $(BPF_DIR)/mem_sampler.skel.h
BPF_OBJ  = $(BPF_DIR)/mem_sampler.bpf.o
VMLINUX  = $(BPF_DIR)/vmlinux.h

all: $(TARGET)

# Stage 1: Generate vmlinux.h from running kernel BTF
$(VMLINUX):
	@mkdir -p $(BPF_DIR)
	bpftool btf dump file /sys/kernel/btf/vmlinux format c > $@

# Stage 2: Compile BPF program to bytecode
$(BPF_OBJ): $(BPF_DIR)/mem_sampler.bpf.c $(VMLINUX) $(BPF_DIR)/mem_sampler.h
	clang -g -O2 -target bpf -D__TARGET_ARCH_x86 \
		-Wno-missing-declarations -Wno-unused-parameter \
		-I$(BPF_DIR) \
		-c $(BPF_DIR)/mem_sampler.bpf.c -o $@

# Stage 3: Generate skeleton header
$(BPF_SKEL): $(BPF_OBJ)
	bpftool gen skeleton $< > $@

# Stage 4: C++ objects depend on skeleton
ebpf_sampler.o: ebpf_sampler.cpp ebpf_sampler.h $(BPF_SKEL)
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(OBJS) $(LDFLAGS)

clean:
	rm -f $(TARGET) $(OBJS) $(BPF_OBJ) $(BPF_SKEL)

distclean: clean
	rm -f $(VMLINUX)
