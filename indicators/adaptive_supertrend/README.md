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

## Expert Advisor (`AdaptiveSuperTrendEA.mq5`)

### Design, chosen on 2024-06 → 2025-12 data only (`research/ea_modes.py`)

| Choice | Tested alternatives | Result (median over 9 TF/factor configs) |
|---|---|---|
| **Exit on the next confirmed flip** (stop-and-reverse) | exit when a bar closes through the line; trailing stop at the line | Confirmed flip PF 1.26 ≈ close-through 1.28. The trailing stop scored 1.12, because intrabar wicks stop it out too often. |
| **Hard stop 2 ATR beyond the line** | 0.5 ATR, 1 ATR | 2 ATR gave the lowest drawdown, with a worst trade of −1.06R. |
| **Hold over weekends** | close on Friday | Closing on Friday dropped PF from 1.26 to 1.10. A trend-follower gives up too many trends by closing. Gaps are modelled, and stops fill at the gap price. |
| **Ignore the flip grade** | trade grade A only | Earlier tests showed the grade has no predictive value. |

### 2026 check and stress tests (`research/ea_oos.py`)

- **2026:** 8 of 9 neighbouring configurations were profitable (median PF 1.29). The 30m / factor 3.5 default gave PF 1.59 on 2026 alone.
- **Full period, 30m / 3.5:** 555 trades, 39% winners, PF 1.48, t-stat 2.84, max drawdown 14.5R, worst trade −1.16R, longest losing streak 11.
- **Cost stress:** PF 1.53 at $0 cost, 1.36 at $1.50.
- **Monte Carlo over ~2.4 years:**

  | Risk per trade | Median return | 95th-percentile drawdown |
  |---|---|---|
  | 0.5% | +46% | 9% |
  | 1% | +112% | 18% |

**Be conservative.** 30m / 3.5 is the best of its neighbourhood. Plan around the neighbourhood median (PF about 1.25), which implies roughly half the Monte Carlo returns above. The data is PAXG, a gold-backed token, not broker XAUUSD.

The EA computes on a rolling window of the last 1,500 bars. `research/window_check.py` confirmed this reproduces full-history flips with 0 mismatches in 1,800 checks.

### EA behaviour

- **Signals:** calculated once per closed bar of the signal timeframe (M30 by default). The maths is the same as `adst.py`.
- **On a confirmed flip:** the EA closes the opposite position, then enters at market with a server-side stop at the line −/+ 2 × ATR. There is no take-profit; the position exits on the next flip or at the stop. After a stop-out it waits for the next flip.
- **Risk:** 0.5% of equity per trade by default, measured to the hard stop. If the minimum lot would exceed that, the trade is skipped.
- **Spread:** if the spread is above $0.60, entry is retried on each tick until the bar ends.
- **Options:** `Adaptive` can be set to false to run a plain SuperTrend, which tested just as well. Friday close is available but off by default.

### Before going live

1. Compile in MetaEditor (F7). It was not compiled here, because there's no MetaEditor in this environment.
2. Run the Strategy Tester on XAUUSD M30 using real ticks, and compare against the numbers above.
3. Demo-trade it for 2–3 months. Expect losing streaks of 10 or more trades.

### Intraday mode (added in v1.10)

`Intraday = true` limits new entries to London 08:00 → New York 15:00 and closes positions at New York 16:00, following `gold_intraday/research/intraday.py`.

**Server time setup:** set `Server GMT offset` (winter) and `Server adds +1h in US summer` to match your broker. The defaults, 2 and true, fit the common GMT+2/+3 brokers. The time-zone conversion was checked against the time-zone database: correct on every trading hour from 2024 to 2026.

**Trend filter:** `Trend filter = 4H SuperTrend` takes only entries in the direction of the 4H SuperTrend(14, 3.5, confirm 2).

**Expectations:** tested close to breakeven (PF ~1.06–1.18). Swing mode (the default) remains the best setup found. See `../gold_intraday/README.md`.

**Suggested intraday preset:** M30, Factor 2.0, Confirm 2, Adaptive false, Stop 2 ATR, Trend filter 4H SuperTrend.
