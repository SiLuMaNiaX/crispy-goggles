# Stop-and-Reverse EA (MT5)

Rebuilt from a screen recording of manual XAUUSD M1 trading. The recording used no indicator: it showed a
market position with a tight stop-loss, plus a pending stop order in the opposite direction parked at that
stop-loss. `StopAndReverseEA.mq5` automates that pattern.

## How a cycle works

1. **Entry**: a market BUY or SELL with SL `InpStopDist` away and TP `InpTakeProfitDist` away.
2. **Reverse order**: a SELL STOP (for a long) or BUY STOP (for a short) is placed at the SL price.
3. **SL hit**: the position closes and the stop order opens the opposite trade, which gets its own SL and
   its own reverse order. This is one flip.
4. **End**: the cycle ends on a take-profit, a manual close, or once `InpMaxFlips` reversals have been used
   (the last trade then has a plain SL). Leftover orders are deleted and the EA waits `InpCooldownBars`.

## Entry modes

| Mode | What starts a cycle |
|---|---|
| `ENTRY_SPIKE_FADE` (default) | Over the last `InpLookback` bars the range is at least `InpSpikeAtr` × ATR, the extreme is at most `InpMaxBarsSinceExt` bars old, and price has pulled back `InpPullbackAtr` × ATR from it. The EA trades against the spike, as in the video. `InpInvertSignal` makes it follow the spike instead. |
| `ENTRY_ALWAYS_BUY` / `ENTRY_ALWAYS_SELL` | A new cycle starts as soon as the cooldown and filters allow. |
| `ENTRY_MANUAL` | You open the trade yourself (magic 0). The EA adds the SL/TP if missing and handles the reversals. |

## Key inputs

- `InpLots`, `InpLotMultiplier`, `InpMaxLots`: lot size per flip is `InpLots × multiplier^flip`, capped.
  The default multiplier of 1.0 keeps lots flat. 2.0 is a martingale and can wipe out an account.
- `InpRecoverLosses`: widens the TP after each flip so one win covers the cycle's losses so far.
- `InpMaxSpread`, `InpStartHour`/`InpEndHour`, `InpMaxDailyLossPct`: filters that only block new cycles.

All distances (`InpStopDist`, `InpTakeProfitDist`, `InpReverseOffset`, `InpMaxSpread`, `InpMaxSlippage`) are in
**price units**, not points: 1.50 means a $1.50 move on gold whether the broker quotes 2 or 3 decimals
(e.g. `XAUUSD` or a cent `XAUUSDc`). Defaults: SL 1.50, TP 2.00, max spread 0.40, max slippage 0.30.

## Install

1. Copy `StopAndReverseEA.mq5` into `MQL5/Experts/` (File → Open Data Folder in MT5).
2. Open it in MetaEditor and compile (F7).
3. Attach it to an XAUUSD M1 chart and enable Algo Trading.

Use a **hedging** account. On a netting account the reverse stop order can net against the open position.
Run it in the Strategy Tester ("Every tick based on real ticks") and on a demo before going live. Tight-stop
reversal systems lose to the spread and to whipsaws in ranging markets.
