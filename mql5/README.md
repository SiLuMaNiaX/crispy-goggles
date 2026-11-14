# XAUUSD M1 Market Phases EA (MT5)

`Experts/XAUUSD_M1_MarketPhases_EA.mq5` is an MQL5 port of the Pine v6 indicator
"XAUUSD M1 - Economics + Structure + Market Phases", plus a trading layer.

## Install
1. Copy the `.mq5` file to `MQL5/Experts/` in your MT5 data folder.
2. Compile it in MetaEditor (F7) and attach it to an XAUUSD M1 chart.
3. Enable Algo Trading.

## How the logic maps from Pine
| Pine | EA |
|---|---|
| `barstate.isconfirmed` | everything runs once per **closed** bar (shift 1) |
| `ta.atr` (RMA) | Wilder RMA computed in code (MT5 `iATR` uses an SMA, so it isn't used) |
| `ta.pivothigh/low(n, n)` | `PivotHigh/PivotLow` (strictly higher than the left bars, not exceeded by the right bars) |
| `ta.highest(high[1], N)` | highest of the N bars before the signal bar |
| `var` state (swings, bias, phase, breakout, last signal) | globals, rebuilt from `InpWarmupBars` of history on start |
| plotshape / bgcolor / table | chart arrows, optional background rectangles, dashboard in the top-right |
| alertcondition | `InpAlerts` pop-ups |

Early warnings only show on closed bars. Pine repaints them on the live candle; the EA does not.

## Trading layer (not part of the original indicator)
- Enters on confirmed BUY / SELL. Each signal type (continuation, reversal, range breakout) can be turned on or off.
- Stop = `InpSL_ATR` × ATR. Target = `InpTP_R` × the stop distance.
- Size: risk % of balance, or a fixed lot.
- Optional: close (and reverse) on an opposite signal, close on a failed breakout against the position.
- Spread filter, session-hours filter, one position per magic number.

Backtest it in the Strategy Tester (use "Every tick based on real ticks" for M1 gold) before running it live.
