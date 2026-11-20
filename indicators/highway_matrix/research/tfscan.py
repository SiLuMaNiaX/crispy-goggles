import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm, itertools, warnings; warnings.filterwarnings("ignore")
df5 = pd.read_pickle(f"{D}/xau5.pkl")
def trend_filter(x, rule, n=50):
    hh = hwm.resample_htf(x[["open","high","low","close"]], rule); e = hwm.ema(hh.close.values, n)
    sl = np.sign(np.r_[0, np.diff(e)])
    ix = np.clip(np.searchsorted(hh.index.values, x.index.values, side="right") - 2, 0, None)
    return sl[ix]
cfg = {"5min":("30min","4h"), "15min":("2h","12h"), "30min":("3h","1D"), "1h":("6h","1D")}
res = []
for tf,(hw,tr) in cfg.items():
    d = df5 if tf=="5min" else hwm.resample_htf(df5, tf)
    x = hwm.compute(d, hwm.resample_htf(d, hw))
    x["t4"] = trend_filter(x, tr)
    x["sig_tf"] = np.where(x.sig == x.t4, x.sig, 0)          # fade only in direction of HTF slope (pullback entries)
    x.to_pickle(f"{D}/x_{tf}.pkl")
    xi = x[x.index < "2026-01-01"]
    for col, (sl_mode, sl_buf, tp_mode, rr) in itertools.product(["sig","hsig","sig_tf"],
            [("outer",0.25,"mid",0),("outer",0.25,"opp",0),("outer",0.25,"rr",1.0),("atr",2.0,"rr",1.0),("atr",2.0,"rr",2.0)]):
        tr_ = hwm.backtest(xi, col, sl_mode=sl_mode, sl_buf=sl_buf, tp_mode=tp_mode, rr=rr, cost=0.40,
                           max_hold=int(24*60/int(pd.Timedelta(tf).total_seconds()/60)), warmup=600)
        st = hwm.stats(tr_)
        res.append(dict(tf=tf, sig=col, exit=f"{sl_mode}{sl_buf}/{tp_mode}{rr or ''}", **st))
r = pd.DataFrame(res); print(r.to_string())
