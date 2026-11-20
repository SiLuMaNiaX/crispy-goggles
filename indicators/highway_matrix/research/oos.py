import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm, warnings; warnings.filterwarnings("ignore")
df5 = pd.read_pickle(f"{D}/xau5.pkl")
def trend_filter(x, rule, n):
    hh = hwm.resample_htf(x[["open","high","low","close"]], rule); e = hwm.ema(hh.close.values, n)
    sl = np.sign(np.r_[0, np.diff(e)]); ix = np.clip(np.searchsorted(hh.index.values, x.index.values, side="right") - 2, 0, None)
    return sl[ix]
d = hwm.resample_htf(df5, "30min")
print("OOS buy&hold 2026:", round(d.close[d.index>="2026-01-01"].iloc[-1]/d.close[d.index>="2026-01-01"].iloc[0]-1,3))
for bw,m_in,tlen,ex in [(20,1.5,50,"mid"),(20,1.5,100,"mid"),(20,1.0,100,"mid"),(20,1.5,50,"opp"),(10,1.5,100,"mid")]:
    x = hwm.compute(d, hwm.resample_htf(d,"3h"), bw=bw, m_in=m_in, m_out=2*m_in)   # computed on full history, causal
    x["t4"] = trend_filter(x,"1D",tlen); x["s"] = np.where(x.sig==x.t4, x.sig, 0)
    for col in ("s","hsig"):
        tr = hwm.backtest(x, col, sl_mode="outer", sl_buf=0.25, tp_mode=ex, cost=0.40, max_hold=48)
        o = tr[tr.entry_t >= "2026-01-01"]
        print(f"bw={bw} m_in={m_in} tlen={tlen} {ex} {col:4}: OOS {hwm.stats(o)} L {hwm.stats(o[o.side==1]).get('PF')} S {hwm.stats(o[o.side==-1]).get('PF')}")
