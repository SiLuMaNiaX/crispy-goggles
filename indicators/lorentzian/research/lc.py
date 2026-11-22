"""Independent implementation of jdehorty's "Machine Learning: Lorentzian Classification" (default settings),
written from reading the open-source Pine v6 script and validated against TradingView export CSVs.

Faithful quirks (all present in the original):
  * training label at bar i uses the PAST 4 bars and is inverted: close rose over bars i-4..i -> label -1 (short)
  * "nearest neighbour" search is greedy: accepts only candidates whose distance is >= the last accepted one,
    skips indices divisible by 4, and the 8-vote buffer persists across bars
  * candidate pool is array indices [max_bars_back_index .. min(max_bars_back-1, n-1)], iterated DOWNWARD when
    the start is larger (Pine for-loop semantics) - i.e. an old, fixed block of history
  * predictions only on the last `max_bars_back` bars of the loaded chart
"""
from __future__ import annotations

import math

import numpy as np

NAN = float("nan")


def _sma(x, p):
    out = np.full(len(x), NAN)
    for i in range(p - 1, len(x)):
        w = x[i - p + 1:i + 1]
        if not np.isnan(w).any():
            out[i] = w.mean()
    return out


def _ema_like(x, p, alpha):
    out = np.full(len(x), NAN)
    for i, v in enumerate(x):
        if np.isnan(v):
            continue
        if i > 0 and not np.isnan(out[i - 1]):
            out[i] = alpha * v + (1 - alpha) * out[i - 1]
        elif i >= p - 1:
            w = x[i - p + 1:i + 1]
            if not np.isnan(w).any():
                out[i] = w.mean()
    return out


def ema(x, p):
    return _ema_like(np.asarray(x, float), p, 2.0 / (p + 1))


def rma(x, p):
    return _ema_like(np.asarray(x, float), p, 1.0 / p)


def _wilder(x, p):
    out = np.empty(len(x))
    for i, v in enumerate(x):
        out[i] = v if i == 0 or np.isnan(out[i - 1]) else out[i - 1] - out[i - 1] / p + v
    return out


def _rescale(v, a, b, c, d):
    return c + (d - c) * (v - a) / max(b - a, 1e-9)


def _normalize_running(x):
    out = np.full(len(x), NAN)
    lo, hi = 1e11, -1e11
    for i, v in enumerate(x):
        if np.isnan(v):
            continue
        lo, hi = min(lo, v), max(hi, v)
        out[i] = (v - lo) / max(hi - lo, 1e-9)
    return out


def rsi(c, p):
    g = np.full(len(c), NAN); l = np.full(len(c), NAN)
    d = np.diff(c)
    g[1:] = np.where(d > 0, d, 0.0); l[1:] = np.where(d < 0, -d, 0.0)
    gr, lr = rma(g, p), rma(l, p)
    out = np.full(len(c), NAN)
    ok = ~np.isnan(gr) & ~np.isnan(lr)
    with np.errstate(divide="ignore", invalid="ignore"):
        out[ok] = np.where(lr[ok] == 0, 100.0, 100.0 - 100.0 / (1.0 + gr[ok] / lr[ok]))
    return out


def n_rsi(c, a, b):
    s = ema(rsi(c, a), b)
    return np.where(np.isnan(s), NAN, _rescale(s, 0, 100, 0, 1))


def n_cci(c, a, b):
    avg = _sma(c, a)
    cci = np.full(len(c), NAN)
    for i in range(len(c)):
        if np.isnan(avg[i]):
            continue
        md = np.abs(c[i - a + 1:i + 1] - avg[i]).mean()
        cci[i] = (c[i] - avg[i]) / (0.015 * md) if md != 0 else 0.0
    return _normalize_running(ema(cci, b))


def n_wt(hlc3, a, b):
    e1 = ema(hlc3, a)
    e2 = ema(np.where(np.isnan(e1), NAN, np.abs(hlc3 - e1)), a)
    ci = np.full(len(hlc3), NAN)
    ok = ~np.isnan(e1) & ~np.isnan(e2)
    with np.errstate(divide="ignore", invalid="ignore"):
        ci[ok] = np.where(e2[ok] != 0, (hlc3[ok] - e1[ok]) / (0.015 * e2[ok]), 0.0)
    wt1 = ema(ci, b); wt2 = _sma(wt1, 4)
    return _normalize_running(wt1 - wt2)


def _qsub(a, b, s):
    return a - b if s <= 0 else (round(a * s) - round(b * s)) / s


def n_adx(h, l, c, p, scale):
    n = len(c)
    tr = np.empty(n); dp = np.empty(n); dm = np.empty(n)
    for i in range(n):
        pc = c[i - 1] if i else 0.0; ph = h[i - 1] if i else 0.0; pl = l[i - 1] if i else 0.0
        tr[i] = max(_qsub(h[i], l[i], scale), abs(_qsub(h[i], pc, scale)), abs(_qsub(l[i], pc, scale)))
        up, dn = _qsub(h[i], ph, scale), _qsub(pl, l[i], scale)
        dp[i] = up if up > dn and up > 0 else 0.0
        dm[i] = dn if dn > up and dn > 0 else 0.0
    ts, ps, ms = _wilder(tr, p), _wilder(dp, p), _wilder(dm, p)
    with np.errstate(divide="ignore", invalid="ignore"):
        dip = np.where(ts != 0, ps / ts * 100, 0.0); dim = np.where(ts != 0, ms / ts * 100, 0.0)
        dx = np.where(dip + dim != 0, np.abs(dip - dim) / (dip + dim) * 100, 0.0)
    a = rma(dx, p)
    return np.where(np.isnan(a), NAN, _rescale(a, 0, 100, 0, 1))


def atr(h, l, c, p):
    pc = np.r_[0.0, c[:-1]]
    return rma(np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc))), p)


def regime(ohlc4, h, l):
    n = len(ohlc4)
    v1 = np.zeros(n); v2 = np.zeros(n); k = np.zeros(n); sl = np.zeros(n); ea = np.zeros(n)
    v2[0] = h[0] - l[0]; k[0] = ohlc4[0]; a_e = 2.0 / 201.0
    for i in range(1, n):
        v1[i] = 0.2 * (ohlc4[i] - ohlc4[i - 1]) + 0.8 * v1[i - 1]
        v2[i] = 0.1 * (h[i] - l[i]) + 0.8 * v2[i - 1]
        om = abs(v1[i] / v2[i]) if v2[i] != 0 else 0.0
        al = (-(om ** 2) + math.sqrt(om ** 4 + 16.0 * om ** 2)) / 8.0
        k[i] = al * ohlc4[i] + (1 - al) * k[i - 1]
        sl[i] = abs(k[i] - k[i - 1])
        ea[i] = sl[i] if (ea[i - 1] == 0 and i < 200) else a_e * sl[i] + (1 - a_e) * ea[i - 1]
    return sl, ea


def kernel_rq(src, lookback, r, start):
    n = len(src); out = np.empty(n)
    denom = max(lookback ** 2 * 2.0 * r, 1e-10)
    for i in range(n):
        m = min(1 + start, i)
        j = np.arange(m + 1)
        w = (1.0 + j ** 2 / denom) ** (-r)
        out[i] = (src[i - j] * w).sum() / w.sum()
    return out


def compute(o, h, l, c, price_scale=0.0, neighbors=8, max_bars_back=2000, include_full_history=False,
            use_vol=True, use_regime=True, regime_thr=-0.1, use_kernel_filter=True,
            kernel_h=8, kernel_r=8.0, kernel_x=25):
    o, h, l, c = (np.asarray(v, float) for v in (o, h, l, c))
    n = len(c)
    hlc3 = (h + l + c) / 3.0; ohlc4 = (o + h + l + c) / 4.0
    F = np.vstack([n_rsi(c, 14, 1), n_wt(hlc3, 10, 11), n_cci(c, 20, 1), n_adx(h, l, c, 20, price_scale), n_rsi(c, 9, 1)])
    a1, a10 = atr(h, l, c, 1), atr(h, l, c, 10)
    rsl, rea = regime(ohlc4, h, l)
    yhat = kernel_rq(c, kernel_h, kernel_r, kernel_x)

    labels = np.zeros(n, int)
    labels[4:] = np.where(c[:-4] < c[4:], -1, np.where(c[:-4] > c[4:], 1, 0))
    mbbi = n - 1 - max_bars_back if n - 1 >= max_bars_back else 0
    start = 0 if include_full_history else mbbi
    bad = np.isnan(F).any(axis=0)
    dist_buf, pred_buf = [], []
    thr_idx = round(neighbors * 3 / 4)

    pred = np.zeros(n, int); direction = np.zeros(n, int)
    buy = np.zeros(n, bool); sell = np.zeros(n, bool); end_l = np.zeros(n, bool); end_s = np.zeros(n, bool)
    signal, held = 0, 0
    for i in range(n):
        if i >= mbbi:
            size_loop = min(max_bars_back - 1, i)          # labels pushed so far: i+1
            idx = np.arange(start, size_loop + 1) if start <= size_loop else np.arange(start, size_loop - 1, -1)
            if bad[i]:
                d = np.full(len(idx), -np.inf)
            else:
                d = np.log1p(np.abs(F[:, idx] - F[:, [i]])).sum(axis=0)
                d[bad[idx]] = -np.inf
            last = -1.0
            for k, j in enumerate(idx):
                if d[k] >= last and j % 4 != 0:
                    last = d[k]
                    dist_buf.append(d[k]); pred_buf.append(int(labels[j]))
                    if len(pred_buf) > neighbors:
                        last = dist_buf[thr_idx]
                        dist_buf.pop(0); pred_buf.pop(0)
            pred[i] = sum(pred_buf)
        fv = (a1[i] > a10[i]) if use_vol and not np.isnan(a1[i]) and not np.isnan(a10[i]) else True
        fr = ((rsl[i] - rea[i]) / rea[i] >= regime_thr) if use_regime and rea[i] != 0 else True
        ok = fv and fr
        prev = signal
        if pred[i] > 0 and ok:
            signal = 1
        elif pred[i] < 0 and ok:
            signal = -1
        direction[i] = signal
        changed = signal != prev
        held = 0 if changed else held + 1
        bull = (i >= 2 and yhat[i - 1] < yhat[i]) if use_kernel_filter else True
        bear = (i >= 2 and yhat[i - 1] > yhat[i]) if use_kernel_filter else True
        buy[i] = signal == 1 and changed and bull
        sell[i] = signal == -1 and changed and bear
        last_buy = i >= 4 and direction[i - 4] == 1
        last_sell = i >= 4 and direction[i - 4] == -1
        end_l[i] = ((held == 4 and last_buy) or (0 < held < 4 and sell[i] and last_buy)) and i >= 4 and buy[i - 4]
        end_s[i] = ((held == 4 and last_sell) or (0 < held < 4 and buy[i] and last_sell)) and i >= 4 and sell[i - 4]
    return dict(F=F, kernel=yhat, prediction=pred, direction=direction, buy=buy, sell=sell,
                end_long=end_l, end_short=end_s, mbbi=mbbi)
