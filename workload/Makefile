CXX = g++
CXXFLAGS = -Wall -Wextra -O2 -std=c++17
LDFLAGS = -lnuma

TARGET = workload

all: $(TARGET)

$(TARGET): workload.cpp
	$(CXX) $(CXXFLAGS) -o $(TARGET) workload.cpp $(LDFLAGS)

clean:
	rm -f $(TARGET)
