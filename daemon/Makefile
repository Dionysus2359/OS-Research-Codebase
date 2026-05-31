CXX = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17
LDFLAGS = -lnuma -lm

TARGET = daemon

SRCS = daemon.cpp tier_manager.cpp policy.cpp
OBJS = $(SRCS:.cpp=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(OBJS) $(LDFLAGS)

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(OBJS)
