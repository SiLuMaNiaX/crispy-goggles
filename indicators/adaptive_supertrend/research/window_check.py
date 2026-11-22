"""Does computing on the last N closed bars (as the EA does) reproduce full-history flips? Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, hwm
d = hwm.resample_htf(pd.read_pickle(f"{D}/xau5.pkl"), "30min")
full = A.compute(d)
rng = np.random.default_rng(5)
flips = np.nonzero(full.flip.values)[0]
for N in (500, 1000, 3000):
    idx = np.r_[rng.choice(np.arange(N, len(d)), 300, replace=False), flips[flips >= N][:300]]
    bad = 0
    for i in idx:
        w = A.compute(d.iloc[i-N+1:i+1])
        bad += int(w.flip.values[-1] != full.flip.values[i] or w.conf.values[-1] != full.conf.values[i]
                   or abs(w.line.values[-1] - full.line.values[i]) > 1e-9)
    print(f"window {N}: mismatches {bad} of {len(idx)}")
