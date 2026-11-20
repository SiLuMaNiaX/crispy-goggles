import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm, warnings; warnings.filterwarnings("ignore")
df5 = pd.read_pickle(f"{D}/xau5.pkl"); d = hwm.resample_htf(df5, "30min")
full = hwm.compute(d, hwm.resample_htf(d,"3h"))
# 1) windowed computation (EA uses last 2500 closed bars)
rng = np.random.default_rng(3); idx = rng.choice(np.arange(3000, len(d)), 400, replace=False)
sig_idx = np.nonzero(full.sig.values)[0]; idx = np.r_[idx, sig_idx[sig_idx>3000][:400]]
mism = 0
for i in idx:
    w = hwm.compute(d.iloc[i-2499:i+1], hwm.resample_htf(d.iloc[i-2499:i+1],"3h"))
    mism += int(w.sig.values[-1] != full.sig.values[i])
print("windowed vs full-history signal mismatches:", mism, "of", len(idx))
# 2) broker day boundary: build D1 trend on GMT+2-shifted timestamps
def tf_shift(x, hours, n=50):
    y = x[["open","high","low","close"]].copy(); y.index = y.index + pd.Timedelta(hours=hours)
    hh = hwm.resample_htf(y, "1D"); e = hwm.ema(hh.close.values, n); sl = np.sign(np.r_[0,np.diff(e)])
    ix = np.clip(np.searchsorted(hh.index.values, y.index.values, side="right")-2, 0, None); return sl[ix]
for hrs in (0, 2, 3):
    x = full.copy(); x["t4"] = tf_shift(x, hrs); x["s"] = np.where(x.sig==x.t4, x.sig, 0)
    tr = hwm.backtest(x, "s", tp_mode="mid", cost=0.40, max_hold=48)
    print(f"server UTC+{hrs}: ALL {hwm.stats(tr)}  OOS PF {hwm.stats(tr[tr.entry_t>='2026-01-01']).get('PF')}")
