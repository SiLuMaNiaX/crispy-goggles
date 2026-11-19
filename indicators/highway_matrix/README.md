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
