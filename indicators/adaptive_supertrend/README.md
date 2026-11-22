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

## Backtest: does it work, and does the grade matter?

The scripts are in `research/`. `adst.py` is a bar-by-bar Python port of the Pine logic. The other scripts use the gold data and helpers from `../highway_matrix/research`.

**Test setup**
- **Data:** PAXG/USDT, Jun 2024 → Nov 2026, with weekend bars removed.
- **Trading rule:** stop-and-reverse on every confirmed flip, entering at the next bar's open. Positions are closed before the weekend.
- **Cost:** $0.40 per trade.
- **Units:** results are in multiples of ATR at entry.
- **Out-of-sample:** 2026 was held back for a single test of candidates chosen beforehand.

**Findings**

1. **The flip grade has no predictive value.** In-sample, grade C beat grade A on 15m and 30m. Out-of-sample, grade A alone was the best result on 30m (PF 2.23) but lost money on 1h (PF 0.66). Treat the grade as a description of market conditions, not a filter.
2. **The adaptive features don't beat a plain SuperTrend.** Across 162 nearby configurations, adaptive and plain had the same median results (PF about 1.2).
3. **The underlying trend-following is robust on gold.** Every one of the 162 configurations (20m/30m/45m, factor 2.5–4.5, ATR 10–20, confirmation 1–3) was profitable over the full period. 96–100% were profitable in 2026 alone, a year when gold fell 14% and shorts made money too.
4. **The default settings on 30m are a lucky peak.** They gave PF 1.39 overall and 1.51 out-of-sample. Plan around the neighbourhood median of about 1.2, not the peak.
5. **This is a trend-following profile.** The win rate is about 40%, with long losing streaks. In-sample drawdowns reached 50–100 ATR units on the lower timeframes.

## MetaTrader 5 version (`AdaptiveSuperTrend.mq5`)

This is a port of the Pine script with the same maths and inputs.

**What it draws**
- the line, coloured by the confirmed direction
- shading between the line and price
- coloured candles
- LONG/SHORT text labels with the grade and price
- the dashboard
- popup and push alerts when a bar closes with a confirmed flip

The flip arrows are buffers 3 (long) and 4 (short), so an EA can read them with `iCustom`.

**Differences from the Pine version**
- **Opaque shading:** MT5 can't draw transparent fills, so the shading uses dark solid colours and *Chart on foreground* is switched on. Shading intensity doesn't change with conviction.
- **No glow:** the glow effect needs transparency, so it's left out.
- **Side switches:** when the line switches sides, MT5 joins the two sides with a connecting segment. Pine leaves a gap.

The file has not been compiled here, because there's no MetaEditor in this environment.
