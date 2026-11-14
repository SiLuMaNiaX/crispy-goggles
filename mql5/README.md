# XAUUSD M1 Market Phases: MT5 indicator + EA

A port of the Pine v6 indicator "XAUUSD M1 - Economics + Structure + Market Phases".

| File | What it is |
|---|---|
| `Indicators/XAUUSD_M1_MarketPhases.mq5` | The indicator. It holds all the signal logic and draws the arrows, the dashboard and the optional phase background. It can run on its own. |
| `Experts/XAUUSD_M1_MarketPhases_EA.mq5` | The EA. It reads the indicator with `iCustom` and only places and manages trades. |

## Install
1. Copy `Indicators/XAUUSD_M1_MarketPhases.mq5` to `MQL5/Indicators/`.
2. Copy `Experts/XAUUSD_M1_MarketPhases_EA.mq5` to `MQL5/Experts/`.
3. Compile both in MetaEditor (F7). Compile the indicator first.
4. To see signals only, attach the indicator to an XAUUSD M1 chart.
5. To trade them, attach the EA instead. By default it also adds the indicator to the chart (`InpShowIndicatorOnChart`), so don't attach the indicator separately as well.

The EA has the same indicator inputs and passes them through, so set them on the EA.

## Indicator buffers (for `iCustom` / `CopyBuffer`)
| # | Buffer | Value |
|---|---|---|
| 0 | Confirmed BUY | bar low, or `EMPTY_VALUE` |
| 1 | Confirmed SELL | bar high, or `EMPTY_VALUE` |
| 2 / 3 | Early bull / bear warning | price, or `EMPTY_VALUE` |
| 4 / 5 | Bullish / bearish structural break | price, or `EMPTY_VALUE` |
| 6 / 7 | Failed bullish / bearish breakout | price, or `EMPTY_VALUE` |
| 8 | Phase | 0 unclassified, 1 range after decline, 2 markup, 3 range after advance, 4 markdown, 5 bull transition, 6 bear transition |
| 9 | Trend bias | -1 / 0 / 1 |
| 10 | Signal type | bitmask: 1 continuation, 2 reversal, 4 range breakout. Positive = BUY, negative = SELL |
| 11 | ATR | Wilder RMA, same as Pine `ta.atr` |
| 12 | Directional efficiency | 0..1 |
| 13 | Range detected | 0 / 1 |
| 14 | Structure | 1 HH+HL, -1 LH+LL, 0 mixed |
| 15 | Candle pressure | 1 buying, -1 selling, 0 weak |

Only closed candles are calculated. The forming candle is `EMPTY_VALUE` in every buffer, so read shift 1 for the latest signal. If a "Show ..." input is off, that plot is hidden but its buffer still holds data.

## How the logic maps from Pine
- `barstate.isconfirmed` → each closed bar is processed once, oldest to newest, so `var` state (swings, bias, phase, active breakout, last signal) behaves the same.
- `ta.atr` → Wilder RMA computed in code. MT5's `iATR` uses an SMA, so it isn't used.
- `ta.pivothigh/low(n, n)` → the pivot must be strictly beyond the n bars to its left and not exceeded by the n bars to its right. With exactly equal highs or lows, TradingView may pick a different pivot.
- Early warnings only appear on closed bars. They don't repaint.

## Trading layer (EA only, not part of the original indicator)
- Enters on confirmed BUY / SELL. Continuation, reversal and range breakout can each be turned on or off.
- Stop = `InpSL_ATR` × ATR. Target = `InpTP_R` × the stop distance.
- Size: risk % of balance, or a fixed lot.
- Optional: close (and reverse) on an opposite signal, close on a failed breakout against the position.
- Spread filter, session-hours filter, one position per magic number.
- It never trades the candle that was already closed when the EA started.

Backtest it in the Strategy Tester (use "Every tick based on real ticks" for M1 gold) before running it live.
