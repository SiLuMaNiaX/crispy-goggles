"""Spot-check ORB and ST-intraday trades on real days. Args: <this dir> <adst dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = sys.argv[1:4]; D = sys.argv[4]
import pandas as pd, numpy as np, intraday as I, adst, hwm
df = pd.read_pickle(f"{D}/xau5.pkl"); df = df[(df.index >= "2025-06-02") & (df.index < "2025-06-07")]
for s in ("LDN", "NY"):
    tr = I.orb(df, s, 30, "opp", 2.0)
    tr["local"] = tr.t.dt.tz_convert(I.SESS[s][0]).dt.strftime("%a %H:%M"); print(s, "\n", tr[["local","side","entry","stop","risk","pnl","R","why"]].round(2).to_string())
    # recompute the first day's range by hand
    lt = df.index.tz_convert(I.SESS[s][0]); d0 = lt.date[0]
    m = (lt.date == d0) & (lt.hour*60+lt.minute >= I._mins(I.SESS[s][1])) & (lt.hour*60+lt.minute < I._mins(I.SESS[s][1])+30)
    print("  hand-check day1 range:", df.high[m].max(), df.low[m].min(), "bars", m.sum())
x = adst.compute(hwm.resample_htf(pd.read_pickle(f"{D}/xau5.pkl"), "15min"), base_f=3.0, base_conf=1, adaptive=False)
tr = I.st_intraday(x[(x.index >= "2025-06-02") & (x.index < "2025-06-07")])
tr["ny"] = tr.t.dt.tz_convert("America/New_York").dt.strftime("%a %H:%M"); print("ST 15m\n", tr[["ny","side","entry","stop","pnl","R","why"]].round(2).to_string())
