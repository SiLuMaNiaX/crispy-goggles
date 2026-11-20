# Highway Matrix: reverse-engineering notes

Source: a 91-second screen recording, `Ultimate_CEO_Highway.mp4` (1280×694, 30 fps). It shows TradingView with XAUUSD, 5m, Pepperstone, and Malay voice-over captions. The indicator on the chart is called **"UC Highway Matrix"**. The browser tabs show it is part of a paid "UltimateCEO Highway Pivot" family.

No source code was available. Everything below comes from the frames, the input values printed in the indicator's status line, and the narration. `highway_matrix.pine` rebuilds it without using any original code.

## What's on screen

| Element | Look | Most likely mechanism |
|---|---|---|
| Outer bands | Thick green curves, very smooth, wave-shaped | Kernel (Nadaraya-Watson-style) regression ± k × MAE |
| Inner bands | Thin grey curves inside the green ones | Same centre line, smaller multiplier |
| Sell zone | Red fill between the upper green and upper grey | Area between the upper outer and upper inner bands |
| Buy zone | Teal fill between the lower grey and lower green | Area between the lower inner and lower outer bands |
| "Highway" | Two parallel **stepped** blue lines with a grey fill | A higher-timeframe value held for each HTF bar (steps at HTF closes), ± a width |
| `H-Sell` / `H-Buy` labels | Placed on the exact swing high or low inside a zone | A reversal from the zone in the trend direction |
| `Sell` / `Buy` (no H) | Smaller labels, mostly in ranges | Counter-trend or sideways version of the same trigger |
| Red box to the right of the last bar | The sell zone projected forward | A box drawn on the last bar |
| Dotted line past the last bar | A ~120-bar "future" price path | Pattern-match ("echo") forecast |
| `HIGHWAY TREND DASHBOARD` | Middle Right, Small: `current trend = sideway` / `waiting` | A table showing trend state and status |

### Status-line inputs (read from the chart)

```
UC Highway Matrix 100 50 1,500 Price 2 2 0.4 1,500 4 2 4 2 4 2 200 2 30 close 5 0.9 6 0
                  Middle Right Small 5 13 34 1 3 8 5 13 8 Normal 1,000 120
```

How I read them:

- `1,500`: max bars back / calculation window.
- `4 2 4 2 4 2`: three band pairs (width and multiplier).
- `200 2 30 close`: the highway. Length 200, multiplier 2, a **30-minute** timeframe, close source. This matches the step spacing seen on the 5m chart.
- `Middle Right Small`: dashboard position and size. This is certain.
- `5 13 34` and `1 3 8 5 13 8`: Fibonacci EMAs, and what looks like Alligator-style length/offset pairs (13/8, 8/5, 5/3). Probably used as a momentum filter.
- `1,000 120`: forecast search lookback and horizon. The dotted path runs about 120 bars to the right.

### The trading rules in the narration (translated)

- "This indicator gives entries that follow the trend when price is in the trend zone and sits in the **sell zone**. That's the entry with the highest win rate and lowest risk."
- "You can counter-buy, and the **highway trend zone** …"
- "Wait for price to come up to the sell box first, *then* enter the sell."
- "Enter when the signal appears."

So the strategy is: take the trend from the highway, wait for a pullback into the opposite zone, and enter on the reversal signal.

## ⚠️ The main finding: the bands almost certainly repaint

Several things in the video point to a centred, two-sided kernel that uses **future bars**:

1. The bands bend to fit every swing. Each `H-Sell` sits exactly on a local top, each `H-Buy` on an exact bottom.
2. The curves are sinusoidal "bulges" that peak in the same place as price. A causal filter lags. These don't.
3. Between scrolls the right-hand end of the bands bends sharply (the "nampak dia terlajak" / "see how it overshoots" segment, ~84s). This is the edge effect of a two-sided kernel that runs out of future data.

The rebuild has both modes, so you can compare them:

- **Non-repainting (default):** a one-sided Gaussian kernel. It is tradable, but it lags and looks much less "perfect".
- **Repainting (video look):** on the last bar it redraws a centred kernel over the whole window and labels hindsight swing points. It reproduces the video's look. **Do not backtest it or trade from it.** The signals only exist after the fact.

## The rebuild (`highway_matrix.pine`)

Pine Script v6. Paste it into the TradingView Pine editor.

- **Envelope:** a Gaussian kernel with bandwidth `20` over a `500`-bar window. MAE-scaled inner (1.5×) and outer (3×) bands.
- **Highway:** on the 30m timeframe, `EMA(20) ± 0.5×ATR(14)`, taken from the previous HTF bar so it doesn't repaint. Drawn as step lines.
- **Trend:** up if price is above the highway and the centre line is rising. Down if price is below the highway and the centre line is falling. Otherwise sideways.
- **Signals:** after a bar pierces a zone, the next bar closes back inside the inner band with a candle in the reversal direction. An optional EMA(5) slope filter and a cooldown apply. Signals in the trend direction are labelled `H-`.
- **Extras:** a projected next-zone box, a dotted echo forecast (the 50-bar pattern with the best correlation over the last 1,000 bars, projected 120 bars ahead), the dashboard, and four `alertcondition`s.

Parameters that are guesses and may need tuning to match the original: the kernel bandwidth, the band multipliers, the highway EMA length and width, and the forecast pattern length.

The script has not been compiled in TradingView from this environment. If the editor reports an error, paste it back and I'll fix it.

## MetaTrader 5 version (`HighwayMatrix.mq5`)

This is a port of the Pine script with the same logic and defaults.

**Install:** in MT5, go to *File → Open Data Folder → MQL5/Indicators*. Copy `HighwayMatrix.mq5` there, open it in MetaEditor and press **F7** to compile. Then drag *Highway Matrix* onto a chart.

Differences from the Pine version:

- **Fills:** MT5 indicator fills can't be transparent, so the zones use dark solid colours. With `Draw candles over fills` on (the default), the chart's *Chart on foreground* setting is switched on so the candles stay visible.
- **Highway data:** the highway reads M30 history directly with `CopyRates` and computes its own EMA and Wilder ATR. It uses the previous completed M30 bar, so it doesn't repaint.
- **Signal text:** signals are arrow buffers, which the Strategy Tester and EAs can read through `iCustom`. The `H-Sell`/`H-Buy` text is drawn with chart objects. Buffers 9–12 are H-Sell, Sell, H-Buy and Buy. Their value is the bar's high or low on a signal bar and `EMPTY_VALUE` otherwise.
- **Alerts:** a popup alert, plus an optional push notification, fires when a bar closes with a signal.
- **Performance:** `Max bars to calculate` (default 5000) limits the initial computation. Set it to 0 to calculate the whole history.
- **Forecast:** the echo forecast is recalculated once per new bar, not on every tick. The chart needs right-side shift turned on to show it.
- **Repainting mode:** it rewrites the band buffers for the last `Window` bars on every tick. It's for looks only and must not be used with an EA or the Strategy Tester.

It has not been compiled here because there's no MetaEditor in this environment. If F7 shows errors, send them over.

## Expert Advisor (`HighwayMatrixEA.mq5`)

### How it was validated

All research code is in `research/`. The data was **PAXG/USDT 5m candles** from Binance, Jun 2024 → Nov 2026. PAXG is a gold-backed token, used here because this environment has no direct XAUUSD feed. Weekend bars were removed so the data matches XAUUSD trading hours. Two quality notes on this data: before 2025 it traded in $1 steps with thin volume, and it is a stand-in for spot gold, not spot gold itself.

The data was split into two parts:
- **In-sample:** 2024-06 → 2025-12. All design decisions were made on this part.
- **Out-of-sample:** 2026-01 → 2026-11. It was used **once**, to test candidates chosen in advance.

Trades enter at the next bar's open. If a bar touches both the stop-loss and the take-profit, the backtest counts the stop-loss (the conservative assumption). The base cost is $0.40 per round trip.

### Findings

1. **No repaint.** The non-repainting indicator gives identical signals on truncated history.
2. **The signals as published lose money.**
   - All 5m signals: PF 0.82–0.91 after costs, on every exit model (~4,000 trades).
   - H-signals: only 175 in 2.5 years, roughly breakeven. An H-Sell needs price to tag the *upper* band while also closing *below* the highway, so the two conditions rarely occur together. On M30 the H filter produced 1–3 trades per year.
3. **On 5m, costs eat the edge.** Band touches show about 0.1–0.2 MAE of mean reversion, roughly $0.5–1. The round-trip cost is $0.40.
4. **Gold's bull-market drift inflates long results in-sample.** Shorts lost in almost every configuration in-sample (median PF 0.78).
5. **What survived:** M30 bars, with signals taken only in the direction of the **D1 EMA(50) slope**. The take-profit is the kernel centre line, and the stop-loss sits 0.25 MAE beyond the outer band.

### Results of the chosen setup ($0.40 cost)

| | Trades | Win % | PF | Notes |
|---|---|---|---|---|
| Full 2024-06 → 2026-11 | 349 | 72% | 1.23 | +18.9 R, max drawdown 7.5 R |
| Out-of-sample 2026 (gold −14%) | 109 | 68% | 1.27 | shorts PF 1.42, longs 1.06 |
| 6-month windows | — | — | 1.02 / 1.42 / 1.44 / 1.53 / 1.03 | none negative |
| Cost stress $0 → $1.00 | — | — | 1.31 → 1.11 | |
| Monte Carlo at 0.5% risk/trade | — | — | — | median +9.7% over 2.4 years, P(loss) 6%, 95th-percentile drawdown 7.5% |

**Caveat:** the t-statistic is **1.63**, so the edge is **not statistically proven**. The average gain is small, about 0.05 R per trade, and a 72% win rate with a far-away stop means occasional large losses. Treat it as a candidate to forward-test, not a proven system.

### EA behaviour

- **Signals:** evaluated once per closed M30 bar, using exactly the indicator's maths (`ComputeSignal`). Each entry is a market order at the next bar's open. The stop-loss and take-profit are set on the server.
- **Trade limits:** one position at a time. A position is closed after 48 bars. All positions are closed on Friday at 22:30 server time.
- **Risk:** 0.5% of equity per trade by default. If the minimum lot would risk more than that, the signal is skipped. New entries stop after a 2% daily loss. Entries are blocked when the spread is above $0.60.
- **Original filter:** `Trend filter = Original highway` uses the video's H-signal definition. It is included for comparison only and was not profitable.
- **Mismatch with the indicator:** the indicator's `H-` labels still use the highway filter. The EA's trades correspond to the indicator's arrows (H or plain) that agree with the D1 EMA slope.

### Before going live

1. Compile in MetaEditor (F7). It was not compiled here, because there's no MetaEditor in this environment.
2. Run the Strategy Tester on your broker's **XAUUSD M30** using *Every tick based on real ticks*, and compare against the table above.
3. Forward-test on demo for at least 2–3 months, about 30+ trades.
