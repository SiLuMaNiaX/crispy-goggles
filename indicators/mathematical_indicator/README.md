# The Mathematical Indicator: reverse-engineering notes

**Source:** [roan-maverick/tradingview-mathematical-indicator](https://github.com/roan-maverick/tradingview-mathematical-indicator) at commit 8a53719. It's MIT-licensed, written in Pine v6, and has 1,444 lines.

It was promoted alongside a Claude Code "agent" that reads TradingView alert packets. The original post called it "mathematically unbeatable" and claimed a 70% win rate at 1:1.

## How it works (read from the code; `docs/SPECIFICATION.md` matches it)

1. **Story (bias).** Yesterday's daily candle and the last closed 4H candle before the session.
   - If both are the same colour, the bias is that direction.
   - If they disagree, it decides from daily floors and ceilings, then the weekly staircase, then the daily candle.
   - The bias is frozen at the first bar of each session window.
2. **Zone.**
   - **Levels:** floors and ceilings from body turns (green→red = ceiling, red→green = floor) on D, 4H, 1H and the chart timeframe. A level breaks only on a close through it on its own timeframe.
   - **Daily-level block:** no buys near a daily ceiling and no sells near a daily floor (within 0.25 × daily ATR) for the rest of the day.
   - **Clean zones:** entries must be inside a "clean zone", a run of at least 3 same-direction 15m candles moving at least 1.5 ATR.
   - **Pullback mode:** if the pre-session 4H candle already ran in the bias direction, the range must pull back 38.2% into that candle.
3. **Strat (trigger).** Inside the first hour of Asia, London or the NYSE open:
   - **Range:** a 3–20 candle range with 2 or more opposite candles.
   - **Breakout candle:** a strong-bodied candle closes outside the range, and is no bigger than 50% of the range.
   - **Stop order:** placed at the breakout candle's extreme, and only filled after a "rubber band" dip (a wick of at least 0.1 ATR). A break with no dip cancels it.
   - **Stop loss:** at the other end of the breakout candle.
4. **Management.**
   - At 1R: bank 50% and move the stop to entry.
   - The remainder targets the next level, capped at 3R.
   - Other exits: "too fast" (3 straight candles beyond 1.5R) and a 240-minute time exit.
   - Limits: 2 trades per session, one at a time.

**The "AI" part:** the Claude agent prompt only advises (TAKE / WAIT / SKIP) and never places orders. The webhook receiver saves packets to files. It listens on all interfaces, and without `--token` anyone who can reach it can inject signals; the script warns about this.

## Important: the on-chart record can't be traded as scored

- **Fills are decided at the bar close but booked inside the bar.** The rubber-band rule is evaluated at the bar close, yet the fill is booked at the trigger price *inside* that bar. When a bar both dips and breaks, the script assumes the dip came first.
- **No costs:** the record includes no fees or slippage.

`research/mi.py` therefore has two execution models:

| Model | How it fills and manages trades |
|---|---|
| `pine` | Exactly the chart record's bookkeeping. |
| `ea` | What a live EA can actually do. Each 15m bar is replayed through its 5m sub-bars: the stop order is armed only after a real dip, and a break with no prior dip cancels. Management is stop-first. Costs are $0.40 per round trip plus $0.10 slippage. |

**Time alignment:** server time is New York time + 7h, the usual GMT+2/+3 MT5 broker. So the daily candle starts at 17:00 New York and 4H candles start at 17, 21, 01, 05, 09 and 13 New York.

## Results on gold (PAXG proxy, Jun 2024 → Nov 2026)

### Default settings, 15m chart (`research/full.py`)

| | Trades | Win % | PF | Total R | t-stat |
|---|---|---|---|---|---|
| Chart-record scoring, no costs | 24 | 25% | 0.49 | −8.3 | −1.65 |
| Chart-record scoring, with costs | 24 | 25% | 0.40 | −11.0 | −2.15 |
| Realistic EA execution, with costs | 32 | 34% | 0.50 | −11.8 | −1.91 |

**Every year was negative.**

Where setups dropped out over 2.4 years:
- Breakout candles rejected: 504 for being too big, 246 by the daily-level block, 148 for not being in a clean zone, and 7 for missing the pullback depth.
- That left 102 stop orders. Of those, 61 broke with no dip first and 17 closed back inside the range, so only 24 filled.

### Relaxed filters and a 5m chart (`research/variants.py`)

Every variant loses. With the filters relaxed and all sessions enabled, 15m gives PF 0.63 over 415 trades (t = −4.2) and 5m gives PF 0.63 over 629 trades (t = −5.2). That's even with the 5m runs scored the optimistic chart-record way. Exiting at 1:1 makes it worse.

### Independent confirmation

[suenot/mathematical-indicator-check](https://github.com/suenot/mathematical-indicator-check) used its own port and 1-minute data from a different provider. **All 8 combinations of BTC, ETH and two gold tokens on 5m and 15m lost after costs.** The 70% win-rate claim was rejected everywhere: the upper bound of every 95% interval was below 70%. Its security audit found no backdoors, only the webhook caveat above.

## Conclusion

The strategy is carefully built and visually polished, but on gold it is **negative expectancy**. The losses come from the trigger itself, not from costs or one filter. Its on-chart record also scores fills more favourably than a real stop order can achieve.

## MT5 EA (`MathematicalIndicatorEA.mq5`), built on request despite the results above

It follows `research/mi.py` with `exec="ea"`, the realistic model that was backtested, using live ticks in place of 5m sub-bars:

| When | What the EA does |
|---|---|
| Start-up | Replays the last 3,000 M15 bars, with no trading, to rebuild daily/4H/1H/M15 levels, clean zones and session state. |
| Each closed M15 bar | Level feeds (break on close, merge, keep 3+1); clean-zone state machine; session-start story (2 candles → MIXED tie-break → weekly staircase); pre-session "ran" check; daily-level blocks; breakout search; setup cancels (closed back inside the range, 6-bar expiry); too-fast and 240-minute time exits. |
| Each tick, setup working | Rubber-band check: price must first move ≥ 0.1 × ATR against the trade from the bar's open. If price reaches the trigger **before** any dip, the setup is cancelled. If it reaches it after one, the EA enters at market. |
| Each tick, in a trade | At 1R: closes 50% and moves the stop to entry. Touching a nearer level also moves the stop to entry. The stop-loss and target sit on the server. |

**Setup**
- Attach the EA to XAUUSD; the timeframe is set by an input (M15 by default).
- Set `Server GMT offset` and `Server adds +1h in US summer` to match your broker. The defaults fit typical GMT+2/+3 brokers, and the session windows depend on them.
- Risk is 0.5% of equity to the stop by default. A trade is skipped if the minimum lot would exceed that.
- The trade's management state is saved in terminal global variables, so a restart keeps managing an open trade.

**Before relying on it**
- **Not compiled here:** there's no MetaEditor in this environment. Compile it with F7.
- **Expected result:** the backtest is negative (PF ~0.5). Use the Strategy Tester with real ticks, or demo only.
