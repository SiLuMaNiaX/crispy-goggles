# Lorentzian Classification: reverse-engineering notes

**Subject:** the X post by @chinpan2512 (USDJPY daily chart) promoting **"Machine Learning: Lorentzian Classification" by jdehorty**.
- It's a free, open-source TradingView script: https://www.tradingview.com/script/WhBzgfDu-Machine-Learning-Lorentzian-Classification/
- It has 1.27M views and 37.7K boosts, and was a TradingView Editors' Pick.

Maintained ports, MIT-licensed, including a Pine v6 port and an MQL5 indicator and EA, live at
https://github.com/artificial-intelligence-edge/lorentzian-classification.

`research/lc.py` is my own implementation, written from reading that source. `research/parity.py` checks it against four TradingView export CSVs from the repo (EURUSD 1D ×2, BTCUSD 1D, BTCUSD 1H): **0 mismatches** in prediction, direction, buy and sell across ~20,400 bars and 265 signals. The kernel line and all five features match to ~1e-13.

## What it actually does (verified in the source)

| Claim (post / summary) | Reality in the code |
|---|---|
| "AI / machine learning" | A k-nearest-neighbour vote. 5 features: RSI(14), WaveTrend(10,11), CCI(20), ADX(20), RSI(9). Each is normalised to 0–1, and Lorentzian distance is Σ ln(1+\|Δ\|). |
| "Neighbours labelled by future price direction over 4 bars" | **No.** Each bar's label comes from the *past* 4 bars, and is **inverted**: `src[4] < src[0]` (price *rose*) gives **short**. The number on each candle counts similar-looking bars that had just fallen (+1) or just risen (−1). It's a contrarian vote, not a forecast. |
| "Nearest neighbours" | **Approximate, and unusual.** It accepts only candidates *farther* than the last one accepted, skips every 4th bar, and keeps its 8 votes from one bar to the next (`var` arrays). With long history, the search pool is a fixed block of *old* bars (indices ≈ 2000 … last−2000, scanned downward). The most recent 2,000 bars are never used as neighbours. |
| Number from −8 to +8; near 0 = range | Correct: it's the sum of 8 votes of ±1. |
| Arrows | A signal starts when the vote's sign flips (gated by a volatility filter, a regime filter, and a rational-quadratic kernel slope). The default exit is exactly 4 bars later. |
| "Non-repainting" | Closed bars don't change in real time. But only the last 2,000 bars of the chart get predictions, and the neighbour pool depends on where the chart ends, so **historical signals change when the chart is reloaded with more bars**. |
| Stats panel "Trades 55 (42\|13), WL Ratio 3.23" | **Not a backtest.** "WL Ratio" is the *count* of wins divided by the *count* of losses, not profit. Prices are `(high+low+2×open)/4` of the signal and exit bars, which uses that bar's high and low, information not available at the signal. No costs are included. The author's own tooltip says it is "NOT intended to be used as a replacement for proper backtesting". |

## Backtest: what the arrows really earn (`research/backtest.py`)

**Test setup**
- **Trades:** the indicator's own trades with default settings: enter at the next open after a Buy/Sell label, exit at the next open after its default 4-bar exit.
- **Costs:** realistic costs for each market.
- **History coverage:** charts are "loaded" at successive end points so that every bar is scored once, with no future prices used.

| Market | Trades | Panel-style W/L | Real win % | Real PF | Total | t-stat | Beats random direction |
|---|---|---|---|---|---|---|---|
| EURUSD 1D (2002–2026) | 201 | 2.53 | 53% | 1.20 | +16.5% | 0.93 | 84% |
| BTCUSD 1D | 114 | 4.43 | 47% | 1.41 | +86% | 1.44 | 93% |
| Gold 4H | 60 | 2.75 | 55% | 2.16 | +22.8% | 1.78 | 97% |
| Gold 1H | 410 | 2.38 | 45% | 0.90 | −8.4% | −0.70 | 41% |
| Gold 30m | 895 | 2.16 | 45% | 0.84 | −22.9% | −1.57 | 24% |

### Conclusions

1. **The panel's W/L ratio is badly inflated.** It showed 2.2–4.4 "wins per loss" everywhere, including on gold 30m, where the real result is a loss (PF 0.84). The video's "WL Ratio 3.23" says almost nothing about profitability.
2. **No timeframe shows a statistically significant edge.** All t-stats are below 2. The higher timeframes lean positive (PF 1.2–2.2, but with few trades); 1H and 30m lose after costs.
3. **The edge, if any, is small.** EURUSD daily made +16.5% over 24 years of signals, less than holding EURUSD (+28%).
4. **It isn't real machine learning.** There's no training, validation or forecasting. It's a contrarian vote over feature similarity against an old block of history.

**Bottom line:** it's a well-made, free visual tool. It is not "paid-grade AI", and its arrows don't have a demonstrated edge.
