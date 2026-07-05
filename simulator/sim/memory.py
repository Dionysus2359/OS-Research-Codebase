import numpy as np
import math

# ML Policy Constants (Retrained on Coeus traces)
ML_WEIGHTS = [-0.1439918785, 0.1305052386, -0.3081748756, 0.0000000000,
              0.0000000000, 0.3371134134, 0.4468972897, 0.4066146945]
ML_BIAS = 0.3054998609
ML_MEAN = [750.3455559200, 92.3797713657, 8.2882509367, 0.0000000000,
           0.0000000000, 50.2869054976, 0.4323195768, 287969.5251283153]
ML_STD  = [942.4641559488, 100.6532806563, 26.3762473006, 1.0000000000,
           1.0000000000, 52.5575233483, 0.3113296821, 443080.2727668207]

STABLE_ABS_THRESHOLD = 0.20
STABLE_DEMOTE_MARGIN = 0.20

def set_ml_margins(abs_thresh, demote_margin):
    global STABLE_ABS_THRESHOLD, STABLE_DEMOTE_MARGIN
    STABLE_ABS_THRESHOLD = abs_thresh
    STABLE_DEMOTE_MARGIN = demote_margin

def score_page_ml(page):
    features = [
        math.log1p(page.access_count),
        page.smooth_frequency,
        page.momentum,
        float(page.migration_history),
        float(page.epochs_since_access),
        page.hot_ratio,
        page.access_frequency_ratio,
        page.aci,
    ]
    dot = ML_BIAS
    for i in range(8):
        if ML_STD[i] > 1e-10:
            dot += ML_WEIGHTS[i] * (features[i] - ML_MEAN[i]) / ML_STD[i]
    if dot > 20: return 1.0
    if dot < -20: return 0.0
    return 1.0 / (1.0 + math.exp(-dot))

class Page:
  def __init__(self, id):
    self.id = id
    self.req_ids = []
    self.pc_ids = []
    self.reuse_dist = []
    self.misplacements = 0
    self.oracle_counts_ep = []
    self.oracle_counts_binned_ep = []
    self.pred_counts_binned_ep = []
    self.counts_ep = []
    self.loc_ep = []
    # ML feature state
    self.access_count = 0
    self.smooth_frequency = 0.0
    self.prev_smooth_frequency = 0.0
    self.momentum = 0.0
    self.migration_history = 0
    self.epochs_since_access = 0
    self.hot_ratio = 0.0
    self.access_frequency_ratio = 0.0
    self.aci = 0.0
    self.epoch_access_count = 0
    self.accessed_this_epoch = False
    
  def increase_cnt(self, ep):
    self.counts_ep[ep] += 1

class AddressSpace:
  def __init__(self):
    self.page_list = []
    self.num_pages = 0
    self.reqs_l1_pages = []
    self.l1_ratio = 0
    self.l1_pages = 0
    self.lru_list = []
    self.policy = ''
    self.oracle_page_ids = set()
    self.num_patterns = 0

  def set_patterns(self):
    distinct_page_cnts_seq = set()
    for page in self.page_list:
      if str(page.oracle_counts_binned_ep) not in distinct_page_cnts_seq:
        distinct_page_cnts_seq.add(str(page.oracle_counts_binned_ep))
    self.num_patterns = len(distinct_page_cnts_seq)

  def populate(self, traffic):
    # init space
    self.num_pages = traffic.num_pages
    for page_id in range(self.num_pages):
      page = Page(page_id)
      self.page_list.append(page)
    # reqs per page
    for req in traffic.req_seq:
      page = self.page_list[req.page_id]
      page.req_ids.append(req.id)
    # reuse distance
    for page in self.page_list:
      page.reuse_dist = np.diff(np.array(page.req_ids))

  def update_ml_features(self, reqs_per_ep):
    EWMA_ALPHA = 0.5
    DECAY = 0.95
    LATENCY_PENALTY_NS = 320.0  # 400 - 80

    # Save prev, set accessed flag
    for page in self.page_list:
        page.prev_smooth_frequency = page.smooth_frequency
        page.accessed_this_epoch = (page.epoch_access_count > 0)

    # Update EWMA, decay cold pages
    epoch_accesses = 0
    for page in self.page_list:
        if page.accessed_this_epoch:
            page.access_count += page.epoch_access_count
            page.smooth_frequency = EWMA_ALPHA * page.smooth_frequency + page.epoch_access_count
            page.epochs_since_access = 0
            epoch_accesses += page.epoch_access_count
        else:
            page.smooth_frequency *= DECAY
            page.epochs_since_access += 1
        page.momentum = page.smooth_frequency - page.prev_smooth_frequency

    # Normalize epoch_accesses using the expected eBPF sample rate.
    # The C++ daemon typically got ~1500-2000 samples per 100ms epoch.
    # The Cori simulator epochs are ~12,000-35,000 requests.
    # We apply a scaling factor so the ACI matches the model's training distribution.
    scale_factor = 2000.0 / reqs_per_ep if reqs_per_ep > 0 else 1.0
    normalized_epoch_accesses = epoch_accesses * scale_factor

    # hot_ratio
    freq_sum = sum(p.smooth_frequency for p in self.page_list if p.accessed_this_epoch)
    epoch_mean = freq_sum / epoch_accesses if epoch_accesses > 0 else 0.0
    for page in self.page_list:
        page.hot_ratio = (page.smooth_frequency / epoch_mean 
                          if (page.accessed_this_epoch and epoch_mean > 1e-10) else 0.0)

    # access_frequency_ratio, epoch_density, ACI
    max_sf = max((p.smooth_frequency for p in self.page_list), default=0.0)
    unique_accessed = sum(1 for p in self.page_list if p.accessed_this_epoch)
    epoch_density = epoch_accesses / unique_accessed if unique_accessed > 0 else 1.0

    for page in self.page_list:
        page.access_frequency_ratio = (page.smooth_frequency / max_sf 
                                       if max_sf > 1e-10 else 0.0)
        page.aci = page.smooth_frequency * LATENCY_PENALTY_NS * epoch_density

    # Reset per-epoch counters
    for page in self.page_list:
        page.epoch_access_count = 0

  def init_cnts(self, num_periods, policy):
    for page in self.page_list:
      page.counts_ep = np.zeros(num_periods)
      page.loc_ep = np.zeros(num_periods)
      page.pred_counts_binned_ep = np.zeros(num_periods)
      page.misplacements = 0
    self.lru_list = [page.id for page in self.page_list]
    self.policy = policy
    self.oracle_page_ids = set()
    
  def init_hybrid(self, oracle_page_ids):
    self.oracle_page_ids = set(oracle_page_ids)
    
  def init_tier(self, l1_ratio):
    self.l1_ratio = l1_ratio
    self.l1_pages = int(l1_ratio * self.num_pages)
    idxs = range(self.num_pages)
    if self.l1_ratio == 1:
      self.tier_pages(idxs, [], 0)
    elif self.l1_ratio == 0:
      self.tier_pages([], idxs, 0)
    else:
      l1_tier, l2_tier = [], []
      for i in range(self.num_pages):
        if i % 2 == 0 and len(l1_tier) < self.l1_pages:
          l1_tier.append(i)
        else:
          l2_tier.append(i)
      self.tier_pages(l1_tier, l2_tier, 0)
   
  def tier_pages(self, l1_tier, l2_tier, ep):
    for page_id in l1_tier:
      page = self.page_list[page_id]
      page.loc_ep[ep] = 0
    for page_id in l2_tier:
      page = self.page_list[page_id]
      page.loc_ep[ep] = 1
    
  def update_lru(self, page_id):
    for idx in range(len(self.lru_list)):
      if self.lru_list[idx] == page_id:
        self.lru_list.pop(idx)
        break
    self.lru_list.append(page_id)
   
  def update_tier(self, curr_ep):
    for page in self.page_list:
      page.loc_ep[curr_ep] = page.loc_ep[curr_ep-1]
  
  def get_l2_hot_pages(self, curr_ep, policy):
    # get the l2 hot pages than are HOTTER than the current l1 hot pages
    sorted_hot_page_ids, hot_page_ids, hot_page_cnts = [], [], []
    for page in self.page_list:
      pcnt = 0
      if policy == 'history':
        pcnt = page.oracle_counts_binned_ep[curr_ep - 1]
      elif policy == 'oracle':
        pcnt = page.oracle_counts_binned_ep[curr_ep]
      elif policy == 'hybrid' or policy == 'hybrid-group':
        if page.id in self.oracle_page_ids:
          pcnt = page.oracle_counts_binned_ep[curr_ep]
        else:
          pcnt = page.oracle_counts_binned_ep[curr_ep - 1]
      if pcnt != 0: # consider pages that are touched in this period
        hot_page_ids.append(page.id)
        hot_page_cnts.append(pcnt)
      page.pred_counts_binned_ep[curr_ep] = pcnt
    # sort
    sorted_idxs = np.argsort(hot_page_cnts)[::-1]
    sorted_hot_page_ids = [hot_page_ids[i] for i in sorted_idxs]
    npages = 0
    page_id = 0
    l2_hot_pages_to_move = []
    while npages < self.l1_pages and npages < len(sorted_hot_page_ids):
      page = self.page_list[sorted_hot_page_ids[page_id]]
      if page.loc_ep[curr_ep-1] == 1:
        l2_hot_pages_to_move.append(page.id)
      npages += 1
      page_id += 1
    return l2_hot_pages_to_move

  def get_l2_hot_pages_lru(self, curr_ep):
    # self.lru_list is ordered from least recently used to most recently used.
    hot_pages = []
    for page_id in reversed(self.lru_list):
      if self.page_list[page_id].loc_ep[curr_ep-1] == 1:
        hot_pages.append(page_id)
        if len(hot_pages) >= self.l1_pages:
          break
    return hot_pages

  def get_l2_hot_pages_lfu(self, curr_ep):
    # LFU promotes by cumulative access_count descending
    hot_page_ids, hot_page_cnts = [], []
    for page in self.page_list:
      if page.access_count > 0:
        hot_page_ids.append(page.id)
        hot_page_cnts.append(page.access_count)
    sorted_idxs = np.argsort(hot_page_cnts)[::-1]
    sorted_hot_page_ids = [hot_page_ids[i] for i in sorted_idxs]

    npages = 0
    page_id = 0
    l2_hot_pages_to_move = []
    while npages < self.l1_pages and npages < len(sorted_hot_page_ids):
      page = self.page_list[sorted_hot_page_ids[page_id]]
      if page.loc_ep[curr_ep-1] == 1:
        l2_hot_pages_to_move.append(page.id)
      npages += 1
      page_id += 1
    return l2_hot_pages_to_move

  def get_l2_hot_pages_decaying_lfu(self, curr_ep):
    hot_page_ids, hot_page_cnts = [], []
    for page in self.page_list:
      if page.smooth_frequency > 0:
        hot_page_ids.append(page.id)
        hot_page_cnts.append(page.smooth_frequency)
    sorted_idxs = np.argsort(hot_page_cnts)[::-1]
    sorted_hot_page_ids = [hot_page_ids[i] for i in sorted_idxs]

    npages = 0
    page_id = 0
    l2_hot_pages_to_move = []
    while npages < self.l1_pages and npages < len(sorted_hot_page_ids):
      page = self.page_list[sorted_hot_page_ids[page_id]]
      if page.loc_ep[curr_ep-1] == 1:
        l2_hot_pages_to_move.append(page.id)
      npages += 1
      page_id += 1
    return l2_hot_pages_to_move

  def get_l2_hot_pages_ml(self, curr_ep):
    slow_candidates = []
    fast_pages = []

    for page in self.page_list:
        if page.loc_ep[curr_ep-1] == 1 and not page.accessed_this_epoch:
            continue
        
        score = score_page_ml(page)
        if page.loc_ep[curr_ep-1] == 1 and page.accessed_this_epoch:
            slow_candidates.append((score, page.id))
        elif page.loc_ep[curr_ep-1] == 0:
            fast_pages.append((score, page.id))

    # Slow descending by score (hottest first)
    slow_candidates.sort(key=lambda x: x[0], reverse=True)
    # Fast ascending by score (coldest first)
    fast_pages.sort(key=lambda x: x[0])

    free_fast_slots = self.l1_pages - len(fast_pages)
    demote_idx = 0
    l2_hot_pages_to_move = []

    for score, page_id in slow_candidates:
        if score < STABLE_ABS_THRESHOLD:
            continue
            
        if free_fast_slots > 0:
            l2_hot_pages_to_move.append(page_id)
            self.page_list[page_id].migration_history += 1
            free_fast_slots -= 1
        elif demote_idx < len(fast_pages):
            cold_score, cold_page_id = fast_pages[demote_idx]
            if score > cold_score + STABLE_DEMOTE_MARGIN:
                l2_hot_pages_to_move.append(page_id)
                self.page_list[page_id].migration_history += 1
                self.page_list[cold_page_id].migration_history += 1
                demote_idx += 1
            else:
                break
        else:
            break

    return l2_hot_pages_to_move
    
  def get_l1_lru_pages(self, curr_ep):
    lru_page_ids = []
    for page_id in self.lru_list:
      page = self.page_list[page_id]
      if page.loc_ep[curr_ep-1] == 0:
        lru_page_ids.append(page.id)
        
    return lru_page_ids
  
  def capacity_check(self, curr_ep):
    l1_pages = 0
    for page in self.page_list:
      if page.loc_ep[curr_ep] == 0:
        l1_pages += 1
    perc = l1_pages / float(self.num_pages)
    if perc > self.l1_ratio:
      print("ERROR: capacity ratio is ", perc, "instead of", self.l1_ratio)

  def get_page_reuse_histogram(self, num_reqs, bucket_size):
    buckets = range(0, num_reqs, bucket_size)
    num_buckets = len(buckets)
    repeats_per_bucket = np.zeros(num_buckets)
    num_pages_per_bucket = np.zeros(num_buckets)
  
    for page in self.page_list:
      heights, bin_edges = np.histogram(page.reuse_dist, bins=buckets)
      for idx in range(num_buckets - 1):
        if heights[idx] > 1:
          repeats_per_bucket[idx] += heights[idx]
          num_pages_per_bucket[idx] += 1
    avg_repeats_per_bucket = []
    for i in range(num_buckets):
      npages = num_pages_per_bucket[i]
      repeat = repeats_per_bucket[i]
      perc = 0
      if npages != 0:
        perc = repeat / npages
      avg_repeats_per_bucket.append(perc)
    dataX, dataY = [], []
    for idx in range(1, num_buckets):  # exclude the first bucket, its intra period reuse
      if avg_repeats_per_bucket[idx] > 2:
        dataX.append(buckets[idx])
        dataY.append(avg_repeats_per_bucket[idx])
    return dataX, dataY

