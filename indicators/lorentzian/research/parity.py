"""Compare lc.py against TradingView export CSVs (Prediction, Direction, Buy, Sell, kernel, features).
Args: <lc.py dir> <baselines dir>"""
import sys, csv, json; sys.path.insert(0, sys.argv[1]); B = sys.argv[2]
import numpy as np, lc
man = json.load(open(f"{B}/baselines_manifest.json"))
for fx in man["fixtures"]:
    rows = list(csv.DictReader(open(f"{B}/{fx['filename']}")))
    dec = max((len(r[k].split(".")[1].rstrip("0")) if "." in r[k] else 0) for r in rows for k in ("open","high","low","close"))
    scale = float(10 ** min(dec, 18)) if dec else 0.0
    col = lambda k: np.array([float(r[k]) if r[k] != "" else np.nan for r in rows])
    out = lc.compute(col("open"), col("high"), col("low"), col("close"), price_scale=scale,
                     include_full_history=fx["settings"]["include_full_history"])
    n = len(rows); res = {}
    res["prediction"] = int((out["prediction"] != col("Prediction")).sum())
    res["direction"] = int((out["direction"] != col("Direction")).sum())
    res["buy"] = int((out["buy"] != ~np.isnan(col("Buy"))).sum())   # Buy column holds a price or 1 when set
    res["sell"] = int((out["sell"] != ~np.isnan(col("Sell"))).sum())
    k = col("Kernel Regression Estimate"); m = ~np.isnan(k)
    res["kernel_maxrel"] = float(np.nanmax(np.abs(out["kernel"][m] - k[m]) / np.abs(k[m]))) if m.any() else None
    for j, name in enumerate(["F1_RSI","F2_WT","F3_CCI","F4_ADX","F5_RSI9"]):
        f = col(name); mm = ~np.isnan(f) & ~np.isnan(out["F"][j])
        res[name] = float(np.abs(out["F"][j][mm] - f[mm]).max()) if mm.any() else "n/a"
    print(f"{fx['filename']:45} bars={n} buys={int((~np.isnan(col('Buy'))).sum())} sells={int((~np.isnan(col('Sell'))).sum())} mismatches: {res}")
