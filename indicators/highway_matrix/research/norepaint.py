import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import numpy as np, hwm
df = hwm.xau_session(hwm.load([f"{D}/a.csv", f"{D}/b.csv"]))
df.to_pickle(f"{D}/xau5.pkl")
htf = hwm.resample_htf(df)
full = hwm.compute(df, htf)
print("bars", len(df), "any signals", (full.sig!=0).sum(), "H signals", (full.hsig!=0).sum(),
      "H-buy", (full.hsig==1).sum(), "H-sell", (full.hsig==-1).sum())
rng = np.random.default_rng(1)
for cut in sorted(rng.integers(5000, len(df)-10, 6)):
    sub = df.iloc[:cut]; part = hwm.compute(sub, hwm.resample_htf(sub))
    a = full.iloc[:cut]
    same = all(np.array_equal(a[k].values, part[k].values) for k in ("sig","hsig","trend"))
    md = np.nanmax(np.abs(a.mid.values - part.mid.values))
    print(cut, "signals identical:", same, "max |mid diff|", md)
