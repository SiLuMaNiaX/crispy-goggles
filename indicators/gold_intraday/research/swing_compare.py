"""Swing SuperTrend EA logic (holds overnight) on the same clean/2026 windows, for comparison. Args: <this> <adst> <hwm> <data>"""
import sys; sys.path[:0] = sys.argv[1:4]; D = sys.argv[4]
import pandas as pd, numpy as np, itertools, adst, hwm, intraday as I, warnings; warnings.filterwarnings("ignore")
src = open(f"{sys.argv[2]}/ea_modes.py").read().split("df5 = pd.read_pickle")[0]; ns = {}; exec(src, ns); sim = ns["sim"]
df = pd.read_pickle(f"{D}/xau5.pkl"); rows = []
for tf, f in itertools.product(["20min","30min","45min"], [2.5,3.5,4.5]):
    x = adst.compute(hwm.resample_htf(df, tf), base_f=f)
    tr = sim(x, "confirm", weekend=False, buf=2.0).rename(columns={"entry_t": "t"})
    c = I.stats(tr[(tr.t >= "2025-03-01") & (tr.t < "2026-01-01")]); o = I.stats(tr[tr.t >= "2026-01-01"])
    rows.append(dict(tf=tf, f=f, n_c=c["n"], PF_c=c["PF"], n_o=o["n"], PF_o=o["PF"], t_o=o["t"]))
r = pd.DataFrame(rows); print(r.to_string())
print("swing ST: clean PF median", r.PF_c.median(), "| 2026 PF median", r.PF_o.median(), "| both>1:", ((r.PF_c>1)&(r.PF_o>1)).mean())
