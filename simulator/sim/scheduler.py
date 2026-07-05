import numpy as np

class Scheduler:
  def __init__(self):
    self.policy = ""
    self.memory = None
    self.traffic = None
    self.num_reqs_per_ep = 0
    self.curr_ep = 0
    self.num_migr = 0
    self.l1_hits = 0

  def init(self, traffic, memory, policy, num_reqs_per_ep, l1_ratio):
    self.traffic = traffic
    self.memory = memory
    self.policy = policy
    self.num_reqs_per_ep = num_reqs_per_ep
    if num_reqs_per_ep == 0:
      self.num_periods = 1
    else:
      self.num_periods = (traffic.num_reqs // num_reqs_per_ep) + 1
    self.l1_ratio = l1_ratio
    self.curr_ep = 0
    self.num_migr = 0
    self.l1_hits = 0
    self.total_misplaced_epochs = 0
    self.unique_misplaced_pages = set()
    self.memory.init_cnts(self.num_periods, policy)
    self.memory.init_tier(self.l1_ratio)
    self.set_oracle_cnts()
    self.memory.set_patterns()
    print("[Scheduler] Initialization done for policy =", self.policy, "periods =", self.num_periods, "reqs per period =", self.num_reqs_per_ep, "cap ratio =", self.l1_ratio)

  def set_oracle_cnts(self):
    for page in self.memory.page_list:
      page.oracle_counts_ep = np.zeros(self.num_periods)
    ep = 0
    for req in self.traffic.req_seq:
      if self.num_reqs_per_ep > 0:
        if req.id % self.num_reqs_per_ep == 0 and req.id != 0:
          ep += 1
      page = self.memory.page_list[req.page_id]
      page.oracle_counts_ep[ep] += 1
    for page in self.memory.page_list:
      bins = range(0, int(max(page.oracle_counts_ep)), 20)
      idxs = np.digitize(page.oracle_counts_ep, bins)
      page.oracle_counts_binned_ep = [bins[idxs[i]-1] for i in range(len(page.oracle_counts_ep))]

  def run(self):
    for req in self.traffic.req_seq:
      if self.num_reqs_per_ep > 0:
        if req.id % self.num_reqs_per_ep == 0 and req.id != 0:
          self.retier()
      page = self.memory.page_list[req.page_id]
      page.increase_cnt(self.curr_ep)
      page.epoch_access_count += 1
      self.memory.update_lru(page.id)
    self.hitrate()
  
  def retier(self):
    self.memory.capacity_check(self.curr_ep)
    
    if self.policy in ['ml', 'lfu', 'decaying_lfu']:
      self.memory.update_ml_features(self.num_reqs_per_ep)
      
    self.curr_ep += 1
    self.memory.update_tier(self.curr_ep)
    
    if self.policy == 'ml':
      hot_pages = self.memory.get_l2_hot_pages_ml(self.curr_ep)
    elif self.policy == 'lfu':
      hot_pages = self.memory.get_l2_hot_pages_lfu(self.curr_ep)
    elif self.policy == 'lru':
      hot_pages = self.memory.get_l2_hot_pages_lru(self.curr_ep)
    elif self.policy == 'decaying_lfu':
      hot_pages = self.memory.get_l2_hot_pages_decaying_lfu(self.curr_ep)
    else:
      hot_pages = self.memory.get_l2_hot_pages(self.curr_ep, self.policy)
    nmigr = min(self.memory.l1_pages, len(hot_pages))
    lru_pages = self.memory.get_l1_lru_pages(self.curr_ep)
    self.memory.tier_pages(hot_pages[:nmigr], lru_pages[:nmigr], self.curr_ep)
    self.num_migr += 2*nmigr
    self.compute_misplacements()

  def compute_misplacements(self):
    # Oracle's ideal: top-K pages by actual access count this epoch
    page_counts = [(page.id, page.oracle_counts_ep[self.curr_ep]) 
                   for page in self.memory.page_list]
    page_counts.sort(key=lambda x: x[1], reverse=True)
    ideal_fast_set = set(pid for pid, _ in page_counts[:self.memory.l1_pages])
    
    epoch_misplaced = 0
    for page_id in ideal_fast_set:
      page = self.memory.page_list[page_id]
      if page.loc_ep[self.curr_ep] == 1:
        epoch_misplaced += 1
        page.misplacements += 1
        self.unique_misplaced_pages.add(page_id)
    self.total_misplaced_epochs += epoch_misplaced

  def hitrate(self):
    for page in self.memory.page_list:
      for ep in range(self.num_periods):
        if page.loc_ep[ep] == 0:
          self.l1_hits += page.counts_ep[ep]
