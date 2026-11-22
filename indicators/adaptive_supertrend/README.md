# Adaptive SuperTrend: reverse-engineering notes

**Source:** the TradingView script ["SuperTrend" by TheRealDrip2Rip](https://www.tradingview.com/script/4UaDaKOX-SuperTrend/). It was published on 2026-11-21 as a public indicator script and had 788 boosts when checked.

This rebuild is based on the published description only; the author's source code was not used. Any detail the description doesn't specify is marked `[ASSUMED]` in `adaptive_supertrend.pine`.

## How it works (as described by the author)

| Piece | Described behaviour | Rebuild |
|---|---|---|
| Adaptive band | ATR(14) vs its 50-bar average. The multiplier widens to 1.4× in high volatility and tightens to 0.75× in low. | `factor = base × clamp(ATR / SMA(ATR, 50), 0.75, 1.4)`. The description gives the bounds, not the mapping; a linear clamp is assumed. |
| Adaptive confirmation | Kaufman Efficiency Ratio (ER) over 10 bars: more confirmation bars in chop, fewer in clean trends. | ER < 0.30: base + 1 bars. ER > 0.60: base − 1 (minimum 1) `[ASSUMED]`. |
| Line vs colour | The line moves as soon as price closes through the band. Colour, labels and alerts wait for confirmation. | The raw direction moves the line. The confirmed direction drives colour, labels and alerts. |
| Flip quality | Weighted score: efficiency 50%, normal volatility 30%, 5-bar momentum relative to ATR 20%. A ≥ 70, B 50–69, C < 50. | ER×100. Volatility scores 100 at an ATR ratio of 1, falling linearly to 0 at a deviation of ±0.5. Momentum scores full marks at 2 ATR in the flip direction. Both scalings `[ASSUMED]`. |
| Conviction / shading | Builds with trend age and efficiency. | `0.5 × min(age/50, 1) + 0.5 × average ER since the flip` `[ASSUMED]`. |
| Dashboard | Direction, age, conviction, efficiency, volatility, factor, last flip, distance, flip counts. Header shows F and C. | Same fields. |
| Alerts | Long Signal, Short Signal, Any Flip. | Same names. |

## Things to know before trading it

- **Not repainting, but the line can jump.** Calculations use only past bars, so it doesn't repaint. The *line* can still jump to the other side and then jump back before a flip is confirmed. Labels and colour only change on confirmation.
- **The flip grade is descriptive.** It describes market conditions at the moment of the flip. The description makes no claim that grade A flips perform better, and that is untested.
- **Use bar-close alerts.** The author warns that signals can change until the bar closes. Set alerts to *Once Per Bar Close*.
