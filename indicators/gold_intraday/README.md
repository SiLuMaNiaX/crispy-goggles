# Gold scalping and intraday: finding the best MT5 setup

**Data:** PAXG/USDT 5m candles, Jun 2024 → Nov 2026, with weekend bars removed. PAXG is a gold-backed token used as a stand-in for XAUUSD. Sessions use real London and New York local time, including daylight saving.

**Execution in the tests**
- Entries happen at the next open, or as stop/limit orders filled at the trigger price or worse.
- If a bar touches both the stop and the target, the stop is assumed to come first.
- A stop touched on the entry bar counts.

**Costs:** $0.40 per round trip, plus $0.10 slippage on stop-type fills.

## What was tested (about 290 configurations)

| Family | Idea | Configurations |
|---|---|---|
| Scalp ST | SuperTrend flips on 5m, London+NY hours, flat by NY 16:00. With and without a 4H/daily trend filter. | 36 |
| Opening-range breakout | Break of the first 15/30/60 min of London 08:00, COMEX 08:20 or NY 09:30; stop at the other side or the middle; target 1R, 2R or end of session. | 54 |
| Opening-range fade | A limit order *against* the first break; stop 0.5–1 range widths away; target the middle or the other side. | 36 |
| Intraday ST | SuperTrend flips on 15m/30m, London+NY hours, flat by NY 16:00. | 24 |
| Intraday ST + trend | The same, with entries only in the direction of the 4H SuperTrend or the daily EMA(50) slope. | 48 |

The first in-sample run (Jun 2024 → Dec 2025) showed nearly every intraday setup losing in **Jun 2024 → Feb 2025**, and that is the period when PAXG traded in coarse $1 steps with thin volume, a data flaw found in the initial check. So each family was re-scored on **clean data (Mar → Dec 2025)**, and then **once on 2026**. Every family is reported below, with no cherry-picking.

## Results (`research/clean_and_oos.py`, `research/swing_compare.py`)

| Family | PF, clean 2025 (median) | PF, 2026 (median) | Configs profitable in both |
|---|---|---|---|
| **Swing SuperTrend M20–M45** (holds overnight; the existing EA) | **1.32** | **1.29** | **89%** |
| Intraday ST + trend | 1.17 | 1.06 | 48% |
| Intraday ST | 1.13 | 0.92 | 8% |
| Opening-range breakout | 0.96 | 0.90 | 13% |
| Scalp ST (+/− trend) | 0.80–0.90 | 0.82–0.86 | **0%** |
| Opening-range fade | 0.65 | 0.76 | **0%** |

## Conclusions

1. **Scalping gold on 5m loses after realistic costs.** No configuration was profitable in 2026. Spread and commission are too large relative to 5-minute moves. This matches the earlier Highway Matrix and Lorentzian results.
2. **Opening-range strategies don't work on gold here, in either direction.** Breakouts fail, and fading them fails too.
3. **Forcing flat by the end of the day removes the edge.** Gold's tradable edge in these tests is trend persistence that plays out over about a day (median hold about 1 day). Exiting at the NY close cuts those trends off.
4. **Best setup to run on MT5:** `AdaptiveSuperTrendEA.mq5` in its default **swing mode on XAUUSD M30**.
5. **If you must be flat overnight**, use the EA's intraday mode, but expect roughly breakeven. The most consistent intraday preset is M30, factor 2.0, confirm 2, plain SuperTrend, stop 2 ATR, 4H trend filter: PF 1.17 on clean 2025 and 1.18 in 2026, about 140 trades a year, t-stat only 0.6.

## Limits

- **PAXG is not XAUUSD.** Intraday and scalping results depend most on real spreads and session liquidity, so test on your broker's XAUUSD with **real ticks** in the MT5 Strategy Tester.
- **Data is too short for 1-minute work.** About 2.4 years of data, of which only about 21 months are clean. 1-minute scalping was not tested, because PAXG's 1-minute microstructure doesn't represent spot gold.
