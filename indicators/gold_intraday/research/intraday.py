"""Gold intraday / scalping strategy research on 5m bars.

Two families, both flat by the end of the session (no overnight risk):
  ORB : opening-range breakout of the London or New York open, stop orders at the range edges.
  ST  : SuperTrend flips on 5m/15m/30m bars, only during London+NY hours, flat at the NY close.

Execution rules (conservative):
  * stop-order entries fill at the trigger or worse (gap), plus slippage
  * if a bar touches both stop and target, the stop is assumed first
  * a stop touched on the entry bar counts
  * cost = spread+commission per round trip (price units) + slippage on stop-type fills
Sessions use DST-correct local time (Europe/London, America/New_York).
"""
from __future__ import annotations

import numpy as np
import pandas as pd

SESS = {  # name: (tz, open "HH:MM", entry cutoff, flat time)
    "LDN":    ("Europe/London",    "08:00", "12:00", "16:30"),
    "COMEX":  ("America/New_York", "08:20", "12:00", "16:00"),
    "NY":     ("America/New_York", "09:30", "12:30", "16:00"),
}


def _mins(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def orb(df: pd.DataFrame, sess="LDN", range_min=30, stop="opp", target_r=None, cost=0.40, slip=0.10,
        min_range=0.0, max_range=1e9) -> pd.DataFrame:
    tz, op, cut, flat = SESS[sess]
    lt = df.index.tz_convert(tz)
    mod = (lt.hour * 60 + lt.minute).to_numpy()
    day = lt.date
    o, h, l, c = (df[k].to_numpy() for k in ("open", "high", "low", "close"))
    t0, t1, tc, tf = _mins(op), _mins(op) + range_min, _mins(cut), _mins(flat)
    out = []
    # group bar indices by local day
    starts = np.r_[0, np.nonzero(day[1:] != day[:-1])[0] + 1, len(day)]
    for a, b in zip(starts[:-1], starts[1:]):
        m = mod[a:b]
        rng = np.nonzero((m >= t0) & (m < t1))[0]
        if len(rng) < range_min // 5:          # incomplete range (holiday / data gap)
            continue
        rh, rl = h[a + rng].max(), l[a + rng].min()
        width = rh - rl
        if width < min_range or width > max_range:
            continue
        pos, entry, stp, tgt, ei = 0, 0.0, 0.0, None, None
        for k in range(a + rng[-1] + 1, b):
            mk = mod[k]
            if pos == 0:
                if mk >= tc:
                    break
                up, dn = h[k] >= rh, l[k] <= rl
                if up and dn:                                   # both edges in one bar: assume the loss
                    e = max(o[k], rh); s_ = rl if stop == "opp" else (rh + rl) / 2
                    out.append((df.index[k], 1, e, s_, (s_ - e) - cost - 2 * slip, e - s_, "both"))
                    break
                if up or dn:
                    pos = 1 if up else -1
                    entry = (max(o[k], rh) if up else min(o[k], rl)) + pos * slip
                    stp = (rl if up else rh) if stop == "opp" else (rh + rl) / 2
                    risk = abs(entry - stp)
                    tgt = entry + pos * target_r * risk if target_r else None
                    ei = k
                    # stop on the entry bar counts (conservative)
                    if (pos == 1 and l[k] <= stp) or (pos == -1 and h[k] >= stp):
                        out.append((df.index[k], pos, entry, stp, -risk - cost - slip, risk, "stop"))
                        break
                    continue
            else:
                if mk >= tf:
                    out.append((df.index[ei], pos, entry, stp, pos * (o[k] - entry) - cost, abs(entry - stp), "eod"))
                    pos = 0; break
                hit_s = (l[k] <= stp) if pos == 1 else (h[k] >= stp)
                hit_t = tgt is not None and ((h[k] >= tgt) if pos == 1 else (l[k] <= tgt))
                if hit_s:
                    px = min(o[k], stp) if pos == 1 else max(o[k], stp)
                    out.append((df.index[ei], pos, entry, stp, pos * (px - entry) - cost - slip, abs(entry - stp), "stop"))
                    pos = 0; break
                if hit_t:
                    out.append((df.index[ei], pos, entry, stp, pos * (tgt - entry) - cost, abs(entry - stp), "target"))
                    pos = 0; break
        if pos != 0:                                         # day ended (data) before flat time
            out.append((df.index[ei], pos, entry, stp, pos * (c[b - 1] - entry) - cost, abs(entry - stp), "eod"))
    tr = pd.DataFrame(out, columns=["t", "side", "entry", "stop", "pnl", "risk", "why"])
    tr["R"] = tr.pnl / tr.risk
    return tr


def st_intraday(x: pd.DataFrame, window="LDN+NY", stop_atr=1.0, cost=0.40, slip=0.10, trend=None) -> pd.DataFrame:
    """x = output of adst.compute on the signal timeframe. Entries only inside the window, flat at NY 16:00.
    trend: optional array (+1/-1/0) aligned to x; entries only in its direction (higher-timeframe filter)."""
    lt_l = x.index.tz_convert("Europe/London"); lt_n = x.index.tz_convert("America/New_York")
    ml = (lt_l.hour * 60 + lt_l.minute).to_numpy(); mn = (lt_n.hour * 60 + lt_n.minute).to_numpy()
    in_win = ((ml >= 480) if window == "LDN+NY" else (mn >= 510)) & (mn < 900)       # until 15:00 ET for entries
    flat = (mn >= 960) | (np.r_[np.diff(np.asarray(lt_n.date, dtype="datetime64[D]")).astype(int) > 0, False])
    o, h, l, c = (x[k].to_numpy() for k in ("open", "high", "low", "close"))
    fl, line, atr = x.flip.to_numpy(), x.line.to_numpy(), x.atr.to_numpy()
    out = []; pos = 0
    for i in range(100, len(x) - 1):
        if pos != 0:
            hit = (l[i] <= stp) if pos == 1 else (h[i] >= stp)
            if hit and i >= ei:                      # a stop touched on the entry bar counts
                px = min(o[i], stp) if pos == 1 else max(o[i], stp)
                out.append((x.index[ei], pos, e, stp, pos * (px - e) - cost - slip, abs(e - stp), "stop")); pos = 0
            elif flat[i]:
                out.append((x.index[ei], pos, e, stp, pos * (c[i] - e) - cost, abs(e - stp), "eod")); pos = 0
        if fl[i] != 0:
            if pos != 0 and pos != fl[i]:
                out.append((x.index[ei], pos, e, stp, pos * (o[i + 1] - e) - cost, abs(e - stp), "flip")); pos = 0
            if pos == 0 and in_win[i] and not flat[i] and (trend is None or trend[i] == fl[i]):
                pos = fl[i]; e = o[i + 1]; ei = i + 1
                stp = line[i] - pos * stop_atr * atr[i]
                if (pos == 1 and stp >= e) or (pos == -1 and stp <= e):
                    pos = 0
    tr = pd.DataFrame(out, columns=["t", "side", "entry", "stop", "pnl", "risk", "why"])
    tr["R"] = tr.pnl / tr.risk
    return tr


def stats(tr: pd.DataFrame) -> dict:
    if len(tr) < 2:
        return {"n": len(tr)}
    r = tr.R.to_numpy(); eq = np.cumsum(r); gl = -r[r < 0].sum()
    return {"n": len(r), "win": round(100 * (r > 0).mean(), 1), "PF": round(r[r > 0].sum() / gl, 2) if gl else np.inf,
            "avgR": round(r.mean(), 3), "sumR": round(r.sum(), 1), "ddR": round((np.maximum.accumulate(eq) - eq).max(), 1),
            "t": round(r.mean() / r.std() * np.sqrt(len(r)), 2)}


def orb_fade(df: pd.DataFrame, sess="LDN", range_min=30, stop_k=0.5, target="mid", cost=0.40, slip=0.10,
             touch=0.05) -> pd.DataFrame:
    """Fade the first break of the opening range with a LIMIT order at the range edge.
    Fill only if price trades `touch` beyond the edge (no free fills on a mere touch).
    stop = edge + stop_k * range width beyond it; target = range mid, opposite edge, or 1R. One trade per session."""
    tz, op, cut, flat = SESS[sess]
    lt = df.index.tz_convert(tz)
    mod = (lt.hour * 60 + lt.minute).to_numpy(); day = lt.date
    o, h, l, c = (df[k].to_numpy() for k in ("open", "high", "low", "close"))
    t0, t1, tc, tf = _mins(op), _mins(op) + range_min, _mins(cut), _mins(flat)
    out = []
    starts = np.r_[0, np.nonzero(day[1:] != day[:-1])[0] + 1, len(day)]
    for a, b in zip(starts[:-1], starts[1:]):
        m = mod[a:b]
        rng = np.nonzero((m >= t0) & (m < t1))[0]
        if len(rng) < range_min // 5:
            continue
        rh, rl = h[a + rng].max(), l[a + rng].min(); w = rh - rl
        if w <= 0:
            continue
        pos = 0
        for k in range(a + rng[-1] + 1, b):
            if pos == 0:
                if mod[k] >= tc:
                    break
                up, dn = h[k] >= rh + touch, l[k] <= rl - touch
                if up and dn:                                    # both edges: assume the losing side
                    risk = stop_k * w
                    out.append((df.index[k], -1, rh, rh + risk, -risk - cost - slip, risk, "both")); break
                if up or dn:
                    pos = -1 if up else 1
                    e = max(o[k], rh) if up else min(o[k], rl)      # gap through the edge fills at the open (better)
                    e = rh if up else rl                            # ...but count only the edge price (conservative)
                    stp = e - pos * stop_k * w
                    risk = abs(e - stp)
                    tgt = (rh + rl) / 2 if target == "mid" else (rl if up else rh) if target == "opp" else e + pos * risk
                    ei = k
                    if (pos == 1 and l[k] <= stp) or (pos == -1 and h[k] >= stp):
                        out.append((df.index[k], pos, e, stp, -risk - cost - slip, risk, "stop")); pos = 0; break
                    continue
            else:
                if mod[k] >= tf:
                    out.append((df.index[ei], pos, e, stp, pos * (o[k] - e) - cost, risk, "eod")); pos = 0; break
                if (l[k] <= stp) if pos == 1 else (h[k] >= stp):
                    px = min(o[k], stp) if pos == 1 else max(o[k], stp)
                    out.append((df.index[ei], pos, e, stp, pos * (px - e) - cost - slip, risk, "stop")); pos = 0; break
                if (h[k] >= tgt) if pos == 1 else (l[k] <= tgt):
                    out.append((df.index[ei], pos, e, stp, pos * (tgt - e) - cost, risk, "target")); pos = 0; break
        if pos != 0:
            out.append((df.index[ei], pos, e, stp, pos * (c[b - 1] - e) - cost, risk, "eod"))
    tr = pd.DataFrame(out, columns=["t", "side", "entry", "stop", "pnl", "risk", "why"])
    tr["R"] = tr.pnl / tr.risk
    return tr


def htf_trend(x: pd.DataFrame, df5: pd.DataFrame, kind="ST4H", adst=None, hwm=None) -> np.ndarray:
    """Higher-timeframe direction known at each bar of x, from COMPLETED higher-timeframe bars only.
    ST4H: plain SuperTrend(14, 3.5, confirm 2) direction on 4H. EMA1D: sign of the daily EMA(50) slope."""
    if kind == "ST4H":
        hb = hwm.resample_htf(df5, "4h"); s = adst.compute(hb, base_f=3.5, base_conf=2, adaptive=False).conf.to_numpy()
    else:
        hb = hwm.resample_htf(df5, "1D"); e = hwm.ema(hb.close.to_numpy(), 50); s = np.sign(np.r_[0, np.diff(e)])
    ix = np.searchsorted(hb.index.values, x.index.values, side="right") - 2      # last completed HTF bar
    return np.where(ix >= 0, s[np.clip(ix, 0, None)], 0)
