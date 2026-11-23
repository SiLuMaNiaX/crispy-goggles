"""Full-period run, default settings, gold 15m: chart record (pine) vs realistic EA execution. Args: <this dir> <data dir>"""
import sys; sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import pandas as pd, numpy as np, mi, warnings; warnings.filterwarnings("ignore")
df = pd.read_pickle(f"{D}/xau5.pkl"); B = mi.build(df)
def st(r):
    r = np.asarray(r); 
    if len(r) < 2: return dict(n=len(r))
    gl = -r[r < 0].sum(); eq = np.cumsum(r)
    return dict(n=len(r), win=round(100*(r > 0.05).mean()), PF=round(r[r > 0].sum()/gl, 2) if gl else np.inf, avgR=round(r.mean(), 3),
                sumR=round(r.sum(), 1), ddR=round((np.maximum.accumulate(eq)-eq).max(), 1), t=round(r.mean()/r.std()*np.sqrt(len(r)), 2))
for ex in ("pine", "ea"):
    d = {}; tr = mi.run(df, exec=ex, built=B, diag=d); tr.to_csv(f"{D}/mi_trades_{ex}.csv", index=False)
    print(f"== {ex}: funnel", {k: v for k, v in d.items() if k.startswith(('✓','✕'))})
    print("   chart-record style (no costs):", st(tr.R)); print("   with costs:", st(tr.R_net))
    print("   by year (net R):", tr.groupby(pd.DatetimeIndex(tr.t).year).R_net.agg(['count','sum']).round(1).to_dict('index'))
    print("   by session (net):", {s: st(g.R_net) for s, g in tr.groupby('sess')})
    print("   exits:", tr.why.value_counts().to_dict(), " avg risk $", round(tr.risk.mean(), 2))
