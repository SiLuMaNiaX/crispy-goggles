import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm
x = pd.read_pickle(f"{D}/x_default.pkl")
df = x[["open","high","low","close"]]
# HTF context (previous completed bar only)
def htf_ctx(rule, n):
    h = hwm.resample_htf(df, rule); e = hwm.ema(h.close.values, n)
    sl = np.r_[0, np.diff(e)]
    idx = np.searchsorted(h.index.values, x.index.values, side="right") - 2
    idx = np.clip(idx, 0, None)
    return e[idx], sl[idx]
x["e1h"], x["s1h"] = htf_ctx("1h", 50)
x["e4h"], x["s4h"] = htf_ctx("4h", 50)
c = x.close.values; o = x.open.values; n=len(x)
cost=0.40
s = x.sig.values
rows=[]
for i in np.nonzero(s)[0]:
    if i < 600 or i+49 >= n: continue
    e = o[i+1]; m = x.mae.values[i]
    for H in (12,48):
        r = (c[i+H] - e) * s[i] - cost
        rows.append((x.index[i], s[i], H, r/m, x.trend.values[i],
                     np.sign(x.s1h.values[i]), np.sign(x.s4h.values[i]),
                     np.sign(c[i]-x.e4h.values[i]), x.index[i].hour, m))
f = pd.DataFrame(rows, columns=["t","side","H","rM","trend","s1h","s4h","p4h","hour","mae"])
f = f[f.t < "2026-01-01"]   # IN-SAMPLE ONLY
def tab(by):
    g = f.groupby(["H"]+by).rM.agg(["count","mean"]); g["t"] = f.groupby(["H"]+by).rM.apply(lambda v: v.mean()/v.std()*np.sqrt(len(v)))
    print(g.round(3).to_string()); print()
f["with4h"] = (f.side == f.s4h).astype(int)       # signal agrees with 4h EMA slope
f["with1h"] = (f.side == f.s1h).astype(int)
f["withp4h"] = (f.side == f.p4h).astype(int)
f["ctrend"] = f.side*f.trend
tab(["side"]); tab(["with1h"]); tab(["with4h"]); tab(["withp4h"]); tab(["ctrend"])
f["sess"] = pd.cut(f.hour,[-1,6,12,16,20,23],labels=["Asia","London","LDN/NY","NY","late"])
tab(["sess"])
f["volq"] = pd.qcut(f.mae/f.groupby(f.t.dt.to_period("M")).mae.transform("median"),3,labels=["lowvol","mid","hivol"])
tab(["volq"])
