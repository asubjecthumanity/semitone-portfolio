import numpy as np
from proto import load_notes, events

FPS = 100

def activations(notes, T):
    """Per-frame probabilities that a beat / a downbeat starts here, from notes."""
    n = int(T * FPS) + 2
    onset = np.zeros(n); bassw = np.zeros(n)
    for t, w, low, group in events(notes):
        f = int(round(t * FPS))
        if f >= n: continue
        onset[f] += w
        if low < 55:
            dur = max(g[1] - g[0] for g in group if g[2] == low)
            bassw[f] += 1.0 + min(dur, 2.0)
    # harmony change at each frame: pitch-class content 0.5 s after vs before
    starts = np.array([x[0] for x in notes]); ends = np.array([x[1] for x in notes]); pcs = np.array([x[2] % 12 for x in notes])
    harm = np.zeros(n)
    def chroma(a, b):
        ov = np.clip(np.minimum(ends, b) - np.maximum(starts, a), 0, None); v = np.zeros(12); np.add.at(v, pcs, ov); return v
    for f in np.nonzero(onset)[0]:
        t = f / FPS; c0 = chroma(t - 0.5, t); c1 = chroma(t, t + 0.5); d = np.linalg.norm(c0) * np.linalg.norm(c1)
        harm[f] = 1 - (c0 @ c1) / d if d > 0 else 1.0
    def spread(x):   # +-1 frame tolerance
        return np.maximum.reduce([np.roll(x, k) for k in (-1, 0, 1)])
    on = spread(onset); on = np.clip(on / (np.percentile(on[on > 0], 90) if (on > 0).any() else 1), 0, 1)
    down = spread(bassw / (bassw.max() or 1) + harm)
    down = np.clip(down / (np.percentile(down[down > 0], 90) if (down > 0).any() else 1), 0, 1)
    act_beat = 0.5 * on * (1 - 0.7 * down)
    act_down = 0.5 * on * (0.2 + 0.7 * down)
    return np.clip(act_beat, 1e-4, None), np.clip(act_down, 1e-4, None)

def decode(act_beat, act_down, n, min_bpm=55, max_bpm=215, num_tempi=None, trans_lambda=60, obs_lambda=16, prior_bpm=120.0, prior_octaves=1.0, tempo_scale=None):
    """Bar-pointer Viterbi (after Krebs/Böck, madmom). Returns (log-likelihood, beats, downbeats)."""
    # every integer beat interval in range: no gaps, so no accidental answers
    intervals = np.arange(int(np.ceil(60 * FPS / max_bpm)), int(np.floor(60 * FPS / min_bpm)) + 1)
    if tempo_scale is not None:   # user asked for x2 / /2: keep tempi within +-35% of the target
        lo, hi = tempo_scale
        intervals = intervals[(intervals >= lo) & (intervals <= hi)]
    K = len(intervals)
    # flat state layout: tempo k owns n*I_k consecutive states
    offs = np.concatenate([[0], np.cumsum(n * intervals)]); S = offs[-1]
    tempo_of = np.repeat(np.arange(K), n * intervals)
    pos = np.concatenate([np.arange(n * I) for I in intervals])
    I_of = intervals[tempo_of]
    beat_idx = pos // I_of; within = pos % I_of
    is_start = within == 0
    prev = np.arange(S) - 1                                        # deterministic advance
    beat_end = np.array([[offs[k] + (j + 1) * intervals[k] - 1 for j in range(n)] for k in range(K)])  # [K, n]
    beat_start = np.array([[offs[k] + j * intervals[k] for j in range(n)] for k in range(K)])
    # tempo transition log-probs (madmom: exp(-lambda * |ratio - 1|))
    ratio = intervals[None, :] / intervals[:, None]
    logT = -trans_lambda * np.abs(ratio - 1); logT -= np.log(np.exp(logT).sum(1, keepdims=True))
    # gentle perceptual tempo preference, paid once per beat entered
    bpm = 60 * FPS / intervals
    logT = logT - 0.5 * (np.log2(bpm / prior_bpm) / prior_octaves)[None, :] ** 2
    # observation class per state
    region = within < np.maximum(1, I_of // obs_lambda)
    cls = np.where(region & (beat_idx == 0), 2, np.where(region, 1, 0))   # 2 down, 1 beat, 0 none
    Tn = len(act_beat)
    V = np.zeros(S)                                                # uniform prior: any tempo, any point in the bar (as in madmom and BeatTracker.swift)
    choice = np.zeros((Tn, K, n), dtype=np.int16)
    for t in range(Tn):
        a_b, a_d = act_beat[t], act_down[t]
        obs = np.array([np.log(max(1 - a_b - a_d, 1e-4) / (obs_lambda - 1)), np.log(a_b), np.log(a_d)])[cls]
        if t > 0:
            ends = V[beat_end]                                     # [K, n] value at the end of beat j
            # entering beat j at tempo k from the end of beat j-1 at tempo k'
            prev_end = np.roll(ends, 1, axis=1)                    # end of beat j-1 (bar wraps)
            cand = prev_end[:, None, :] + logT[:, :, None]         # [k', k, j]
            best = cand.argmax(0); bestv = cand.max(0)             # [k, j]
            Vn = np.empty(S); Vn[1:] = V[:-1]; Vn[0] = -np.inf
            Vn[beat_start] = bestv
            choice[t] = best
            V = Vn
        V = V + obs
    # backtrack
    s = int(np.argmax(V)); ll = float(V[s]); states = np.empty(Tn, dtype=np.int64)
    for t in range(Tn - 1, -1, -1):
        states[t] = s
        if t == 0: break
        k, j = tempo_of[s], beat_idx[s]
        if is_start[s]:
            kp = choice[t, k, j]; s = beat_end[kp, (j - 1) % n]
        else:
            s = s - 1
    starts = np.nonzero(is_start[states] & np.r_[True, states[1:] != states[:-1]])[0]
    bt = starts / FPS; db = bt[beat_idx[states[starts]] == 0]
    return ll / Tn, bt, db
