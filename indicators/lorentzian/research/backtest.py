"""Backtest the indicator's own trades (Buy/Sell labels, default 4-bar strict exits) like a chart user would see them.
Charts are 'loaded' at successive end points T, each evaluating its last 2000 bars (the only bars that get predictions),
so every bar is scored exactly once and no future prices are used. Args: <lc dir> <hwm dir> <baselines dir> <data dir>"""
import sys, csv; sys.path[:0] = [sys.argv[1], sys.argv[2]]; B, D = sys.argv[3], sys.argv[4]
import numpy as np, pandas as pd, lc, hwm, warnings; warnings.filterwarnings("ignore")

def load_csv(name):
    rows = list(csv.DictReader(open(f"{B}/{name}")))
    df = pd.DataFrame({k: [float(r[k]) for r in rows] for k in ("open","high","low","close")})
    df.index = pd.to_datetime([int(r["time"]) for r in rows], unit="s", utc=True); return df

def trades_for(df, scale, cost_frac, mbb=2000):
    o, h, l, c = (df[k].to_numpy() for k in ("open","high","low","close")); n = len(c)
    out = []
    ends = list(range(n - 1, mbb - 1, -mbb))[::-1] if n > mbb else [n - 1]
    for T in ends:
        r = lc.compute(o[:T+1], h[:T+1], l[:T+1], c[:T+1], price_scale=scale, max_bars_back=mbb)
        lo = r["mbbi"] + 1
        for side, ent, ex in ((1, r["buy"], r["end_long"]), (-1, r["sell"], r["end_short"])):
            for i in np.nonzero(ent)[0]:
                if i < lo or i + 1 > T: continue
                js = np.nonzero(ex[i+1:])[0]
                j = i + 1 + js[0] if len(js) else T
                ep = o[i+1]; xp = o[j+1] if j + 1 <= T else c[T]
                mp = lambda k: (h[k] + l[k] + o[k] + o[k]) / 4          # price the stats panel uses
                out.append(dict(t=df.index[i+1], side=side, ret=side*(xp-ep)/ep - cost_frac,
                                panel_win=side*(mp(j)-mp(i)) > 0, panel_loss=side*(mp(j)-mp(i)) < 0, bars=j-i))
    return pd.DataFrame(out).sort_values("t")

def summarize(name, tr, df):
    r = tr.ret.to_numpy(); gl = -r[r<0].sum()
    wl = tr.panel_win.sum() / max(tr.panel_loss.sum(), 1)
    bh = df.close.iloc[-1] / df.close.iloc[0] - 1
    # benchmark: same entries/holding periods, random direction (1000 draws)
    rng = np.random.default_rng(0); rand = []
    for _ in range(1000):
        s = rng.choice([-1, 1], len(r)); rand.append(((r + (cost_frac_of[name])) * tr.side.to_numpy() * s - cost_frac_of[name]).sum())
    pct = (np.array(rand) < r.sum()).mean()
    print(f"{name:22} trades={len(r):4} | PANEL-STYLE W/L ratio={wl:.2f} | REAL: win%={100*(r>0).mean():.0f} PF={r[r>0].sum()/gl:.2f} "
          f"avg={100*r.mean():+.3f}% total={100*r.sum():+.1f}% t={r.mean()/r.std()*np.sqrt(len(r)):+.2f} "
          f"| longs {100*r[tr.side==1].sum():+.1f}% shorts {100*r[tr.side==-1].sum():+.1f}% | beats random-direction {pct:.0%} | buy&hold {100*bh:+.0f}%")

cost_frac_of = {}
xau = pd.read_pickle(f"{D}/xau5.pkl")
sets = [("EURUSD 1D (oanda)", load_csv("pine_oanda_eurusd_1d_full_history.csv"), 1e5, 0.00008),
        ("BTCUSD 1D (coinbase)", load_csv("pine_coinbase_btcusd_1d_limited_history.csv"), 100.0, 0.001),
        ("Gold 4H (PAXG)", hwm.resample_htf(xau, "4h"), 100.0, 0.40/3000),
        ("Gold 1H (PAXG)", hwm.resample_htf(xau, "1h"), 100.0, 0.40/3000),
        ("Gold 30m (PAXG)", hwm.resample_htf(xau, "30min"), 100.0, 0.40/3000)]
for name, df, scale, cost in sets:
    cost_frac_of[name] = cost
    tr = trades_for(df, scale, cost); tr.to_csv(f"{D}/lc_trades_{name.split()[0]}_{name.split()[1]}.csv", index=False)
    summarize(name, tr, df)
