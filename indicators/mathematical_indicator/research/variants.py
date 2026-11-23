"""Does the core trigger have an edge when filters are relaxed? 15m (EA execution) and 5m (chart-record scoring, optimistic).
Args: <this dir> <data dir>"""
import sys; sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import pandas as pd, numpy as np, mi, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df = pd.read_pickle(f"{D}/xau5.pkl")
V = {"default": {}, "no clean-zone rule": dict(zone_req=False), "no daily-level block": dict(block_ceil=False),
     "breakout candle up to 100%": dict(max_break=100.0), "1:1 exits": dict(exit_plan="1R"),
     "all 3 filters relaxed": dict(zone_req=False, block_ceil=False, max_break=100.0),
     "relaxed + all sessions": dict(zone_req=False, block_ceil=False, max_break=100.0,
         sessions=tuple((a, b, c, d_, True) for a, b, c, d_, _ in mi.P["sessions"]))}
def st(r):
    r = np.asarray(r)
    if len(r) < 2: return dict(n=len(r))
    gl = -r[r < 0].sum()
    return dict(n=len(r), win=round(100*(r > 0.05).mean()), PF=round(r[r > 0].sum()/gl, 2) if gl else np.inf,
                avgR=round(r.mean(), 3), t=round(r.mean()/r.std()*np.sqrt(len(r)), 2))
def job(a):
    tf, name = a; p = dict(mi.P, **V[name])
    if tf == "15min": tr = mi.run(df, exec="ea", p=p)
    else:  # 5m chart: no finer data, so only the (optimistic) chart-record scoring is possible
        d5 = df.copy(); B = mi.build(d5, tf="5min", p=p); tr = mi.run(d5, exec="pine", p=p, built=B)
    s = st(tr.R_net) if len(tr) else {"n": 0}
    s26 = st(tr[pd.DatetimeIndex(tr.t) >= "2026-01-01"].R_net) if len(tr) else {}
    return dict(tf=tf, variant=name, **s, PF_2026=s26.get("PF"), n_2026=s26.get("n"))
jobs = [(tf, v) for tf in ("15min", "5min") for v in V]
with Pool(4) as pool: r = pd.DataFrame(pool.map(job, jobs))
pd.set_option("display.width", 200); print(r.to_string())
