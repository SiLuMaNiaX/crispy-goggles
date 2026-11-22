"""Single out-of-sample look (2026) at pre-chosen candidates. Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, warnings; warnings.filterwarnings("ignore")
for tf in ("30min", "1h", "4h"):
    for name in ("adaptive", "plain"):
        x = pd.read_pickle(f"{D}/ast_{tf}_{name}.pkl")
        for label, g in (("all grades", ("A","B","C")), ("grade A only", ("A",))):
            if name == "plain" and label != "all grades": continue
            tr = A.sar(x, grades=g); o = tr[tr.entry_t >= "2026-01-01"]
            print(f"{tf:5} {name:8} {label:12} OOS {A.stats(o)}  L {A.stats(o[o.side==1]).get('PF')}  S {A.stats(o[o.side==-1]).get('PF')}")
x = pd.read_pickle(f"{D}/ast_1h_plain.pkl"); y = x[x.index >= "2026-01-01"]
print("buy & hold 2026:", round(y.close.iloc[-1] / y.close.iloc[0] - 1, 3))
