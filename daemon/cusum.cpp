#include "cusum.h"
#include <cmath>
#include <algorithm>
#include <iostream>

bool CUSUMDetector::update(double observation) {
    n_observations++;
    double delta = observation - running_mean;
    running_mean += delta / n_observations;
    double delta2 = observation - running_mean;
    running_m2 += delta * delta2;
    
    epochs_since_detection++;
    
    if (n_observations < 10) return false;  // Need warm-up period
    
    double variance = running_m2 / (n_observations - 1);
    double sigma = std::sqrt(variance);
    if (sigma < 1e-10) return false;
    
    double k = 0.5 * sigma;    // Slack (half-sigma)
    double h = 4.0 * sigma;    // Decision threshold
    
    // Update CUSUM statistics
    S_high = std::max(0.0, S_high + (observation - running_mean) - k);
    S_low  = std::max(0.0, S_low  - (observation - running_mean) - k);
    
    bool detected = (S_high > h || S_low > h);
    
    if (detected) {
        S_high = 0;
        S_low = 0;
        epochs_since_detection = 0;
        std::cerr << "[CUSUM] Change-point detected! "
                  << "obs=" << observation << " mean=" << running_mean
                  << " sigma=" << sigma << std::endl;
    }
    
    return detected;
}

double CUSUMDetector::get_promote_margin() const {
    if (epochs_since_detection <= REACT_EPOCHS) {
        return REACT_PROMOTE;
    } else if (epochs_since_detection <= TRANSITION_EPOCHS) {
        double t = (double)(epochs_since_detection - REACT_EPOCHS) 
                 / (TRANSITION_EPOCHS - REACT_EPOCHS);
        return REACT_PROMOTE + t * (stable_promote - REACT_PROMOTE);
    }
    return stable_promote;
}

double CUSUMDetector::get_demote_margin() const {
    if (epochs_since_detection <= REACT_EPOCHS) {
        return react_demote;
    } else if (epochs_since_detection <= TRANSITION_EPOCHS) {
        double t = (double)(epochs_since_detection - REACT_EPOCHS) 
                 / (TRANSITION_EPOCHS - REACT_EPOCHS);
        return react_demote + t * (stable_demote - react_demote);
    }
    return stable_demote;
}

double CUSUMDetector::get_absolute_threshold() const {
    if (epochs_since_detection <= REACT_EPOCHS) {
        return REACT_ABS_THRESHOLD;
    } else if (epochs_since_detection <= TRANSITION_EPOCHS) {
        double t = (double)(epochs_since_detection - REACT_EPOCHS) 
                 / (TRANSITION_EPOCHS - REACT_EPOCHS);
        return REACT_ABS_THRESHOLD + t * (stable_abs_threshold - REACT_ABS_THRESHOLD);
    }
    return stable_abs_threshold;
}
