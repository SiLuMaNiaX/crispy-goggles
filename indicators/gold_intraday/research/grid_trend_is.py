"""In-sample grid: intraday SuperTrend entries aligned with a higher-timeframe trend. Args: <this dir> <adst dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = sys.argv[1:4]; D = sys.argv[4]
import pandas as pd, numpy as np, itertools, intraday as I, adst, hwm, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df = pd.read_pickle(f"{D}/xau5.pkl"); IS = df[df.index < "2026-01-01"]
def run(a):
    tf, f, cf, sa, flt = a
    x = adst.compute(hwm.resample_htf(IS, tf), base_f=f, base_conf=cf, adaptive=False)
    tr = I.st_intraday(x, "LDN+NY", sa, trend=I.htf_trend(x, IS, flt, adst, hwm))
    return dict(tf=tf, f=f, conf=cf, stopATR=sa, filt=flt, **I.stats(tr),
                PF_h1=I.stats(tr[tr.t < "2025-03-01"]).get("PF"), PF_h2=I.stats(tr[tr.t >= "2025-03-01"]).get("PF"),
                L=I.stats(tr[tr.side==1]).get("PF"), S=I.stats(tr[tr.side==-1]).get("PF"))
g = list(itertools.product(["5min","15min","30min"], [2.0,3.0,4.0], [1,2], [1.0,2.0], ["ST4H","EMA1D"]))
with Pool(4) as p: r = pd.DataFrame(p.map(run, g))
r.to_pickle(f"{D}/grid_trend.pkl"); pd.set_option("display.width", 250)
print(r.groupby(["tf","filt"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean()), n=("n","median"),
      h1=("PF_h1","median"), h2=("PF_h2","median"), L=("L","median"), S=("S","median")).round(2).to_string())
print(r.groupby(["tf","f"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean())).round(2).to_string())
print(r.sort_values("PF", ascending=False).head(10).to_string())
