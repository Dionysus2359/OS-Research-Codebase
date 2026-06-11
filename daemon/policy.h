#ifndef POLICY_H
#define POLICY_H

#include "tier_manager.h"
#include "cusum.h"
#include <string>

class Policy {
public:
    virtual ~Policy() = default;
    virtual void execute(TierManager& mgr) = 0;
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
private:
    double score_page(const PageMetadata& meta) const;
    CUSUMDetector cusum;
};

Policy* get_policy(const std::string& name);

#endif
