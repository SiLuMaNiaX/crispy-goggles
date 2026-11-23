"""Smoke test: both execution models on Jun-Aug 2025. Args: <this dir> <data dir>"""
import sys, time; sys.path.insert(0, sys.argv[1]); D = sys.argv[2]
import pandas as pd, numpy as np, mi, warnings; warnings.filterwarnings("ignore")
df = pd.read_pickle(f"{D}/xau5.pkl"); df = df[(df.index >= "2025-05-01") & (df.index < "2025-09-01")]
t0 = time.time(); B = mi.build(df); print("build s", round(time.time() - t0, 1), "chart bars", len(B[1]))
for ex in ("pine", "ea"):
    t0 = time.time(); tr = mi.run(df, exec=ex, built=B)
    print(f"\n{ex}: {len(tr)} trades in {time.time()-t0:.1f}s  sumR={tr.R.sum():.1f}  netR={tr.R_net.sum():.1f}  win%={(tr.R>0.05).mean()*100:.0f}")
    tr["ny"] = pd.DatetimeIndex(tr.t).tz_convert("America/New_York").strftime("%m-%d %H:%M")
    print(tr[["ny","sess","side","entry","stop0","risk","tgt","R","R_net","why","part"]].head(12).round(2).to_string())
