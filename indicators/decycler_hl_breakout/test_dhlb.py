import math

import pytest

from indicators.decycler_hl_breakout.dhlb import (
    DHLBParams,
    decycler,
    decycler_alpha,
    decycler_hl_breakout,
)


def test_alpha_matches_ehlers_formula():
    w = 0.707 * 2 * math.pi / 125
    assert decycler_alpha(125) == pytest.approx((math.cos(w) + math.sin(w) - 1) / math.cos(w))
    assert 0 < decycler_alpha(125) < decycler_alpha(20) < 1


def test_decycler_passes_constant_and_linear_trend():
    assert decycler([7.0] * 50, 20) == pytest.approx([7.0] * 50)
    ramp = [100 + 0.5 * i for i in range(200)]
    # Second difference of a ramp is zero, so the high-pass stays 0: zero-lag on linear trends.
    assert decycler(ramp, 20) == pytest.approx(ramp)


def test_decycler_removes_short_cycle():
    wave = [100 + 5 * math.sin(2 * math.pi * i / 8) for i in range(400)]
    out = decycler(wave, 60)
    tail = out[200:]
    assert max(tail) - min(tail) < 0.25 * 10  # most of the 8-bar cycle amplitude is gone


def _bars(closes, spread=0.2):
    return [c + spread for c in closes], [c - spread for c in closes], closes


def _trend_onset(direction, rate=0.5, n=220, at=150):
    """Quiet chop, then a sustained trend starting at bar `at`."""
    cl = [100.0 + 0.1 * math.sin(i / 2) for i in range(n)]
    for i in range(at, n):
        cl[i] += direction * rate * (i - at + 1)
    return _bars(cl)


@pytest.mark.parametrize("direction", [1, -1])
def test_trend_onset_flips_trend_once(direction):
    hi, lo, cl = _trend_onset(direction)
    r = decycler_hl_breakout(hi, lo, cl, DHLBParams(cutoff=30))
    flips = r.go_long if direction > 0 else r.go_short
    first = flips.index(True)
    assert 150 <= first <= 160
    assert all(t == direction for t in r.trend[first:])


def test_breakout_needs_slope_or_strong_override():
    # Quiet chop, then one modest pop just beyond the upper boundary with no slope behind it.
    cl = [100.0 + 0.1 * math.sin(i / 2) for i in range(200)]
    hi, lo, cl = _bars(cl)
    base = decycler_hl_breakout(hi, lo, cl, DHLBParams(cutoff=30))
    i = 150
    cl[i] = base.upper[i] + 0.4  # beyond the boundary, under 1 ATR past it
    hi[i] = cl[i] + 0.2
    strict = DHLBParams(cutoff=30, slope_thr=100.0, strong_mult=50.0)
    loose = DHLBParams(cutoff=30, slope_thr=100.0, strong_mult=0.0)
    assert not decycler_hl_breakout(hi, lo, cl, strict).go_long[i]
    assert decycler_hl_breakout(hi, lo, cl, loose).go_long[i]


def test_breathing_room_widens_the_defended_side_only():
    ramp = [100 + 0.4 * i for i in range(200)]
    hi, lo, cl = _bars(ramp)
    tight = decycler_hl_breakout(hi, lo, cl, DHLBParams(breath=0.0))
    roomy = decycler_hl_breakout(hi, lo, cl, DHLBParams(breath=2.0))
    assert roomy.lower[-1] < tight.lower[-1]
    assert roomy.upper[-1] == pytest.approx(tight.upper[-1])


def test_no_repeat_signal_while_in_trend():
    hi, lo, cl = _trend_onset(1)
    r = decycler_hl_breakout(hi, lo, cl, DHLBParams(cutoff=30))
    assert sum(r.go_long[150:]) == 1
