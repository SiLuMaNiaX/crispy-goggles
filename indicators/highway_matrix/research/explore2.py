import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm
x = pd.read_pickle(f"{D}/x_default.pkl")
x = x[x.index < "2026-01-01"].copy()   # IN-SAMPLE ONLY
c,o,h,l = (x[k].values for k in ("close","open","high","low")); m=x.mae.values; n=len(x)
def fwd(idx, side, H):
    idx = idx[(idx>600)&(idx+H<n)]
    r = (c[idx+H]-o[idx+1])*side[idx] if np.ndim(side) else (c[idx+H]-o[idx+1])*side
    r = r/m[idx]; return len(r), r.mean(), r.mean()/r.std()*np.sqrt(len(r))
allidx=np.arange(n)
for H in (12,48):
    print(H, "unconditional long drift (MAE units, gross):", np.round(fwd(allidx,1,H),3))
# 4h trend
hh = hwm.resample_htf(x[["open","high","low","close"]],"4h"); e=hwm.ema(hh.close.values,50); sl=np.sign(np.r_[0,np.diff(e)])
ix=np.clip(np.searchsorted(hh.index.values,x.index.values,side="right")-2,0,None); t4=sl[ix]
print("share of time 4h-up:", (t4>0).mean().round(3))
for H in (12,48):
    print(H,"long when 4h up:",np.round(fwd(np.nonzero(t4>0)[0],1,H),3),"short when 4h dn:",np.round(fwd(np.nonzero(t4<0)[0],-1,H),3))
# breakouts: close beyond outer / inner band (first bar)
for band in ("upI","upO"):
    lob = "loI" if band=="upI" else "loO"
    up = (c > x[band].values) & (np.r_[True, c[:-1] <= x[band].values[:-1]])
    dn = (c < x[lob].values) & (np.r_[True, c[:-1] >= x[lob].values[:-1]])
    for H in (12,48):
        print(band,H,"breakout long",np.round(fwd(np.nonzero(up)[0],1,H),3),"breakout short",np.round(fwd(np.nonzero(dn)[0],-1,H),3),
              "| with 4h: L",np.round(fwd(np.nonzero(up&(t4>0))[0],1,H),3),"S",np.round(fwd(np.nonzero(dn&(t4<0))[0],-1,H),3))
