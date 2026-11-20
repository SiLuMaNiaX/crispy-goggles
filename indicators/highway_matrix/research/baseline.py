import sys; sys.path.insert(0, sys.argv[1]); D=sys.argv[2]
import pandas as pd, numpy as np, hwm
df = pd.read_pickle(f"{D}/xau5.pkl"); htf = hwm.resample_htf(df)
x = hwm.compute(df, htf); x.to_pickle(f"{D}/x_default.pkl")
IS = x.index < "2026-01-01"
print("median MAE $", round(np.median(x.mae[600:]),2), " median price", round(x.close.median()))
for col in ("hsig","sig"):
  for sl_mode,sl_buf,tp_mode,rr in [("outer",0.25,"mid",0),("outer",0.25,"rr",1.0),("outer",0.25,"rr",2.0),("atr",1.5,"rr",1.5),("outer",0.25,"opp",0)]:
    for cost in (0.0,0.40):
        tr = hwm.backtest(x, col, sl_mode=sl_mode, sl_buf=sl_buf, tp_mode=tp_mode, rr=rr, cost=cost)
        tis = tr[tr.entry_t < "2026-01-01"]; tos = tr[tr.entry_t >= "2026-01-01"]
        print(f"{col:4} sl={sl_mode}/{sl_buf} tp={tp_mode}{rr or ''} cost={cost}: ALL {hwm.stats(tr)}  | OOS {hwm.stats(tos)}")
