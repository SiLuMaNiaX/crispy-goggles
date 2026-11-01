"""Reference implementation of the Decycler High-Low Breakout reconstruction.

Mirrors ``decycler_hl_breakout.pine`` bar for bar. Missing values are ``None``,
the Python stand-in for Pine's ``na``.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional, Sequence

from indicators.liquid_reversal_bands.lrb import Series, atr


def decycler_alpha(period: int) -> float:
    w = 0.707 * 2.0 * math.pi / period
    return (math.cos(w) + math.sin(w) - 1.0) / math.cos(w)


def decycler(src: Sequence[float], period: int) -> list[float]:
    """Ehlers 2-pole Decycler: src minus a 2-pole Butterworth high-pass of src."""
    a = decycler_alpha(period)
    c0 = (1.0 - a / 2.0) ** 2
    c1 = 2.0 * (1.0 - a)
    c2 = (1.0 - a) ** 2
    hp = [0.0] * len(src)
    for i in range(2, len(src)):
        hp[i] = c0 * (src[i] - 2.0 * src[i - 1] + src[i - 2]) + c1 * hp[i - 1] - c2 * hp[i - 2]
    return [s - h for s, h in zip(src, hp)]


@dataclass
class DHLBParams:
    cutoff: int = 60  # ASSUMED default
    atr_len: int = 14  # ASSUMED default
    pad_mult: float = 0.5  # ASSUMED default
    breath: float = 0.5  # ASSUMED form + default
    slope_len: int = 5  # ASSUMED default
    slope_thr: float = 0.25  # ASSUMED default
    strong_mult: float = 1.0  # ASSUMED form + default


@dataclass
class DHLBResult:
    dc_high: list[float]
    dc_low: list[float]
    dc_close: list[float]
    slope: Series
    upper: Series
    lower: Series
    trend: list[int]  # +1 long / -1 short / 0 undecided
    go_long: list[bool]
    go_short: list[bool]


def decycler_hl_breakout(
    high: Sequence[float],
    low: Sequence[float],
    close: Sequence[float],
    params: DHLBParams | None = None,
) -> DHLBResult:
    p = params or DHLBParams()
    n = len(close)
    dc_h = decycler(high, p.cutoff)
    dc_l = decycler(low, p.cutoff)
    dc_c = decycler(close, p.cutoff)
    vol = atr(high, low, close, p.atr_len)

    slope: Series = [None] * n
    upper: Series = [None] * n
    lower: Series = [None] * n
    for i in range(n):
        v = vol[i]
        if v is None or i < p.slope_len:
            continue
        s = (dc_c[i] - dc_c[i - p.slope_len]) / v if v > 0 else 0.0
        slope[i] = s
        upper[i] = dc_h[i] + v * (p.pad_mult + p.breath * max(-s, 0.0))
        lower[i] = dc_l[i] - v * (p.pad_mult + p.breath * max(s, 0.0))

    trend = [0] * n
    go_long = [False] * n
    go_short = [False] * n
    state = 0
    for i in range(n):
        s, u, l, v = slope[i], upper[i], lower[i], vol[i]
        if s is not None:
            c = close[i]
            bull = c > u and (s >= p.slope_thr or c > u + p.strong_mult * v)
            bear = c < l and (s <= -p.slope_thr or c < l - p.strong_mult * v)
            go_long[i] = state != 1 and bull
            go_short[i] = state != -1 and bear and not go_long[i]
            if go_long[i]:
                state = 1
            elif go_short[i]:
                state = -1
        trend[i] = state

    return DHLBResult(dc_h, dc_l, dc_c, slope, upper, lower, trend, go_long, go_short)


if __name__ == "__main__":
    import random

    random.seed(11)
    price, hi, lo, cl = 100.0, [], [], []
    for _ in range(800):
        price *= math.exp(random.gauss(0.0002, 0.012))
        cl.append(price)
        hi.append(price * (1 + abs(random.gauss(0, 0.006))))
        lo.append(price * (1 - abs(random.gauss(0, 0.006))))
    res = decycler_hl_breakout(hi, lo, cl)
    for i in range(len(cl)):
        if res.go_long[i] or res.go_short[i]:
            side = "LONG " if res.go_long[i] else "SHORT"
            print(f"bar {i:4d} {side} close={cl[i]:8.3f} slope={res.slope[i]:+.2f}")
