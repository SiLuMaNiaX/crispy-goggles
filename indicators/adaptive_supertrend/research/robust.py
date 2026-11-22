"""Neighbourhood check around the 30m result: nearby timeframes and parameters, full period + 2026. Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, hwm, itertools, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df5 = pd.read_pickle(f"{D}/xau5.pkl")
def run(a):
    tf, f, atr_len, conf, adaptive = a
    x = A.compute(hwm.resample_htf(df5, tf), atr_len=atr_len, base_f=f, base_conf=conf, adaptive=adaptive)
    tr = A.sar(x); i = tr[tr.entry_t < "2026-01-01"]; o = tr[tr.entry_t >= "2026-01-01"]
    return dict(tf=tf, f=f, atr=atr_len, conf=conf, ad=adaptive, n=len(tr), PF_all=A.stats(tr).get("PF"),
                PF_is=A.stats(i).get("PF"), PF_oos=A.stats(o).get("PF"), S_is=A.stats(i[i.side==-1]).get("PF"))
grid = list(itertools.product(["20min","30min","45min"], [2.5,3.5,4.5], [10,14,20], [1,2,3], [True, False]))
with Pool(4) as p: r = pd.DataFrame(p.map(run, grid))
r.to_pickle(f"{D}/ast_robust.pkl")
g = r.groupby(["tf","ad"]).agg(configs=("n","size"), PF_all_med=("PF_all","median"), share_PF_all_gt1=("PF_all", lambda v:(v>1).mean()),
        PF_is_med=("PF_is","median"), PF_oos_med=("PF_oos","median"), share_oos_gt1=("PF_oos", lambda v:(v>1).mean()), shorts_is_med=("S_is","median"))
print(g.round(2).to_string())
print("\nDefault-settings rows:"); print(r[(r.f==3.5)&(r.atr==14)&(r.conf==2)].round(2).to_string())
