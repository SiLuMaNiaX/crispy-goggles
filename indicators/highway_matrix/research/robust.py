import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm, itertools, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool
df5 = pd.read_pickle(f"{D}/xau5.pkl")
cfg = {"5min":("30min","4h",288), "30min":("3h","1D",48)}
def trend_filter(x, rule, n):
    hh = hwm.resample_htf(x[["open","high","low","close"]], rule); e = hwm.ema(hh.close.values, n)
    sl = np.sign(np.r_[0, np.diff(e)])
    ix = np.clip(np.searchsorted(hh.index.values, x.index.values, side="right") - 2, 0, None)
    return sl[ix]
def run(args):
    tf, bw, m_in, tlen, ex = args
    hw, trr, mh = cfg[tf]
    d = df5 if tf=="5min" else hwm.resample_htf(df5, tf)
    d = d[d.index < "2026-01-01"]                                   # IN-SAMPLE ONLY
    x = hwm.compute(d, hwm.resample_htf(d, hw), bw=bw, m_in=m_in, m_out=2*m_in)
    x["t4"] = trend_filter(x, trr, tlen)
    x["s"] = np.where(x.sig == x.t4, x.sig, 0)
    sl_mode,tp = ("outer","mid") if ex=="mid" else ("outer","opp")
    tr = hwm.backtest(x, "s", sl_mode=sl_mode, sl_buf=0.25, tp_mode=tp, cost=0.40, max_hold=mh)
    out = dict(tf=tf,bw=bw,m_in=m_in,tlen=tlen,ex=ex, **hwm.stats(tr))
    for side,name in ((1,"L"),(-1,"S")):
        out[name+"_PF"] = hwm.stats(tr[tr.side==side]).get("PF"); out[name+"_n"]=int((tr.side==side).sum())
    h1 = tr[tr.entry_t < "2025-03-01"]; h2 = tr[tr.entry_t >= "2025-03-01"]
    out["PF_h1"]=hwm.stats(h1).get("PF"); out["PF_h2"]=hwm.stats(h2).get("PF")
    return out
grid = list(itertools.product(["5min","30min"],[10,20,40],[1.0,1.5,2.0],[20,50,100],["mid","opp"]))
with Pool(8) as p: res = p.map(run, grid)
r = pd.DataFrame(res); r.to_pickle(f"{D}/robust.pkl")
cols=["tf","bw","m_in","tlen","ex","n","win%","PF","sumR","maxDD_R","L_n","L_PF","S_n","S_PF","PF_h1","PF_h2"]
print(r[cols].sort_values(["tf","PF"],ascending=[True,False]).to_string())
for tf in ("5min","30min"):
    q=r[r.tf==tf]; print(tf,"share of 54 configs with PF>1:",(q.PF>1).mean().round(2),
        " median PF",q.PF.median(), " median long PF",q.L_PF.median()," median short PF",q.S_PF.median())
