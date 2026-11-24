# AITraderEA: an AI-driven MT5 pipeline from scanning to entry, management and exit

One EA, attached to a single chart, that trades a whole watchlist. It calls an AI model through MT5's **WebRequest** at four stages, and checks every AI answer against hard limits in the code before anything reaches the broker.

## AI providers and failover

Each AI call tries the providers in this order:

| Order | Provider | Endpoint | Key file in `<Common>\Files` |
|---|---|---|---|
| 1 (primary) | **asAi** | `https://serveras.click/v1/chat/completions` | `aitrader_key_asai.txt` |
| 2 (backup) | DeepSeek | `https://api.deepseek.com/chat/completions` | `aitrader_key_deepseek.txt` |
| 3 (backup) | OpenRouter | `https://openrouter.ai/api/v1/chat/completions` | `aitrader_key_openrouter.txt` |

- A provider counts as failed if it times out, returns an HTTP error, or replies without JSON. The EA then moves straight to the next provider, and skips the failed one for *Skip a failed provider for N minutes* (10 by default), so you don't wait on a timeout for every call.
- A provider without a key is left out of the chain. The EA only refuses to start if no provider has a key.
### Multi-model setup: each provider has a job

| Stage | Runs on (default) | Why |
|---|---|---|
| SCAN (each new bar of the mode's scan timeframe) | **DeepSeek** | Runs often and ranks a table; a cheap, fast model is enough |
| ENTRY | **asAi** (`asai/gpt-6.2-astra`) | The decision that commits money; give it your strongest model |
| ENTRY second opinion | **OpenRouter** (`google/gemini-4-carbon`), or the next provider if OpenRouter answered the first call or is down | A different model family checks the trade, so one model cannot open a trade on its own |
| MANAGE (each new bar of the mode's manage timeframe, per position) | **DeepSeek** | High volume; HOLD is the usual answer |

Each stage still fails over to the other providers when its first choice is down. You can change the routing in *Multi-model routing*.

**Entry consensus** (*ENTRY needs a 2nd model to agree*, on by default): after the first model proposes a BUY or SELL, a model from a **different provider** gets the same data and is told to judge it independently.
- If it says HOLD, the opposite direction, or something that can't be parsed, the trade is **rejected**, and the log records both opinions.
- If it agrees, the trade uses the **lower** confidence and the **lower** risk % of the two models, plus the first model's SL/TP. Those then go through the hard-limit checks as usual.
- If no second provider is reachable, the default is to trade on the single opinion. Set *If no 2nd provider is available: true = skip trade* to skip the trade instead.

Each trade with consensus costs 2 entry calls. For the most independent second opinion, use a different model family on the reviewing provider, for example a Claude or GPT model through OpenRouter (*Provider 3 → Model slug*) while asAi/DeepSeek run DeepSeek models.

- The per-stage model overrides (*Primary model for SCAN / ENTRY / MANAGE*) apply only when asAi answers. The backups always use their own *Model* input.
- The dashboard shows the chain (`asAi > DeepSeek > OpenRouter`, with `(down)` next to any provider that is being skipped) and which provider/model answered last.

```
 every new bar of the scan timeframe (set by the trading mode)
 ┌──────────────┐   1 AI call   ┌──────────────────┐  1 AI call per pick  ┌─────────────────┐
 │ 1. SCAN      │ ────────────► │ 2. ENTRY         │ ───────────────────► │ hard-limit check │ ──► order
 │ indicators   │   AI picks    │ full context per │  BUY/SELL/HOLD,      │ risk cap, SL/ATR,│     (or DRY-RUN log)
 │ for every    │   ≤ N symbols │ candidate +      │  risk %, SL, TP      │ R:R, margin,     │
 │ symbol       │   + bias      │ open positions   │                      │ portfolio risk   │
 └──────────────┘               └──────────────────┘                      └─────────────────┘

 every new bar of the manage timeframe (set by the trading mode), for each open position
 ┌──────────────────┐  1 AI call  ┌──────────────────────────────────┐
 │ 3. MANAGE        │ ──────────► │ HOLD / CLOSE / PARTIAL / MODIFY   │ ──► validated: the SL can only tighten,
 │ position + bars  │             │ (+ new SL / TP / close fraction)  │     TP must be valid, lot split must be valid
 └──────────────────┘             └──────────────────────────────────┘

 every timer tick (15 s), no AI involved
 4. HARD CLOSES: daily loss limit → close all and halt · max hold time · Friday close
```

## Strategy profile: trading mode, session bias and risk profile

Three selectors at the top of the inputs control how the EA trades. Each one changes the EA's hard limits **and** is described to the AI at the start of every request, so the scan, entry and management stages all work to the same style.

### 1. Trading mode

| Mode | Scan TF | Manage TF | SL distance | Min R:R | Max hold | Max spread | Trades/day | Timer | AI calls/day |
|---|---|---|---|---|---|---|---|---|---|
| **Superscalping** | M1 | M1 | 0.5–1.5 ATR | 1.0 | 30 min | 0.30 ATR | 30 | 3 s | 1500 |
| **Scalping** | M5 | M1 | 0.6–2.0 ATR | 1.2 | 3 h | 0.20 ATR | 15 | 5 s | 600 |
| **Intraday** (default) | M15 | M5 | 0.7–2.5 ATR | 1.5 | 12 h, flat at session end | 0.15 ATR | 6 | 10 s | 300 |
| **Swing** | H4 | H1 | 1.0–3.5 ATR | 2.0 | 10 days | 0.10 ATR | 3 | 30 s | 80 |
| **Custom** | your inputs | your inputs | your inputs | your inputs | your inputs | your inputs | your inputs | 15 s | 150 |

- In every mode except Swing, positions are **closed when the selected session ends** (*Non-swing modes: close positions when the session ends*).
- Swing can hold over the weekend (*Swing mode: allow holding over the weekend*). The other modes close on Friday at *Friday close hour*.
- *AI calls/day* and *Timer* are the mode's defaults. Set the inputs to a value above 0 to override them.
- Inputs marked **[Custom]** apply only when the mode is Custom.
- **Superscalping caveat:** an AI reply takes about 2–20 s, and with entry consensus each trade needs two replies. On M1 that delay is a large part of the trade's life. The EA re-reads the live price and re-checks the stop-loss and take-profit before sending, so stale signals are rejected rather than filled badly. Even so, superscalping depends on very low spreads and fast AI responses, and it uses the most API calls. Test it in dry run first.

### 2. Session bias (adjusts for daylight saving automatically)

Each session is defined in its own city's **local time**. The EA converts it to GMT every day using that country's daylight-saving rules, so you never need to shift anything by hand.

| Session | Local definition | GMT, winter | GMT, summer | What the AI is told |
|---|---|---|---|---|
| No session bias | *Entries from/until* inputs | server time | server time | Trade any liquid hour |
| Asian | Tokyo 09:00–17:00 (Japan has no DST) | 00:00–08:00 | 00:00–08:00 | Range-bound; favour JPY/AUD/NZD and XAU; fade extremes |
| London | London 08:00–17:00 | 08:00–17:00 | 07:00–16:00 | Highest volume; EUR/GBP/CHF/XAU; London-open breakouts of the Asian range |
| New York | New York 08:00–17:00 | 13:00–22:00 | 12:00–21:00 | USD pairs, XAU, indices; US data spikes at 08:30–10:00 New York time |
| London-NY | London open → New York close | 08:00–22:00 | 07:00–21:00 | Most liquid hours; strongest moves in the overlap |
| Asian-London | Tokyo open → London close | 00:00–17:00 | 00:00–16:00 | The Asian range forms, then London often breaks it |
| NY-Asian | New York open → Tokyo close (overnight) | 13:00–08:00 | 12:00–08:00 | NY momentum, then quieter Asia; avoid the 17:00 New York rollover |

- **UK clocks** change on the last Sunday of March and the last Sunday of October.
- **US clocks** change on the second Sunday of March and the first Sunday of November.
- For 2–3 weeks each spring and autumn the two countries are out of step. During those weeks each session still follows its own city. For example, on 15 March 2026 London is 08:00–17:00 GMT while New York is already 12:00–21:00 GMT.
- The AI is told the actual window for the day and the current time in London (GMT/BST), New York (EST/EDT) and Tokyo. The chart dashboard shows the same clocks.
- New entries are only allowed inside the window, and positions are closed when it ends (except in Swing mode).
- These times rely on your PC's clock and time zone being set correctly, because MT5 works out GMT from the PC clock.

### 3. Risk profile

The Balanced profile uses your inputs as set. The other profiles adjust them:

| Profile | Risk/trade | Min confidence | Min R:R | Max positions | Trades/day | Candidates | Entry consensus | AI behaviour |
|---|---|---|---|---|---|---|---|---|
| **Conservative** (default) | × 0.75 | ≥ 0.72 | +0.3 | ≤ 2 | × 0.6 | score ≥ 0.70 | required | Capital first; trend-aligned only; early partial profits and breakeven |
| **Balanced** | × 1.0 | input (0.65) | mode value | input (3) | mode value | input | input | Clear setups, risk sized to setup quality |
| **Aggressive** | × 1.5 | ≤ 0.60 | −0.3 (min 1.0) | +2 | × 1.5 | +1, score ≥ 0.55 | input | More setups including breakouts and fades; lets winners run; never averages down |

**These limits apply under every profile:** *Absolute ceiling per trade* (2% by default), *Max total open risk* (3%) and the daily loss limit (3%). For example, Aggressive allows 5 positions at 1.5% each, but the 3% total-risk cap means only about 2 of them can be open at full risk.

#### Effective settings with default inputs

| Mode | Profile | Risk/trade | Min conf | Min R:R | Max positions | Trades/day |
|---|---|---|---|---|---|---|
| Superscalping | Conservative | 0.75% | 0.72 | 1.3 | 2 | 18 |
| Superscalping | Balanced | 1.00% | 0.65 | 1.0 | 3 | 30 |
| Superscalping | Aggressive | 1.50% | 0.60 | 1.0 | 5 | 45 |
| Scalping | Conservative | 0.75% | 0.72 | 1.5 | 2 | 9 |
| Scalping | Balanced | 1.00% | 0.65 | 1.2 | 3 | 15 |
| Scalping | Aggressive | 1.50% | 0.60 | 1.0 | 5 | 22 |
| Intraday | Conservative | 0.75% | 0.72 | 1.8 | 2 | 4 |
| Intraday | Balanced | 1.00% | 0.65 | 1.5 | 3 | 6 |
| Intraday | Aggressive | 1.50% | 0.60 | 1.2 | 5 | 9 |
| Swing | Conservative | 0.75% | 0.72 | 2.3 | 2 | 2 |
| Swing | Balanced | 1.00% | 0.65 | 2.0 | 3 | 3 |
| Swing | Aggressive | 1.50% | 0.60 | 1.7 | 5 | 4 |

The chart dashboard shows the active mode, session (open or closed), profile and the effective risk settings.

## What the AI decides and what the EA enforces

| Stage | AI decides | EA enforces (the AI cannot override these) |
|---|---|---|
| Scan | Which symbols have the best setups, the bias, a score, and a short market view | Symbols outside the watchlist are ignored; candidates below *Min scan score* or already holding a position are skipped |
| Entry | Direction, confidence, **risk %**, SL, TP | Risk ≤ per-trade cap and ≤ remaining portfolio budget; confidence above the minimum; SL/TP on the correct side; SL 0.5–3 ATR from entry; R:R ≥ 1.5; spread ≤ 0.15 ATR; lot always rounded **down**; margin check |
| Manage | Hold, close, partial close, move SL/TP | The SL can only **tighten**, never widen; TP and SL must clear the broker's stop level; both parts of a partial close must be ≥ the minimum lot; actions below *Min manage confidence* are ignored |
| Close | Exits based on its own analysis | Daily loss limit (closes all, no new trades for the rest of the day), max hold time, Friday cutoff |

The portfolio limits are max positions, max trades per day, max total open risk (3% by default), entry hours and the daily AI call budget.

## Direct mode (gold-only)

The default watchlist is `XAUUSD`. When **2 or fewer** symbols pass the spread filter (*Skip the AI scanner when this many or fewer symbols are tradeable*), the EA skips the scan stage. On every scan bar, the entry model (asAi) judges each tradeable symbol in either direction, and the second-opinion model (Gemini) must agree before any trade. Set that input to 0 to always use the scanner.

## Market context, news filter and performance tracking

| # | Feature | What the AI or EA gets | Input |
|---|---|---|---|
| 1 | **News filter** | MT5's economic calendar. **New entries are blocked** from 30 min before to 15 min after high-impact USD events. This is a hard rule the AI can't override. The AI is also told what's coming up. | *Block entries around economic news*, currencies, importance, minutes before/after, optional close |
| 2 | **Performance panel** | Closed trades, win rate, net P/L, profit factor, max drawdown and average R for this EA's magic number only, plus a PROOF line (30+ trades, net > 0, PF > 1.2). | *Performance stats from* |
| 3 | **Key levels** | Previous day high/low/close, today open/high/low, week open, previous week high/low, Asian range, London and New York open prices (DST-aware), nearest round numbers. | *Key levels* |
| 4 | **Higher timeframes** | Two higher timeframes (M5 → M15 + H1, M15 → H1 + H4, H4 → D1 + W1): trend, EMA20/50, RSI, 20-bar high/low, last 6 bars. | *Higher-timeframe trend* |
| 5 | **Volume profile** | POC and 70% value area for the previous day and today, built from M1 **tick volume**. On a CFD this is the broker's activity count, not exchange volume. | *Volume profile* |
| 6 | **Tick-flow approximation** | Quote up-ticks vs. down-ticks over 5/15/60 min, plus a 60-min cumulative path. It counts **price changes only, not real traded volume**, and the AI is told to treat it as weak confirmation. | *Tick-flow proxy* |
| 7 | **Self-review** | The entry model sees this EA's last 10 closed trades (side, entry/exit, exit reason, P/L, R, time held) and last-20 stats, with instructions to learn from repeated failures without overreacting to one loss. | *Show the AI its own recent trades* |

Sections 3–6 are also sent to the position manager. Every section can be switched off. More context makes each AI request larger and a little more expensive, and asAi takes slightly longer to reply.

## API keys: where to put them

| Where | Works on | Shown in logs? |
|---|---|---|
| **`AITraderKeys.mqh`**, compiled into the EA (recommended) | PC **and** MQL5 VPS | **No** |
| Key files in `<Common>\Files` | PC only (not copied to the VPS) | No |
| EA inputs (*API key* fields) | PC and VPS | **Yes**: MT5 prints every input in the terminal and VPS log. Don't use these. |

To use the compiled-in option:
1. Copy `AITraderKeys.mqh` next to `AITraderEA.mq5` in `MQL5\Experts`.
2. Paste each key between the quotes and save.
3. Compile `AITraderEA.mq5` with F7, then sync to the VPS.

Keep the *API key* inputs empty. Never share the compiled `.ex5` or a filled-in `AITraderKeys.mqh`.

## Setup

1. Copy `AITraderEA.mq5` into `<Data Folder>\MQL5\Experts\`, open it in MetaEditor and compile it with **F7**.
2. **Tools → Options → Expert Advisors**:
   - ✅ **Allow algorithmic trading**. This box is unchecked in your screenshot.
   - ✅ **Allow WebRequest for listed URL**: **add `https://serveras.click`**. This is the asAi API host, which is different from the `serverasai.com` dashboard site. Keep `https://api.deepseek.com` and `https://openrouter.ai`, which you already have.
3. Create the three key files in `<Common>\Files` (usually `%APPDATA%\MetaQuotes\Terminal\Common\Files`). Put each key alone on one line, using the file names in the table above. You can paste keys into the inputs instead, but they are then saved in plain text with the chart settings.
4. Models are set in the inputs. The defaults are `asai/gpt-6.2-astra` (asAi), `deepseek-chat` (DeepSeek) and `google/gemini-4-carbon` (OpenRouter). You can change them on the EA's Inputs tab without recompiling.
5. Set **Watchlist** to plain names such as `XAUUSD,EURUSD`. The EA adds your broker's suffix or prefix automatically (`XAUUSD` → `XAUUSDc`, `XAUUSD.m`, …). The Experts log shows each mapping as `XAUUSD -> broker symbol XAUUSDc`. You can also type the exact broker names.
6. Attach the EA to **one** chart. Any symbol works; that chart's symbol only provides the bar timing. Tick *Allow Algo Trading* in the EA's Common tab.
7. Run with **Dry run = true** on a demo account for at least 1–2 weeks. Then review `MQL5\Files\AITraderEA_log.csv`, which records every scan, entry, hold, rejection, management action and close.

The chart shows a live dashboard: mode, day P/L, open risk, positions, AI calls used, the last scan result and the last event.

## Choosing models and cost

- **asAi**: any model listed on its Models page. Your asAi dashboard says keys have **no spending limit**, so create a separate asAi key just for this EA. That way you can revoke it on its own, and *Max AI calls per day* is your only spending cap. If asAi rejects requests with HTTP 400, its proxy may not accept `response_format`: set *Request JSON response_format* to false.
- **DeepSeek direct**: `deepseek-chat`. It's cheap and fast, and supports JSON mode.
- **OpenRouter**: one key for many models. Set *Default model* to any slug from openrouter.ai/models. You can also use a cheaper model for SCAN and MANAGE (which run often) and a stronger one for ENTRY (which runs rarely), via *Model for SCAN / ENTRY / MANAGE*.
- Calls per day depend mostly on the trading mode. See *AI calls/day* in the trading mode table; that number is also the hard cap.
  - Each new scan bar costs 1 scan call, plus up to 2 entry calls (with consensus) for each candidate.
  - Each manage bar costs 1 call for each open position.
  - Swing uses the fewest calls and Superscalping the most. Routing scan and manage to a cheap model, as in the defaults, keeps the cost down.
- Reasoning models (such as `deepseek-reasoner` and other models that "think") are slow and sometimes ignore JSON mode. If you see `PARSE_ERROR` in the log, set *Request JSON response_format* to false or switch models.

## Key inputs

| Group | Input | Default |
|---|---|---|
| Strategy profile | Trading mode / Session bias / Risk profile | **Intraday / No session bias / Conservative** |
| | Close positions when the session ends (non-swing modes) | true |
| Scanner | Watchlist | XAUUSD, EURUSD, GBPUSD, USDJPY, AUDUSD, USDCAD, XAGUSD |
| | [Balanced] Max candidates per scan / min score | 2 / 0.6 |
| | [No session bias] Entry hours (server time) | 01–21 |
| Management | [Balanced] Min manage confidence | 0.6 |
| | Friday close hour / swing may hold over the weekend | 20 / true |
| | Mechanical breakeven at R | 0 (left to the AI) |
| Hard limits | **Dry run** | **true** |
| | [Balanced] Risk per trade / absolute ceiling / total open risk | 1% / 2% / 3% |
| | [Balanced] Min entry confidence | 0.65 |
| | [Balanced] Max positions | 3 |
| | Daily loss limit / close all when hit | 3% / true |
| Custom mode | Timeframes, bars, SL ATR range, R:R, hold hours, spread, trades/day | used only when Trading mode = Custom |

## Limitations

- **The Strategy Tester can't run WebRequest**, so this EA can't be backtested. The only way to validate it is forward-testing in dry run or on a demo account.
- WebRequest is synchronous. One cycle with a scan, two entry calls and several manage calls can take a minute or more, and the EA does nothing else during that time. The hard closes run between cycles, and the SL/TP orders sitting at the broker still protect every position.
- If the API is unreachable or returns errors, the EA opens nothing and makes no AI management changes. Existing SL/TP orders and the hard closes keep working.
- Each key is sent only to its own provider. Your market data and account summary (equity, P/L, positions) go to whichever provider answers.
- An AI model has no proven edge in forecasting markets. This EA's job is to make sure that whatever the model says, losses stay inside the limits you set.
