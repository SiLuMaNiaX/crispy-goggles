"""In-sample grid (2024-06..2025-12). Args: <this dir> <adst dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = sys.argv[1:4]; D = sys.argv[4]
import pandas as pd, numpy as np, itertools, intraday as I, adst, hwm, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df = pd.read_pickle(f"{D}/xau5.pkl"); IS = df[df.index < "2026-01-01"]
def half(tr):  # consistency: PF in each half of the in-sample period
    a = tr[tr.t < "2025-03-01"]; b = tr[tr.t >= "2025-03-01"]
    return I.stats(a).get("PF"), I.stats(b).get("PF")
def run_orb(a):
    s, rm, st, tg = a; tr = I.orb(IS, s, rm, st, tg)
    h1, h2 = half(tr); return dict(fam="ORB", sess=s, range=rm, stop=st, tgt=tg or "EOD", **I.stats(tr), PF_h1=h1, PF_h2=h2)
def run_st(a):
    tf, f, cf, sa, w = a
    x = adst.compute(hwm.resample_htf(IS, tf), base_f=f, base_conf=cf, adaptive=False)
    tr = I.st_intraday(x, w, sa); h1, h2 = half(tr)
    return dict(fam="ST", tf=tf, f=f, conf=cf, stopATR=sa, win_=w, **I.stats(tr), PF_h1=h1, PF_h2=h2)
g1 = list(itertools.product(["LDN","COMEX","NY"], [15,30,60], ["opp","mid"], [1.0, 2.0, None]))
g2 = list(itertools.product(["5min","15min","30min"], [2.0,3.0,4.0], [1,2], [1.0,2.0], ["LDN+NY","NY"]))
with Pool(4) as p: r1 = pd.DataFrame(p.map(run_orb, g1)); r2 = pd.DataFrame(p.map(run_st, g2))
r1.to_pickle(f"{D}/grid_orb.pkl"); r2.to_pickle(f"{D}/grid_st.pkl")
pd.set_option("display.width", 250)
print("=== ORB: median by session / range ===")
print(r1.groupby(["sess","range"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean()), n=("n","median"), avgR=("avgR","median")).round(2).to_string())
print(r1.groupby(["stop","tgt"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean())).round(2).to_string())
print("top ORB:\n", r1.sort_values("PF", ascending=False).head(8).to_string())
print("\n=== SuperTrend intraday: median by TF / window ===")
print(r2.groupby(["tf","win_"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean()), n=("n","median"), avgR=("avgR","median")).round(2).to_string())
print(r2.groupby(["tf","f"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean())).round(2).to_string())
print("top ST:\n", r2.sort_values("PF", ascending=False).head(8).to_string())
