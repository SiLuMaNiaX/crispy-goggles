"""Every family re-scored on clean data (2025-03..2025-12, $0.01 ticks) and, once, on 2026 (OOS).
Indicators are computed on the full history (causal) and trades are bucketed by entry date. Args: <this> <adst> <hwm> <data>"""
import sys; sys.path[:0] = sys.argv[1:4]; D = sys.argv[4]
import pandas as pd, numpy as np, itertools, intraday as I, adst, hwm, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df = pd.read_pickle(f"{D}/xau5.pkl")
def split(tr): 
    c = tr[(tr.t >= "2025-03-01") & (tr.t < "2026-01-01")]; o = tr[tr.t >= "2026-01-01"]
    return I.stats(c), I.stats(o)
def pack(fam, key, tr):
    c, o = split(tr); return dict(fam=fam, cfg=key, n_c=c.get("n"), PF_c=c.get("PF"), n_o=o.get("n"), PF_o=o.get("PF"), t_o=o.get("t"))
def job(a):
    kind = a[0]
    if kind == "ORB":  return pack("ORB breakout", a[1:], I.orb(df, *a[1:]))
    if kind == "FADE": return pack("ORB fade", a[1:], I.orb_fade(df, *a[1:]))
    tf, f, cf, sa, flt = a[1:]
    x = adst.compute(hwm.resample_htf(df, tf), base_f=f, base_conf=cf, adaptive=False)
    trend = None if flt == "none" else I.htf_trend(x, df, flt, adst, hwm)
    fam = ("Scalp " if tf == "5min" else "Intraday ") + "ST" + ("" if flt == "none" else "+trend")
    return pack(fam, a[1:], I.st_intraday(x, "LDN+NY", sa, trend=trend))
jobs  = [("ORB",)  + g for g in itertools.product(["LDN","COMEX","NY"], [15,30,60], ["opp","mid"], [1.0, 2.0, None])]
jobs += [("FADE",) + g for g in itertools.product(["LDN","COMEX","NY"], [15,30,60], [0.5,1.0], ["mid","opp"])]
jobs += [("ST",)   + g for g in itertools.product(["5min","15min","30min"], [2.0,3.0,4.0], [1,2], [1.0,2.0], ["none","ST4H","EMA1D"])]
with Pool(4) as p: r = pd.DataFrame(p.map(job, jobs))
r.to_pickle(f"{D}/clean_oos.pkl"); pd.set_option("display.width", 250)
g = r.groupby("fam").agg(configs=("cfg","size"), trades_clean=("n_c","median"), PF_clean_med=("PF_c","median"),
      share_clean_gt1=("PF_c", lambda v:(v>1).mean()), trades_2026=("n_o","median"), PF_2026_med=("PF_o","median"),
      share_2026_gt1=("PF_o", lambda v:(v>1).mean()), both_gt1=("PF_c", lambda v: ((v>1) & (r.loc[v.index,"PF_o"]>1)).mean()))
print(g.round(2).sort_values("PF_2026_med", ascending=False).to_string())
q = r[r.fam.str.startswith("Intraday")].copy(); q["tf"] = q.cfg.str[0]; q["f"] = q.cfg.str[1]
print("\nIntraday ST by timeframe/factor:\n", q.groupby(["tf","f"]).agg(PF_clean=("PF_c","median"), PF_2026=("PF_o","median"), both=("PF_c", lambda v: ((v>1)&(q.loc[v.index,"PF_o"]>1)).mean())).round(2).to_string())
