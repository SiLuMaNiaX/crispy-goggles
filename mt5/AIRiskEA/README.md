# AIRiskEA: an MT5 Expert Advisor that asks an AI model for trade decisions

On every new bar of the timeframe you choose, the EA:

1. Collects market data: the last N closed bars, today's and recent daily OHLC, ATR14, RSI14, EMA 20/50/200, spread, and account equity and daily P/L.
2. Sends that data to an AI model through MT5's **WebRequest**, using either **DeepSeek** (`https://api.deepseek.com`) or **OpenRouter** (`https://openrouter.ai`).
3. Receives a JSON decision: `action` (BUY/SELL/HOLD), `confidence`, `risk_percent`, `sl`, `tp` and `reason`.
4. **Checks that decision against hard limits written into the EA.** The AI picks the direction and the risk, but no AI answer can go past these limits:
   - the risk is capped at *Max risk per trade*
   - trades below *Min AI confidence* are rejected
   - the SL and TP must be on the correct side of price, outside the broker's stop level, and the SL must be between the min and max ATR multiples
   - the reward:risk ratio must be at least *Min reward:risk*
   - limits on spread, trading hours, open positions, trades per day and daily loss
5. Sizes the lot so that hitting the SL loses exactly the approved % of equity. It always rounds the lot **down**, then shrinks it further if there isn't enough free margin.
6. Places the order. In **dry-run mode** (the default) it only logs the order it would have placed.
7. Optionally moves the SL to breakeven once the trade has moved +1R.

Every decision is written to `MQL5\Files\AIRiskEA_log.csv`, including HOLDs, rejections and failed orders.

## Setup

1. **Copy** `AIRiskEA.mq5` to `<Data Folder>\MQL5\Experts\`. To find the data folder, open MT5 and use File → Open Data Folder. Then open the file in MetaEditor and press **F7** to compile it.
2. **Tools → Options → Expert Advisors** (the dialog in your screenshot):
   - ✅ **Allow algorithmic trading**. This box is currently *unchecked* in your screenshot, and the EA can't send orders without it.
   - ✅ **Allow WebRequest for listed URL** with `https://api.deepseek.com` and/or `https://openrouter.ai`. You already have both listed. ✔
   - DLL imports are not needed, so leave that box off.
3. **API key**. Use either of these:
   - Paste the key into the EA's **API key** input. Note that the key is then saved in plain text in chart/.set files.
   - Or, safer: leave that input empty and save the key alone on one line in `<Common>\Files\airiskea_key.txt`. The Common folder is usually `%APPDATA%\MetaQuotes\Terminal\Common\Files`.
4. Attach the EA to an **XAUUSD** chart and tick "Allow Algo Trading" in its Common tab.
5. Leave **Dry run = true** for a few days. Read the Experts log and the CSV to see what the AI would have done before you switch dry run off.

## Main inputs

| Input | Default | Notes |
|---|---|---|
| Provider | DeepSeek | Or OpenRouter, which gives you access to many models (Claude, GPT, DeepSeek, …) |
| Model | `deepseek-chat` / `deepseek/deepseek-chat` | For OpenRouter, any model slug from openrouter.ai/models |
| Decision timeframe | H1 | The EA asks the AI once at the open of each new bar |
| Dry run | **true** | No orders are sent until you turn this off |
| Max risk per trade | 1.0 % | A hard cap; the AI picks a risk between 0 and this value |
| Min AI confidence | 0.65 | |
| Min reward:risk | 1.5 | |
| SL distance | 0.5 – 3.0 × ATR | |
| Max daily loss | 3 % | Measured from equity at the start of the server day; once hit, no new trades that day |
| Max trades/day, max positions | 4, 1 | |
| Max spread | 50 points | Adjust this to your broker's normal gold spread |
| Trading window | 01:00–21:00 server time | Keeps the EA out of the low-liquidity rollover |
| Max AI calls/day | 24 | Limits API cost |
| Breakeven at R | 1.0 | 0 turns it off |

## Limitations

- **WebRequest does not work in the Strategy Tester**, so this EA can't be backtested in MT5. Test it with dry run on a demo account instead.
- WebRequest is synchronous: while the EA waits for the model (up to *HTTP timeout*), that chart's EA is blocked. Other charts are not affected.
- Thinking/reasoning models (for example `deepseek-reasoner`) are slower and may not support JSON mode. If you get parse errors with them, set *Request JSON response_format* to false.
- An LLM has no proven edge in predicting price. The EA's job is to make sure that whatever the model says, the account's risk stays within limits you chose. Run it on a demo account first.
