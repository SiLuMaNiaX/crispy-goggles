import math
import random

import pytest

from indicators.liquid_reversal_bands.lrb import (
    LRBParams,
    alma,
    alma_weights,
    atr,
    ema,
    liquid_reversal_bands,
    rma,
    stdev,
)


def _walk(n=500, seed=1):
    random.seed(seed)
    price, hi, lo, cl = 100.0, [], [], []
    for _ in range(n):
        price *= math.exp(random.gauss(0, 0.012))
        cl.append(price)
        hi.append(price * (1 + abs(random.gauss(0, 0.006))))
        lo.append(price * (1 - abs(random.gauss(0, 0.006))))
    return hi, lo, cl


def test_ema_seeds_with_sma_like_pine():
    out = ema([1, 2, 3, 4, 5], 3)
    assert out[:2] == [None, None]
    assert out[2] == pytest.approx(2.0)
    assert out[3] == pytest.approx(0.5 * 4 + 0.5 * 2.0)


def test_rma_uses_wilder_alpha():
    out = rma([2, 4, 6, 8], 2)
    assert out[1] == pytest.approx(3.0)
    assert out[2] == pytest.approx(0.5 * 6 + 0.5 * 3.0)


def test_stdev_is_population():
    assert stdev([2, 4, 4, 4, 5, 5, 7, 9], 8)[-1] == pytest.approx(2.0)


def test_alma_weights_peak_toward_recent_bars():
    w = alma_weights(9, 0.85, 6.0)
    assert sum(w) == pytest.approx(1.0)
    assert w.index(max(w)) == round(0.85 * 8)
    assert alma([5.0] * 9, 9, 0.85, 6.0)[-1] == pytest.approx(5.0)


def test_atr_first_bar_uses_range():
    out = atr([10, 12], [8, 9], [9, 11], 1)
    assert out == [2, 3]


def test_band_ordering_and_warmup():
    hi, lo, cl = _walk()
    r = liquid_reversal_bands(hi, lo, cl)
    valid = [i for i, u in enumerate(r.upper) if u is not None]
    assert valid, "bands never warmed up"
    assert valid[0] >= 50
    for i in valid:
        assert r.lower_outer[i] < r.lower[i] < r.lfv[i] < r.upper[i] < r.upper_outer[i]
        assert 0.0 <= r.heat[i] <= 1.0


def _flat_then_spike(direction):
    # Quiet series, one bar closing far outside the bands, then a close back near the mean.
    n = 120
    cl = [100.0 + 0.2 * math.sin(i / 3) for i in range(n)]
    cl[100] = 100.0 + direction * 8.0
    hi = [c + 0.3 for c in cl]
    lo = [c - 0.3 for c in cl]
    return hi, lo, cl


@pytest.mark.parametrize("direction", [-1, 1])
def test_reentry_after_close_outside_fires_signal(direction):
    hi, lo, cl = _flat_then_spike(direction)
    r = liquid_reversal_bands(hi, lo, cl, LRBParams(fair_len=20, cooldown=0))
    band = r.lower if direction < 0 else r.upper
    assert (cl[100] < band[100]) if direction < 0 else (cl[100] > band[100])
    fired = r.bull if direction < 0 else r.bear
    assert fired[101]
    assert r.last_dir[101] == (1 if direction < 0 else -1)


def test_wick_outside_band_does_not_fire():
    hi, lo, cl = _flat_then_spike(-1)
    cl[100] = cl[99]
    lo[100] = 90.0  # deep wick, close stays inside
    r = liquid_reversal_bands(hi, lo, cl, LRBParams(fair_len=20, cooldown=0))
    assert not any(r.bull[95:110])


def test_cooldown_suppresses_close_signals():
    hi, lo, cl = _walk(800, seed=3)
    free = liquid_reversal_bands(hi, lo, cl, LRBParams(cooldown=0))
    gated = liquid_reversal_bands(hi, lo, cl, LRBParams(cooldown=25))
    sig_idx = [i for i in range(len(cl)) if gated.bull[i] or gated.bear[i]]
    assert all(b - a >= 25 for a, b in zip(sig_idx, sig_idx[1:]))
    assert sum(free.bull) + sum(free.bear) >= len(sig_idx)
