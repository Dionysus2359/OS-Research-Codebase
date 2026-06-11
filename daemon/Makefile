CXX = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17
LDFLAGS = -lnuma -lm

# Set LOCAL_DEV=1 for laptop testing (injects CXL latency penalty)
# Unset for CloudLab/real NUMA hardware
ifdef LOCAL_DEV
CXXFLAGS += -DLOCAL_DEV
endif

TARGET = daemon

SRCS = daemon.cpp tier_manager.cpp policy.cpp perf_sampler.cpp cusum.cpp
OBJS = $(SRCS:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJS)
