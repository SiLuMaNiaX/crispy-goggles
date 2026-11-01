# Decycler High-Low Breakout — reverse-engineered reconstruction

A clean-room reconstruction of **"Decycler High-Low Breakout [SchizoQuant]"** ([TradingView](https://www.tradingview.com/script/dOcUNfyv-Decycler-High-Low-Breakout-SchizoQuant/)).
It is built from the author's public description and John Ehlers' published Decycler formula.
The original Pine source was not used or copied, so a constant marked *ASSUMED* is a reasoned
default and may not match the original.

| File | What it is |
|------|------------|
| `decycler_hl_breakout.pine` | Pine Script v6 indicator. Passes compile and lint checks with no diagnostics. |
| `dhlb.py` | Pure-Python port that matches the Pine script bar for bar. It reuses `atr` from `liquid_reversal_bands/lrb.py`. |
| `test_dhlb.py` | Tests for the filter's properties, trend flips, the confirmation gate, breathing room, and repeat suppression. |

```bash
PYTHONPATH=. pytest -q indicators                 # run tests
python -m indicators.decycler_hl_breakout.dhlb     # demo on a synthetic random walk
```

## How it works

```
α  = (cos(0.707·2π/P) + sin(0.707·2π/P) − 1) / cos(0.707·2π/P)
HP = (1−α/2)²·(x − 2x[1] + x[2]) + 2(1−α)·HP[1] − (1−α)²·HP[2]      (2-pole Butterworth high-pass)
Decycler(x) = x − HP                                               applied to high, low and close

slope  = (dcClose − dcClose[slopeLen]) / ATR                       (ATR units)
upper  = dcHigh + ATR·(pad + breath·max(−slope, 0))
lower  = dcLow  − ATR·(pad + breath·max(+slope, 0))

long flip  : close > upper  AND (slope ≥ +thr  OR close > upper + strong·ATR)
short flip : close < lower  AND (slope ≤ −thr  OR close < lower − strong·ATR)
```

1. **Decycler.** Subtracting a 2-pole high-pass filter from price removes cycles shorter than
   the cutoff period and keeps the trend. A linear trend passes through with zero lag, because
   its second difference is zero. The filter runs separately on the high, low and close. The
   filtered close is the centerline, and the filtered high and low anchor the channel.
2. **Slope.** The filtered close's change over `slopeLen` bars, measured in ATRs. This keeps
   the threshold comparable across symbols and timeframes.
3. **Adaptive channel defense.** Both boundaries are padded by `pad × ATR`. The boundary that
   would end the current move also gets *breathing room* that grows with the move's strength. A
   strong uptrend pushes the lower boundary further below price, so an ordinary pullback doesn't
   flip the trend. The opposite boundary is unaffected.
4. **Trend state machine.** The trend flips only when price closes beyond the opposite boundary
   and one of two confirmations holds:
   - the slope agrees past its threshold, or
   - the *strong-breakout override* fires, meaning the close is at least `strong × ATR` beyond
     the boundary even though the slope hasn't caught up.

   A flip fires once, and no repeat signal fires while the trend continues.

## Confirmed vs assumed

| Element | Status | Source |
|---------|--------|--------|
| 2-pole Ehlers Decycler applied separately to high, low and close | Confirmed | Description |
| Decycler formula (α, high-pass recursion, 0.707 factor) | Confirmed | Ehlers, TASC Sept 2015 |
| Filtered close as centerline, filtered high/low as an optional channel | Confirmed | Description |
| Slope of the filtered close, normalized by ATR | Confirmed | Description |
| Flip needs a close beyond the opposite boundary plus slope confirmation or the strong override | Confirmed | Description |
| Channel padding grows with volatility and the strength of the move | Confirmed (concept) | Description |
| Inputs: cutoff, ATR length, padding, slope period, slope threshold, breathing room, strong override | Confirmed (names) | Description |
| Breathing-room formula `breath · max(±slope, 0) · ATR` | **Assumed** | — |
| Strong override as "close at least `strong × ATR` beyond the boundary" | **Assumed** | — |
| Slope measured as a change over N bars, not per bar | **Assumed** | — |
| Defaults: cutoff 60, ATR 14, padding 0.5, slope period 5, threshold 0.25, breathing room 0.5, strong override 1.0 | **Assumed** | Not published |

To calibrate against the original, open both indicators on the same chart.
1. Match the centerline by changing only `cutoff`. The centerline is pure Ehlers math, so once
   the cutoff is right the two lines should overlap exactly. This is the strongest check that
   the reconstruction is on track.
2. Match the channel distance in quiet markets with `padMult`.
3. Match how the channel behaves in trends with `breath`.
4. Match flip timing with `slopeThr` and `strongMult`.

## Caveats

- **Filter overshoot.** A 2-pole Decycler overshoots after a sudden jump. In tests, an
  instantaneous +10 step (about 25× the noise) made the centerline overshoot by about 1.3. That
  dragged the lower boundary above price, and the strong override flipped the trend back
  15 bars later. On real charts, expect occasional false flips right after large gaps or news
  candles.
- Flips are evaluated on the current bar's close, so a flip can appear and disappear while a bar
  is still open in real time. Set alerts to *Once Per Bar Close*.
- This is trend-following. In sideways chop it can flip back and forth repeatedly. Backtest it
  before you trade it.
