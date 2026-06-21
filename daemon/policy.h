#ifndef POLICY_H
#define POLICY_H

#include "tier_manager.h"
#include "cusum.h"
#include <string>

extern int SLOW_NODE;

class Policy {
public:
    virtual ~Policy() = default;
    virtual void execute(TierManager& mgr) = 0;
    virtual void set_margins(double /*abs*/, double /*demote*/) {}
};

class LRUPolicy : public Policy {
public:
    void execute(TierManager& mgr) override;
};

class LFUPolicy : public Policy {
public:
    void execute(TierManager& mgr) override;
};

class DecayingLFUPolicy : public Policy {
public:
    void execute(TierManager& mgr) override;
};

class MLPolicy : public Policy {
public:
    void execute(TierManager& mgr) override;
    void set_margins(double abs_thresh, double demote_margin) override {
        cusum.set_margins(abs_thresh, demote_margin);
    }
private:
    double score_page(const PageMetadata& meta) const;
    CUSUMDetector cusum;
};

class RandomPolicy : public Policy {
public:
    void execute(TierManager& mgr) override;
};

Policy* get_policy(const std::string& name);

#endif
