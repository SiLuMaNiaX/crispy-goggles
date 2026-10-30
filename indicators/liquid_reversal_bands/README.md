# Liquid Reversal Bands — reverse-engineered reconstruction

A clean-room reconstruction of **"Uptrick: Liquid Reversal Bands"** ([TradingView](https://www.tradingview.com/script/NkOJyPWb-Uptrick-Liquid-Reversal-Bands/)).
It is built **only from the author's public description**. The original Pine source was not
used or copied, so a constant marked *ASSUMED* is a reasoned default and may not match the original.

| File | What it is |
|------|------------|
| `liquid_reversal_bands.pine` | Pine Script v6 indicator. Passes a compile check with no diagnostics. |
| `lrb.py` | Pure-Python port that matches the Pine script bar for bar, for research and backtests. It has no dependencies. |
| `test_lrb.py` | Tests for the Pine built-in semantics, band ordering, signal and wick rules, and cooldown. |

```bash
PYTHONPATH=. pytest -q indicators              # run tests
python -m indicators.liquid_reversal_bands.lrb  # demo on a synthetic random walk
```

## How it works

```
src ─┬─ EMA(len) ──┐
     └─ ALMA(len) ─┴─ blend (phase bias) ─ EMA(smoothLen) ─► LFV  (Liquid Fair Value)

dev = src − LFV
width = Σ wᵢ·volᵢ / Σ wᵢ,  vol = { stdev(dev,len), ATR(len), EMA(|dev|,len), EMA(high−low,len) }

inner  = LFV ± innerMult · width
outer  = LFV ± outerMult · width       (optional)
```

1. **Liquid Fair Value (centerline).** An EMA reacts quickly but overshoots. An ALMA is smooth
   but can wobble after a gap. Blending them offsets these weaknesses. A short second EMA pass
   then damps the remaining ALMA jitter without adding much lag.
2. **Band width.** The width is a weighted blend of four volatility measures, so no single
   measure dominates:
   - stdev of the deviation from fair value: the statistical spread around the mean
   - ATR: volatility that accounts for gaps
   - EMA of the absolute deviation: typical stretch from fair value, less sensitive to outliers than stdev
   - EMA of high−low: intrabar "range energy"
3. **Signals.** A **bullish reversal** fires when the previous bar *closed* below a lower band
   and the current bar closes back at or above it. A **bearish reversal** is the mirror case at
   an upper band. Because the rule uses closes, a wick that pokes through a band and closes
   inside never triggers a signal. Re-entering an outer band also counts as a signal.
4. **Cooldown.** After a signal fires, no new signal can fire for `cooldown` bars.
5. **Candle coloring.**
   - *Reversal Heat* maps the close's position inside the inner band (0 at the lower band,
     1 at the upper band) to a bull → neutral → bear color gradient.
   - *Latest Signal* colors each candle by the direction of the most recent signal.

## Confirmed vs assumed

| Element | Status | Source |
|---------|--------|--------|
| EMA + ALMA blend, with offset and phase bias, then a secondary smoothing pass | Confirmed | Description |
| Fair Value Length is the lookback for both the EMA and the ALMA. Default 50 | Confirmed / likely | Description; ThinkScript port uses `fairLen = 50` |
| The four volatility inputs (stdev of deviation, ATR, EMA of absolute deviation, EMA of bar range) | Confirmed | Description |
| Close-based re-entry signals, wicks filtered | Confirmed | Description |
| Signal cooldown, Reversal Heat and Latest Signal candle modes, Show Outer Bands toggle | Confirmed | Description |
| ALMA offset 0.85, sigma 6 | **Assumed** | Pine defaults |
| Phase bias, read as a 50/50 ALMA share of the blend | **Assumed** | — |
| Secondary smoothing EMA length 5 | **Assumed** | — |
| Volatility weights 0.30 / 0.30 / 0.20 / 0.20 | **Assumed** | Not published |
| Inner ×2.0 and outer ×3.0 multipliers | **Assumed** | — |
| Volatility lookbacks tied to Fair Value Length | **Assumed** | Matches "higher length → wider bands" |
| Cooldown default of 10 bars | **Assumed** | — |

To calibrate against the original, open both indicators on the same chart. First match the
centerline by adjusting `phaseBias` and `smoothLen`. Then match the band distance by adjusting
`innerMult` and `outerMult`. The weights mostly change the shape of the bands during volatility
spikes, not their average width.

## Caveats

- Signals use the current bar's `close`, so a signal can appear and disappear while a bar is
  still open in real time. Set alerts to *Once Per Bar Close*.
- This is a mean-reversion overlay. In a strong trend, price can ride or repeatedly cross a band
  and produce a series of losing reversal signals. Backtest it before you trade it.
