"""Reference implementation of the Liquid Reversal Bands reconstruction.

Mirrors ``liquid_reversal_bands.pine`` bar for bar so the logic can be tested and
backtested outside TradingView. Each helper reproduces the semantics of the
matching Pine built-in (``ta.ema``/``ta.rma`` seed from an SMA, ``ta.stdev`` is
the population standard deviation, ``ta.alma`` weights oldest-to-newest).
Missing values are ``None``, the Python stand-in for Pine's ``na``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional, Sequence

Series = list[Optional[float]]


# ───────────────────────── Pine built-ins ─────────────────────────

def sma(src: Sequence[Optional[float]], length: int) -> Series:
    out: Series = [None] * len(src)
    for i in range(length - 1, len(src)):
        window = src[i - length + 1 : i + 1]
        if all(v is not None for v in window):
            out[i] = sum(window) / length
    return out


def _recursive_ma(src: Sequence[Optional[float]], length: int, alpha: float) -> Series:
    """Shared core of ta.ema / ta.rma: seed with the SMA of the first full window, then recurse."""
    out: Series = [None] * len(src)
    seed = sma(src, length)
    prev: Optional[float] = None
    for i, v in enumerate(src):
        if prev is None:
            prev = seed[i]
        elif v is not None:
            prev = alpha * v + (1.0 - alpha) * prev
        out[i] = prev
    return out


def ema(src: Sequence[Optional[float]], length: int) -> Series:
    return _recursive_ma(src, length, 2.0 / (length + 1))


def rma(src: Sequence[Optional[float]], length: int) -> Series:
    return _recursive_ma(src, length, 1.0 / length)


def stdev(src: Sequence[Optional[float]], length: int) -> Series:
    out: Series = [None] * len(src)
    for i in range(length - 1, len(src)):
        window = src[i - length + 1 : i + 1]
        if all(v is not None for v in window):
            mean = sum(window) / length
            out[i] = math.sqrt(sum((v - mean) ** 2 for v in window) / length)
    return out


def alma_weights(length: int, offset: float, sigma: float) -> list[float]:
    """Normalised ALMA weights, index 0 = oldest bar in the window."""
    m = offset * (length - 1)
    s = length / sigma
    raw = [math.exp(-((i - m) ** 2) / (2 * s * s)) for i in range(length)]
    norm = sum(raw)
    return [w / norm for w in raw]


def alma(src: Sequence[Optional[float]], length: int, offset: float, sigma: float) -> Series:
    weights = alma_weights(length, offset, sigma)
    out: Series = [None] * len(src)
    for i in range(length - 1, len(src)):
        window = src[i - length + 1 : i + 1]
        if all(v is not None for v in window):
            out[i] = sum(w * v for w, v in zip(weights, window))
    return out


def atr(high: Sequence[float], low: Sequence[float], close: Sequence[float], length: int) -> Series:
    tr: list[Optional[float]] = []
    for i in range(len(close)):
        if i == 0:
            tr.append(high[i] - low[i])
        else:
            pc = close[i - 1]
            tr.append(max(high[i] - low[i], abs(high[i] - pc), abs(low[i] - pc)))
    return rma(tr, length)


# ───────────────────────── Indicator ─────────────────────────

@dataclass
class LRBParams:
    fair_len: int = 50
    alma_offset: float = 0.85  # ASSUMED (Pine default)
    alma_sigma: float = 6.0  # ASSUMED (Pine default)
    phase_bias: float = 0.5  # ASSUMED: ALMA share of the EMA/ALMA blend
    smooth_len: int = 5  # ASSUMED: secondary EMA pass
    w_std: float = 0.30  # ASSUMED
    w_atr: float = 0.30  # ASSUMED
    w_abs: float = 0.20  # ASSUMED
    w_range: float = 0.20  # ASSUMED
    inner_mult: float = 2.0  # ASSUMED
    outer_mult: float = 3.0  # ASSUMED
    show_outer: bool = True
    cooldown: int = 10  # ASSUMED


@dataclass
class LRBResult:
    lfv: Series
    width: Series
    upper: Series
    lower: Series
    upper_outer: Series
    lower_outer: Series
    bull: list[bool]
    bear: list[bool]
    heat: Series  # 0 = at/below lower band, 1 = at/above upper band
    last_dir: list[int] = field(default_factory=list)  # +1 / -1 / 0, drives "Latest Signal" candles


def _add(a: Optional[float], b: Optional[float], k: float = 1.0) -> Optional[float]:
    return None if a is None or b is None else a + k * b


def _crossed_back(prev_close: float, close: float, prev_band: Optional[float], band: Optional[float], below: bool) -> bool:
    if prev_band is None or band is None:
        return False
    if below:
        return prev_close < prev_band and close >= band
    return prev_close > prev_band and close <= band


def liquid_reversal_bands(
    high: Sequence[float],
    low: Sequence[float],
    close: Sequence[float],
    params: LRBParams | None = None,
    src: Sequence[float] | None = None,
) -> LRBResult:
    p = params or LRBParams()
    src = close if src is None else src
    n = len(close)

    # Liquid Fair Value: EMA/ALMA blend, then a short EMA pass.
    ema_fv = ema(src, p.fair_len)
    alma_fv = alma(src, p.fair_len, p.alma_offset, p.alma_sigma)
    raw_fv = [
        None if e is None or a is None else e * (1.0 - p.phase_bias) + a * p.phase_bias
        for e, a in zip(ema_fv, alma_fv)
    ]
    lfv = ema(raw_fv, p.smooth_len)

    # Width: weighted blend of four volatility measures.
    dev = [None if f is None else s - f for s, f in zip(src, lfv)]
    vol_std = stdev(dev, p.fair_len)
    vol_atr = atr(high, low, close, p.fair_len)
    vol_abs = ema([None if d is None else abs(d) for d in dev], p.fair_len)
    vol_range = ema([h - l for h, l in zip(high, low)], p.fair_len)
    w_sum = max(p.w_std + p.w_atr + p.w_abs + p.w_range, 1e-10)
    width: Series = []
    for parts in zip(vol_std, vol_atr, vol_abs, vol_range):
        if any(v is None for v in parts):
            width.append(None)
        else:
            s, a, d, r = parts
            width.append((p.w_std * s + p.w_atr * a + p.w_abs * d + p.w_range * r) / w_sum)

    upper = [_add(f, w, p.inner_mult) for f, w in zip(lfv, width)]
    lower = [_add(f, w, -p.inner_mult) for f, w in zip(lfv, width)]
    upper_outer = [_add(f, w, p.outer_mult) for f, w in zip(lfv, width)]
    lower_outer = [_add(f, w, -p.outer_mult) for f, w in zip(lfv, width)]

    # Signals: close back inside a band after closing outside it on the prior bar, gated by cooldown.
    bull = [False] * n
    bear = [False] * n
    last_dir = [0] * n
    last_sig_bar: Optional[int] = None
    direction = 0
    for i in range(1, n):
        c0, c1 = close[i], close[i - 1]
        bull_raw = _crossed_back(c1, c0, lower[i - 1], lower[i], below=True) or (
            p.show_outer and _crossed_back(c1, c0, lower_outer[i - 1], lower_outer[i], below=True)
        )
        bear_raw = _crossed_back(c1, c0, upper[i - 1], upper[i], below=False) or (
            p.show_outer and _crossed_back(c1, c0, upper_outer[i - 1], upper_outer[i], below=False)
        )
        can_fire = last_sig_bar is None or i - last_sig_bar >= p.cooldown
        bull[i] = can_fire and bull_raw
        bear[i] = can_fire and not bull[i] and bear_raw
        if bull[i] or bear[i]:
            last_sig_bar = i
            direction = 1 if bull[i] else -1
        last_dir[i] = direction

    heat: Series = []
    for c, u, l in zip(close, upper, lower):
        if u is None or l is None:
            heat.append(None)
        elif u - l <= 0:
            heat.append(0.5)
        else:
            heat.append(min(1.0, max(0.0, (c - l) / (u - l))))

    return LRBResult(lfv, width, upper, lower, upper_outer, lower_outer, bull, bear, heat, last_dir)


if __name__ == "__main__":
    import random

    random.seed(7)
    price, hi, lo, cl = 100.0, [], [], []
    for _ in range(600):
        price *= math.exp(random.gauss(0, 0.012))
        cl.append(price)
        hi.append(price * (1 + abs(random.gauss(0, 0.006))))
        lo.append(price * (1 - abs(random.gauss(0, 0.006))))
    res = liquid_reversal_bands(hi, lo, cl)
    for i in range(len(cl)):
        if res.bull[i] or res.bear[i]:
            side = "BULL" if res.bull[i] else "BEAR"
            print(f"bar {i:4d} {side}  close={cl[i]:8.3f}  lower={res.lower[i]:8.3f}  upper={res.upper[i]:8.3f}")
