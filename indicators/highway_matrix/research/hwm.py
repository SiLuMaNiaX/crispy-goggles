"""Python replica of HighwayMatrix.mq5 (non-repainting mode) + a bar-by-bar backtester.

Used to validate the H-Sell/H-Buy signals before building the EA. All values at bar i
use only data up to and including bar i (signals act at the open of bar i+1).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

M30 = pd.Timedelta(minutes=30)


# ───────────────────────── data ─────────────────────────
def load(paths: list[str]) -> pd.DataFrame:
    df = pd.concat([pd.read_csv(p) for p in paths])
    df["t"] = pd.to_datetime(df.open_time_ms, unit="ms", utc=True)
    df = df.drop_duplicates("t").set_index("t").sort_index()
    return df[["open", "high", "low", "close", "volume"]].astype(float)


def xau_session(df: pd.DataFrame) -> pd.DataFrame:
    """Drop bars when spot gold (XAUUSD) is closed: Fri 21:00 UTC -> Sun 22:00 UTC."""
    t = df.index
    dow, hr = t.dayofweek, t.hour
    closed = (dow == 5) | ((dow == 4) & (hr >= 21)) | ((dow == 6) & (hr < 22))
    return df[~closed]


def resample_htf(df: pd.DataFrame, rule="30min") -> pd.DataFrame:
    return df.resample(rule, label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last"}).dropna()


# ───────────────────────── indicator ─────────────────────────
def ema(x: np.ndarray, n: int) -> np.ndarray:
    a = 2.0 / (n + 1.0)
    out = np.empty_like(x)
    out[0] = x[0]
    for i in range(1, len(x)):
        out[i] = a * x[i] + (1 - a) * out[i - 1]
    return out


def atr_rma(h, l, c, n):
    tr = np.empty_like(c)
    tr[0] = h[0] - l[0]
    tr[1:] = np.maximum(h[1:] - l[1:], np.maximum(np.abs(h[1:] - c[:-1]), np.abs(l[1:] - c[:-1])))
    out = np.empty_like(c)
    s = 0.0
    for j in range(len(c)):
        if j < n:
            s += tr[j]
            out[j] = s / (j + 1)
        else:
            out[j] = (out[j - 1] * (n - 1) + tr[j]) / n
    return out


def compute(df: pd.DataFrame, htf: pd.DataFrame, bw=20.0, win=500, m_in=1.5, m_out=3.0,
            hw_len=20, hw_atr=14, hw_mult=0.5, ema_fast=5, use_mom=True, cooldown=10) -> pd.DataFrame:
    o, h, l, c = (df[k].to_numpy() for k in ("open", "high", "low", "close"))
    n = len(c)
    src = c

    # endpoint Gaussian kernel (same truncation as the MQL5 code)
    k_len = int(min(np.ceil(bw * 3.0), 499))
    w = np.exp(-(np.arange(k_len) ** 2) / (2.0 * bw * bw))
    num = np.convolve(src, w)[:n]
    den = np.convolve(np.ones(n), w)[:n]
    mid = num / den

    dev = np.abs(src - mid)
    mae = pd.Series(dev).rolling(win, min_periods=1).mean().to_numpy()

    # highway: previous completed HTF bar
    hc, hh, hl_ = (htf[k].to_numpy() for k in ("close", "high", "low"))
    h_ema = ema(hc, hw_len)
    h_atr = atr_rma(hh, hl_, hc, hw_atr)
    idx = np.searchsorted(htf.index.values, df.index.values, side="right") - 1  # HTF bar containing t
    prev = idx - 1
    ok = prev >= 0
    hwU = np.full(n, np.nan)
    hwL = np.full(n, np.nan)
    hwU[ok] = h_ema[prev[ok]] + h_atr[prev[ok]] * hw_mult
    hwL[ok] = h_ema[prev[ok]] - h_atr[prev[ok]] * hw_mult

    slope = np.r_[0.0, np.diff(mid)]
    trend = np.where((c > hwU) & (slope > 0), 1, np.where((c < hwL) & (slope < 0), -1, 0))

    upI, loI = mid + mae * m_in, mid - mae * m_in
    upO, loO = mid + mae * m_out, mid - mae * m_out
    ef = ema(src, ema_fast)
    efd = np.r_[0.0, np.diff(ef)]

    raw_sell = np.zeros(n, bool)
    raw_buy = np.zeros(n, bool)
    raw_sell[1:] = (h[:-1] >= upI[:-1]) & (c[1:] < upI[1:]) & (c[1:] < o[1:]) & ((efd[1:] < 0) | (not use_mom))
    raw_buy[1:] = (l[:-1] <= loI[:-1]) & (c[1:] > loI[1:]) & (c[1:] > o[1:]) & ((efd[1:] > 0) | (not use_mom))

    sig = np.zeros(n, np.int8)  # +1 buy, -1 sell (any)
    last = -10**9
    for i in range(1, n):
        if i - last <= cooldown:
            continue
        if raw_sell[i]:
            sig[i] = -1
            last = i
        elif raw_buy[i]:
            sig[i] = 1
            last = i

    out = df.copy()
    out = out.assign(mid=mid, mae=mae, upI=upI, loI=loI, upO=upO, loO=loO, hwU=hwU, hwL=hwL,
                     trend=trend, sig=sig, ema_f=ef)
    out["hsig"] = np.where((sig == -1) & (trend == -1), -1, np.where((sig == 1) & (trend == 1), 1, 0))
    return out


# ───────────────────────── backtest ─────────────────────────
def backtest(x: pd.DataFrame, sig_col="hsig", sl_mode="outer", sl_buf=0.25, tp_mode="mid", rr=1.5,
             cost=0.40, max_hold=288, be_at=None, warmup=600, entry_filter=None) -> pd.DataFrame:
    """One position at a time. Entry at next bar open. Intrabar: SL checked before TP (conservative).

    sl_mode: 'outer'  -> beyond the outer band (+ sl_buf*MAE)
             'atr'    -> sl_buf * MAE from entry (MAE used as volatility unit)
    tp_mode: 'mid'    -> kernel centre line at signal bar
             'rr'     -> rr * risk
             'opp'    -> opposite inner band
    cost: round-trip cost in price units (spread + commission + slippage).
    """
    o, h, l, c = (x[k].to_numpy() for k in ("open", "high", "low", "close"))
    sig = x[sig_col].to_numpy()
    mid, mae = x["mid"].to_numpy(), x["mae"].to_numpy()
    upO, loO, upI, loI = (x[k].to_numpy() for k in ("upO", "loO", "upI", "loI"))
    t = x.index
    n = len(c)
    trades = []
    i = warmup
    while i < n - 1:
        s = sig[i]
        if s == 0 or (entry_filter is not None and not entry_filter[i]):
            i += 1
            continue
        e = o[i + 1]
        if s == -1:
            sl = (upO[i] + sl_buf * mae[i]) if sl_mode == "outer" else e + sl_buf * mae[i]
            risk = sl - e
            tp = mid[i] if tp_mode == "mid" else (loI[i] if tp_mode == "opp" else e - rr * risk)
        else:
            sl = (loO[i] - sl_buf * mae[i]) if sl_mode == "outer" else e - sl_buf * mae[i]
            risk = e - sl
            tp = mid[i] if tp_mode == "mid" else (upI[i] if tp_mode == "opp" else e + rr * risk)
        if risk <= 0 or (s == -1 and tp >= e) or (s == 1 and tp <= e):
            i += 1
            continue
        exit_px, j, why = None, i + 1, "time"
        moved_be = False
        while j < n:
            hi, lo = h[j], l[j]
            if s == -1:
                if hi >= sl:
                    exit_px, why = max(sl, o[j]) if o[j] > sl else sl, "sl"
                elif lo <= tp:
                    exit_px, why = min(tp, o[j]) if o[j] < tp else tp, "tp"
            else:
                if lo <= sl:
                    exit_px, why = min(sl, o[j]) if o[j] < sl else sl, "sl"
                elif hi >= tp:
                    exit_px, why = max(tp, o[j]) if o[j] > tp else tp, "tp"
            if exit_px is not None:
                break
            if be_at is not None and not moved_be:
                fav = (e - lo) if s == -1 else (hi - e)
                if fav >= be_at * risk:
                    sl = e
                    moved_be = True
            if j - (i + 1) >= max_hold or (j + 1 < n and (t[j + 1] - t[j]) > pd.Timedelta(hours=6)):
                exit_px = c[j]
                why = "time" if j - (i + 1) >= max_hold else "weekend"
                break
            j += 1
        if exit_px is None:
            break
        pnl = (exit_px - e) * (-1 if s == -1 else 1) - cost
        trades.append((t[i + 1], t[j], s, e, exit_px, risk, pnl, pnl / risk, why))
        i = j  # next signal only after exit
    return pd.DataFrame(trades, columns=["entry_t", "exit_t", "side", "entry", "exit", "risk", "pnl", "R", "why"])


def stats(tr: pd.DataFrame) -> dict:
    if len(tr) == 0:
        return {"n": 0}
    R = tr.R.to_numpy()
    eq = np.cumsum(R)
    dd = (np.maximum.accumulate(eq) - eq).max()
    gp, gl = R[R > 0].sum(), -R[R < 0].sum()
    return {"n": len(tr), "win%": round(100 * (R > 0).mean(), 1), "avgR": round(R.mean(), 3),
            "PF": round(gp / gl, 2) if gl > 0 else np.inf, "sumR": round(R.sum(), 1),
            "maxDD_R": round(dd, 1), "pnl$": round(tr.pnl.sum(), 1)}
