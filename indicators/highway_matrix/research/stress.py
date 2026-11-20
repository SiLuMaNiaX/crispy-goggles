import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm, warnings; warnings.filterwarnings("ignore")
df5 = pd.read_pickle(f"{D}/xau5.pkl")
d = hwm.resample_htf(df5, "30min")
def trend_filter(x, rule, n):
    hh = hwm.resample_htf(x[["open","high","low","close"]], rule); e = hwm.ema(hh.close.values, n)
    sl = np.sign(np.r_[0, np.diff(e)]); ix = np.clip(np.searchsorted(hh.index.values, x.index.values, side="right") - 2, 0, None)
    return sl[ix]
x = hwm.compute(d, hwm.resample_htf(d,"3h")); x["t4"] = trend_filter(x,"1D",50); x["s"]=np.where(x.sig==x.t4,x.sig,0)
for cost in (0.0,0.2,0.4,0.6,0.8,1.0):
    tr = hwm.backtest(x,"s",tp_mode="mid",cost=cost,max_hold=48)
    print("cost",cost, hwm.stats(tr), "OOS", hwm.stats(tr[tr.entry_t>="2026-01-01"]).get("PF"))
tr = hwm.backtest(x,"s",tp_mode="mid",cost=0.40,max_hold=48); tr.to_csv(f"{D}/final_trades.csv",index=False)
R=tr.R.values; print("t-stat all:", round(R.mean()/R.std()*np.sqrt(len(R)),2), " avg risk $", round(tr.risk.mean(),2), " exits:", tr.why.value_counts().to_dict())
print(tr.groupby(tr.entry_t.dt.to_period("Q")).R.agg(["count","sum"]).round(2).T.to_string())
# Monte Carlo: bootstrap trade sequence, 0.5% risk per trade
rng=np.random.default_rng(0); dds=[]; rets=[]
for _ in range(5000):
    r=rng.choice(R,len(R),replace=True); eq=np.cumprod(1+0.005*r); dds.append((1-eq/np.maximum.accumulate(eq)).max()); rets.append(eq[-1]-1)
print("MC @0.5% risk: median return", round(np.median(rets),3), " P(loss)", round(np.mean(np.array(rets)<0),3),
      " DD median", round(np.median(dds),3), " DD 95%", round(np.percentile(dds,95),3))
# walk-forward-ish: rolling 6-month windows
for a,b in [("2024-07","2024-12"),("2025-01","2025-06"),("2025-07","2025-12"),("2026-01","2026-06"),("2026-07","2026-11")]:
    w=tr[(tr.entry_t>=a)&(tr.entry_t<pd.Period(b).end_time.tz_localize("UTC"))]; print(a,b,hwm.stats(w))
