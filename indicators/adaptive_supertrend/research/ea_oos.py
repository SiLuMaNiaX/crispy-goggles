"""One-time 2026 check of the chosen EA design (confirm exit, hold weekends, hard stop 2 ATR beyond the line),
plus cost stress and Monte Carlo sizing. Args: <ast dir> <hwm dir> <data dir>"""
import sys; sys.path[:0] = [sys.argv[1], sys.argv[2]]; D = sys.argv[3]
import pandas as pd, numpy as np, adst as A, hwm, itertools, warnings; warnings.filterwarnings("ignore")
sys.argv = sys.argv[:1] + sys.argv[1:]
import importlib.util
spec = importlib.util.spec_from_file_location("eam", f"{sys.path[0]}/ea_modes.py")
src = open(f"{sys.path[0]}/ea_modes.py").read().split("df5 = pd.read_pickle")[0]   # reuse sim()/st() only
ns = {}; exec(src, ns); sim, st = ns["sim"], ns["st"]
df5 = pd.read_pickle(f"{D}/xau5.pkl")
rows = []
for tf, f in itertools.product(["20min","30min","45min"], [2.5,3.5,4.5]):
    x = A.compute(hwm.resample_htf(df5, tf), base_f=f)
    tr = sim(x, "confirm", weekend=False, buf=2.0)
    o = tr[tr.entry_t >= "2026-01-01"]
    rows.append(dict(tf=tf, f=f, **{f"oos_{k}": v for k, v in st(o).items()}, all_PF=st(tr)["PF"]))
    if tf == "30min" and f == 3.5: best = (x, tr)
r = pd.DataFrame(rows); print(r.to_string()); print("OOS share PF>1:", (r.oos_PF > 1).mean(), " median OOS PF:", r.oos_PF.median())
x, tr = best
for cost in (0.0, 0.4, 0.8, 1.5):
    print("30m/3.5 cost", cost, st(sim(x, "confirm", cost=cost, weekend=False, buf=2.0)))
R_ = tr.R.values; print("t-stat:", round(R_.mean()/R_.std()*np.sqrt(len(R_)), 2), " exits:", tr.why.value_counts().to_dict())
print("avg hard-stop distance $", round(tr.risk.mean(), 1), " median hold", (tr.exit_t - tr.entry_t).median())
rng = np.random.default_rng(0)
for risk in (0.005, 0.01):
    rets, dds = [], []
    for _ in range(5000):
        s = rng.choice(R_, len(R_)); eq = np.cumprod(1 + risk * s)
        rets.append(eq[-1] - 1); dds.append((1 - eq / np.maximum.accumulate(eq)).max())
    print(f"MC risk {risk:.1%}/trade over {len(R_)} trades (~2.4y): median {np.median(rets):.1%}, P(loss) {np.mean(np.array(rets)<0):.1%}, "
          f"DD median {np.median(dds):.1%}, DD 95% {np.percentile(dds,95):.1%}")
streak = max(len(s) for s in "".join("L" if v < 0 else "W" for v in R_).split("W")); print("longest losing streak:", streak)
