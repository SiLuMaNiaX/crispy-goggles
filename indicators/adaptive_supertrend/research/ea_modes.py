"""EA design test: how to exit. R = distance from entry to the hard (emergency) stop at entry (what the EA sizes on).
Modes:
  confirm : hold until the next confirmed flip (stop-and-reverse); emergency stop = line - buf*ATR at entry
  trail   : server stop trails the line (intrabar); after a stop-out wait for the next confirmed flip
  close   : exit at the next open after a bar CLOSES through the line (raw flip), no confirmation wait
Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, hwm, itertools, warnings; warnings.filterwarnings("ignore")
from multiprocessing import Pool

def sim(x, mode, cost=0.40, weekend=True, buf=1.0, warmup=100):
    o, h, l, c = (x[k].to_numpy() for k in ("open","high","low","close"))
    fl, raw, line, atr = x.flip.to_numpy(), x.raw.to_numpy(), x.line.to_numpy(), x.atr.to_numpy()
    t = x.index; n = len(c)
    gap = np.r_[(t[1:] - t[:-1]) > pd.Timedelta(hours=6), False]
    out = []; pos = 0
    def close_tr(px, tt, why):
        nonlocal pos
        out.append((e_t, tt, pos, e, px, risk, ((px - e) * pos - cost) / risk, why)); pos = 0
    i = warmup
    while i < n - 1:
        if pos != 0:
            # intrabar stop for bar i (stop level known at the bar's open)
            stp = line[i-1] if mode == "trail" and raw[i-1] == pos else emerg
            if mode == "trail" and raw[i-1] == pos:
                stp = max(stp, emerg) if pos == 1 else min(stp, emerg)
            hit = (l[i] <= stp) if pos == 1 else (h[i] >= stp)
            if hit:
                px = min(o[i], stp) if pos == 1 else max(o[i], stp)   # gap through stop fills at open
                close_tr(px, t[i], "stop")
            elif weekend and gap[i]:
                close_tr(c[i], t[i], "weekend")
            elif mode == "close" and raw[i] != pos:
                close_tr(o[i+1], t[i+1], "close-through")
        if fl[i] != 0:
            if pos != 0 and pos != fl[i]:
                close_tr(o[i+1], t[i+1], "flip")
            if pos == 0:
                pos = fl[i]; e = o[i+1]; e_t = t[i+1]
                emerg = line[i] - buf*atr[i] if pos == 1 else line[i] + buf*atr[i]
                risk = abs(e - emerg)          # EA sizes on the real hard-stop distance
                if risk <= 0 or (pos == 1 and emerg >= e) or (pos == -1 and emerg <= e):
                    pos = 0
        i += 1
    return pd.DataFrame(out, columns=["entry_t","exit_t","side","entry","exit","risk","R","why"])

def st(tr):
    if len(tr) == 0: return {}
    r = tr.R.values; eq = np.cumsum(r); gl = -r[r<0].sum()
    return dict(n=len(r), win=round((r>0).mean()*100,1), PF=round(r[r>0].sum()/gl,2), avgR=round(r.mean(),3),
                sumR=round(r.sum(),1), ddR=round((np.maximum.accumulate(eq)-eq).max(),1), worstR=round(r.min(),2))

df5 = pd.read_pickle(f"{D}/xau5.pkl")
cache = {}
def run(a):
    tf, f, mode, wk, buf = a
    x = A.compute(hwm.resample_htf(df5, tf), base_f=f)
    tr = sim(x[x.index < "2026-01-01"], mode, weekend=wk, buf=buf)   # IN-SAMPLE ONLY
    return dict(tf=tf, f=f, mode=mode, weekend=wk, buf=buf, **st(tr))
grid = list(itertools.product(["20min","30min","45min"], [2.5,3.5,4.5], ["confirm","trail","close"], [True, False], [0.5, 1.0, 2.0]))
with Pool(4) as p: r = pd.DataFrame(p.map(run, grid))
r.to_pickle(f"{D}/ea_modes_is.pkl")
print(r.groupby(["mode","weekend","buf"]).agg(PF_med=("PF","median"), share_gt1=("PF", lambda v:(v>1).mean()), avgR=("avgR","median"), ddR=("ddR","median"), worstR=("worstR","min")).round(2).to_string())
