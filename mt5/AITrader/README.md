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
- The per-stage model overrides (*Primary model for SCAN / ENTRY / MANAGE*) apply only to the primary provider. The backups always use their own *Model* input.
- The dashboard shows the chain (`asAi > DeepSeek > OpenRouter`, with `(down)` next to any provider that is being skipped) and which provider/model answered last.

```
 every new bar of the scan timeframe (H1 by default)
 ┌──────────────┐   1 AI call   ┌──────────────────┐  1 AI call per pick  ┌─────────────────┐
 │ 1. SCAN      │ ────────────► │ 2. ENTRY         │ ───────────────────► │ hard-limit check │ ──► order
 │ indicators   │   AI picks    │ full context per │  BUY/SELL/HOLD,      │ risk cap, SL/ATR,│     (or DRY-RUN log)
 │ for every    │   ≤ N symbols │ candidate +      │  risk %, SL, TP      │ R:R, margin,     │
 │ symbol       │   + bias      │ open positions   │                      │ portfolio risk   │
 └──────────────┘               └──────────────────┘                      └─────────────────┘

 every new bar of the manage timeframe (M15 by default), for each open position
 ┌──────────────────┐  1 AI call  ┌──────────────────────────────────┐
 │ 3. MANAGE        │ ──────────► │ HOLD / CLOSE / PARTIAL / MODIFY   │ ──► validated: the SL can only tighten,
 │ position + bars  │             │ (+ new SL / TP / close fraction)  │     TP must be valid, lot split must be valid
 └──────────────────┘             └──────────────────────────────────┘

 every timer tick (15 s), no AI involved
 4. HARD CLOSES: daily loss limit → close all and halt · max hold time · Friday close
```

## What the AI decides and what the EA enforces

| Stage | AI decides | EA enforces (the AI cannot override these) |
|---|---|---|
| Scan | Which symbols have the best setups, the bias, a score, and a short market view | Symbols outside the watchlist are ignored; candidates below *Min scan score* or already holding a position are skipped |
| Entry | Direction, confidence, **risk %**, SL, TP | Risk ≤ per-trade cap and ≤ remaining portfolio budget; confidence above the minimum; SL/TP on the correct side; SL 0.5–3 ATR from entry; R:R ≥ 1.5; spread ≤ 0.15 ATR; lot always rounded **down**; margin check |
| Manage | Hold, close, partial close, move SL/TP | The SL can only **tighten**, never widen; TP and SL must clear the broker's stop level; both parts of a partial close must be ≥ the minimum lot; actions below *Min manage confidence* are ignored |
| Close | Exits based on its own analysis | Daily loss limit (closes all, no new trades for the rest of the day), max hold time, Friday cutoff |

The portfolio limits are max positions, max trades per day, max total open risk (3% by default), entry hours and the daily AI call budget.

## Setup

1. Copy `AITraderEA.mq5` into `<Data Folder>\MQL5\Experts\`, open it in MetaEditor and compile it with **F7**.
2. **Tools → Options → Expert Advisors**:
   - ✅ **Allow algorithmic trading**. This box is unchecked in your screenshot.
   - ✅ **Allow WebRequest for listed URL**: **add `https://serveras.click`**. This is the asAi API host, which is different from the `serverasai.com` dashboard site. Keep `https://api.deepseek.com` and `https://openrouter.ai`, which you already have.
3. Create the three key files in `<Common>\Files` (usually `%APPDATA%\MetaQuotes\Terminal\Common\Files`). Put each key alone on one line, using the file names in the table above. You can paste keys into the inputs instead, but they are then saved in plain text with the chart settings.
4. In asAi → **Models**, copy the exact model ID you want and paste it into *Provider 1 → Model id*. The default `deepseek-chat` is only a placeholder.
5. Set **Watchlist** to your broker's exact symbol names, for example `XAUUSDm,EURUSDm` if your broker adds a suffix.
6. Attach the EA to **one** chart. Any symbol works; that chart's symbol only provides the bar timing. Tick *Allow Algo Trading* in the EA's Common tab.
7. Run with **Dry run = true** on a demo account for at least 1–2 weeks. Then review `MQL5\Files\AITraderEA_log.csv`, which records every scan, entry, hold, rejection, management action and close.

The chart shows a live dashboard: mode, day P/L, open risk, positions, AI calls used, the last scan result and the last event.

## Choosing models and cost

- **asAi**: any model listed on its Models page. Your asAi dashboard says keys have **no spending limit**, so create a separate asAi key just for this EA. That way you can revoke it on its own, and *Max AI calls per day* is your only spending cap. If asAi rejects requests with HTTP 400, its proxy may not accept `response_format`: set *Request JSON response_format* to false.
- **DeepSeek direct**: `deepseek-chat`. It's cheap and fast, and supports JSON mode.
- **OpenRouter**: one key for many models. Set *Default model* to any slug from openrouter.ai/models. You can also use a cheaper model for SCAN and MANAGE (which run often) and a stronger one for ENTRY (which runs rarely), via *Model for SCAN / ENTRY / MANAGE*.
- Expected number of calls per day with the defaults (H1 scan, M15 manage, 20 trading hours):
  - about 20 scan calls
  - up to 2 entry calls per scan
  - up to 4 manage calls per hour for each open position

  The hard cap is *Max AI calls per day* (150 by default).
- Reasoning models (such as `deepseek-reasoner` and other models that "think") are slow and sometimes ignore JSON mode. If you see `PARSE_ERROR` in the log, set *Request JSON response_format* to false or switch models.

## Key inputs

| Group | Input | Default |
|---|---|---|
| Scanner | Watchlist | XAUUSD, EURUSD, GBPUSD, USDJPY, AUDUSD, USDCAD, XAGUSD |
| | Scan/entry timeframe | H1 |
| | Max candidates per scan / min score | 2 / 0.6 |
| | Entry hours (server time) | 01–21 |
| Management | Manage timeframe | M15 |
| | Min manage confidence | 0.6 |
| | Max hold hours / Friday close hour | 48 / 20 |
| | Mechanical breakeven at R | 0 (left to the AI) |
| Hard limits | **Dry run** | **true** |
| | Max risk per trade / total open risk | 1% / 3% |
| | Min entry confidence / min R:R | 0.65 / 1.5 |
| | SL distance | 0.5–3.0 × ATR |
| | Max positions / trades per day | 3 / 6 |
| | Daily loss limit / close all when hit | 3% / true |
| | Max spread (fraction of ATR) | 0.15 |

## Limitations

- **The Strategy Tester can't run WebRequest**, so this EA can't be backtested. The only way to validate it is forward-testing in dry run or on a demo account.
- WebRequest is synchronous. One cycle with a scan, two entry calls and several manage calls can take a minute or more, and the EA does nothing else during that time. The hard closes run between cycles, and the SL/TP orders sitting at the broker still protect every position.
- If the API is unreachable or returns errors, the EA opens nothing and makes no AI management changes. Existing SL/TP orders and the hard closes keep working.
- Each key is sent only to its own provider. Your market data and account summary (equity, P/L, positions) go to whichever provider answers.
- An AI model has no proven edge in forecasting markets. This EA's job is to make sure that whatever the model says, losses stay inside the limits you set.
