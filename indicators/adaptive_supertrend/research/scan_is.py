"""In-sample scan: adaptive vs plain SuperTrend, by timeframe and by flip grade. Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, hwm, os, warnings; warnings.filterwarnings("ignore")
p = f"{D}/xau5.pkl"
df5 = pd.read_pickle(p) if os.path.exists(p) else hwm.xau_session(hwm.load([f"{D}/a.csv", f"{D}/b.csv"]))
for tf in ("15min", "30min", "1h", "4h"):
    d = hwm.resample_htf(df5, tf)
    for name, adaptive in (("adaptive", True), ("plain", False)):
        x = A.compute(d, adaptive=adaptive); x.to_pickle(f"{D}/ast_{tf}_{name}.pkl")
        tr = A.sar(x[x.index < "2026-01-01"])          # IN-SAMPLE
        print(f"{tf:6} {name:8} ALL {A.stats(tr)}")
        if adaptive:
            for g in "ABC":
                print(f"{'':16} grade {g}: {A.stats(tr[tr.grade == g])}")
            print(f"{'':16} longs {A.stats(tr[tr.side==1])} | shorts {A.stats(tr[tr.side==-1])}")
