#ifndef CUSUM_H
#define CUSUM_H

class CUSUMDetector {
    // Adaptive statistics (Welford's online algorithm)
    double running_mean = 0;
    double running_m2 = 0;       // Running sum of squared differences
    int n_observations = 0;
    
    // CUSUM state
    double S_high = 0;
    double S_low = 0;
    
    // Reaction state
    int epochs_since_detection = 999;
    static constexpr int REACT_EPOCHS = 5;
    static constexpr int TRANSITION_EPOCHS = 20;
    
    // Margin bounds
    static constexpr double REACT_PROMOTE = 0.001;
    static constexpr double REACT_DEMOTE = 0.01;
    static constexpr double STABLE_PROMOTE = 0.05;
    static constexpr double STABLE_DEMOTE = 0.10;
    
    static constexpr double REACT_ABS_THRESHOLD = 0.50;
    static constexpr double STABLE_ABS_THRESHOLD = 0.75;
    
public:
    CUSUMDetector() = default;
    
    bool update(double observation);  // Returns true if change-point detected
    
    double get_promote_margin() const;
    double get_demote_margin() const;
    double get_absolute_threshold() const;
};

#endif
