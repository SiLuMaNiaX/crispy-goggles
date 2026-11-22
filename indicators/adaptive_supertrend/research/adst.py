"""Python port of adaptive_supertrend.pine (bar-by-bar, same order of operations) + SAR backtest."""
from __future__ import annotations

import numpy as np
import pandas as pd


def rma(x, n):
    out = np.full(len(x), np.nan)
    s = 0.0
    for i, v in enumerate(x):
        if i < n:
            s += v
            if i == n - 1:
                out[i] = s / n
        else:
            out[i] = (out[i - 1] * (n - 1) + v) / n
    return out


def compute(df: pd.DataFrame, atr_len=14, base_f=3.5, er_len=10, base_conf=2, vol_avg=50,
            f_min=0.75, f_max=1.4, er_chop=0.30, er_trend=0.60, adaptive=True) -> pd.DataFrame:
    """adaptive=False gives a plain SuperTrend (fixed factor, confirm = base_conf)."""
    o, h, l, c = (df[k].to_numpy(float) for k in ("open", "high", "low", "close"))
    n = len(c)
    tr = np.r_[h[0] - l[0], np.maximum(h[1:] - l[1:], np.maximum(abs(h[1:] - c[:-1]), abs(l[1:] - c[:-1])))]
    atr = rma(tr, atr_len)                                    # ta.atr
    atr_avg = pd.Series(atr).rolling(vol_avg).mean().to_numpy()
    vr = np.where(np.isfinite(atr / atr_avg), atr / atr_avg, 1.0)
    factor = base_f * np.clip(vr, f_min, f_max) if adaptive else np.full(n, base_f)

    chg = np.abs(c - np.r_[np.full(er_len, np.nan), c[:-er_len]])
    path = pd.Series(np.abs(np.r_[np.nan, np.diff(c)])).rolling(er_len).sum().to_numpy()
    er = np.where(path > 0, chg / np.where(path > 0, path, 1), 0.0)
    er = np.nan_to_num(er)
    if adaptive:
        conf_n = np.where(er < er_chop, base_conf + 1, np.where(er > er_trend, max(1, base_conf - 1), base_conf))
    else:
        conf_n = np.full(n, base_conf)

    src = (h + l) / 2
    up = np.full(n, np.nan); dn = np.full(n, np.nan)
    raw = np.ones(n, int); conf = np.ones(n, int); flip = np.zeros(n, int); line = np.full(n, np.nan)
    q = np.full(n, np.nan)
    up_b = dn_b = np.nan
    raw_d, conf_d, held = 1, 1, 0
    for i in range(n):
        if np.isnan(atr[i]):
            raw[i], conf[i] = raw_d, conf_d
            continue
        up_new = src[i] - factor[i] * atr[i]
        dn_new = src[i] + factor[i] * atr[i]
        up_b = up_new if np.isnan(up_b) else (max(up_new, up_b) if c[i - 1] > up_b else up_new)
        dn_b = dn_new if np.isnan(dn_b) else (min(dn_new, dn_b) if c[i - 1] < dn_b else dn_new)
        prev = raw_d
        if raw_d == 1 and c[i] < up_b:
            raw_d = -1
        elif raw_d == -1 and c[i] > dn_b:
            raw_d = 1
        held = 1 if raw_d != prev else held + 1
        if raw_d != conf_d and held >= conf_n[i]:
            conf_d = raw_d
            flip[i] = conf_d
            mom5 = (c[i] - c[i - 5]) / atr[i] * conf_d if i >= 5 else 0.0
            eff_s = er[i] * 100
            vol_s = 100 * (1 - min(abs(vr[i] - 1) / 0.5, 1))
            mom_s = 100 * max(0.0, min(mom5 / 2.0, 1.0))
            q[i] = 0.5 * eff_s + 0.3 * vol_s + 0.2 * mom_s
        up[i], dn[i], raw[i], conf[i] = up_b, dn_b, raw_d, conf_d
        line[i] = up_b if raw_d == 1 else dn_b
    out = df.copy()
    out = out.assign(atr=atr, vr=vr, er=er, factor=factor, conf_n=conf_n, line=line, raw=raw, conf=conf, flip=flip, q=q)
    out["grade"] = np.where(np.isnan(q), "", np.where(q >= 70, "A", np.where(q >= 50, "B", "C")))
    return out


def sar(x: pd.DataFrame, cost=0.40, grades=("A", "B", "C"), warmup=100) -> pd.DataFrame:
    """Stop-and-reverse on confirmed flips. Enter at next bar open. A flip whose grade is not in
    `grades` closes the open trade (the trend changed) but does not open a new one.
    Weekend gaps > 6h: flat at last bar close before the gap (matches an EA closing on Friday)."""
    o, c = x.open.to_numpy(), x.close.to_numpy()
    fl, gr, atr = x.flip.to_numpy(), x.grade.to_numpy(), x.atr.to_numpy()
    t = x.index
    gap = np.r_[(t[1:] - t[:-1]) > pd.Timedelta(hours=6), False]
    trades, pos, e_px, e_t, e_atr, e_g = [], 0, 0.0, None, 0.0, ""
    for i in range(warmup, len(x) - 1):
        if pos != 0 and gap[i]:
            trades.append((e_t, t[i], pos, e_g, e_px, c[i], ((c[i] - e_px) * pos - cost), e_atr)); pos = 0
            continue
        if fl[i] != 0:
            if pos != 0:
                trades.append((e_t, t[i + 1], pos, e_g, e_px, o[i + 1], ((o[i + 1] - e_px) * pos - cost), e_atr)); pos = 0
            if gr[i] in grades:
                pos, e_px, e_t, e_atr, e_g = fl[i], o[i + 1], t[i + 1], atr[i], gr[i]
    tr = pd.DataFrame(trades, columns=["entry_t", "exit_t", "side", "grade", "entry", "exit", "pnl", "atr"])
    tr["R"] = tr.pnl / tr.atr        # P&L in ATR-at-entry units
    return tr


def stats(tr: pd.DataFrame) -> dict:
    if len(tr) == 0:
        return {"n": 0}
    r = tr.R.to_numpy(); eq = np.cumsum(r)
    gp, gl = r[r > 0].sum(), -r[r < 0].sum()
    return {"n": len(r), "win%": round(100 * (r > 0).mean(), 1), "avgR": round(r.mean(), 3),
            "PF": round(gp / gl, 2) if gl > 0 else np.inf, "sumR": round(r.sum(), 1),
            "maxDD_R": round((np.maximum.accumulate(eq) - eq).max(), 1),
            "t": round(r.mean() / r.std() * np.sqrt(len(r)), 2) if len(r) > 2 else np.nan}
