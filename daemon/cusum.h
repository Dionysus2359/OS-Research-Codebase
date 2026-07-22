#ifndef CUSUM_H
#define CUSUM_H

class CUSUMDetector {
  // Adaptive statistics (Welford's online algorithm)
  double running_mean = 0;
  double running_m2 = 0; // Running sum of squared differences
  int n_observations = 0;

  // CUSUM state
  double S_high = 0;
  double S_low = 0;

  // Reaction state
  int epochs_since_detection = 999;
  static constexpr int REACT_EPOCHS = 5;
  static constexpr int TRANSITION_EPOCHS = 20;

  // Margin bounds
  static constexpr double REACT_PROMOTE = 0.05;
  double react_demote = 0.10;
  double stable_promote = 0.20;
  double stable_demote = 0.40;

  static constexpr double REACT_ABS_THRESHOLD = 0.10;
  double stable_abs_threshold = 0.921;

public:
  CUSUMDetector() = default;

  void set_margins(double abs_thresh, double demote_margin) {
      stable_abs_threshold = abs_thresh;
      stable_demote = demote_margin;
  }

  bool update(double observation); // Returns true if change-point detected

  double get_promote_margin() const;
  double get_demote_margin() const;
  double get_absolute_threshold() const;
};

#endif
