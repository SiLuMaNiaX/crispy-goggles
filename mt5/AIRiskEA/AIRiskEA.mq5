//+------------------------------------------------------------------+
//|                                                    AIRiskEA.mq5  |
//|  Asks an LLM (OpenRouter or DeepSeek, via MT5 WebRequest) for a  |
//|  trade decision + risk %, then validates it against hard limits  |
//|  in the EA before placing any order. The AI proposes, the EA     |
//|  disposes: no AI output can exceed the limits set in the inputs. |
//+------------------------------------------------------------------+
#property copyright "AIRiskEA"
#property version   "1.00"

#include <Trade/Trade.mqh>

//--- providers -------------------------------------------------------
enum ENUM_AI_PROVIDER
  {
   PROVIDER_OPENROUTER = 0, // OpenRouter (https://openrouter.ai)
   PROVIDER_DEEPSEEK   = 1  // DeepSeek   (https://api.deepseek.com)
  };

//--- inputs: AI ------------------------------------------------------
input group "AI provider"
input ENUM_AI_PROVIDER InpProvider       = PROVIDER_DEEPSEEK;   // Provider
input string           InpApiKey         = "";                  // API key (leave empty to read from key file)
input string           InpApiKeyFile     = "airiskea_key.txt";  // Key file in <Common>\Files (used if API key empty)
input string           InpModelOpenRouter= "deepseek/deepseek-chat"; // OpenRouter model slug
input string           InpModelDeepSeek  = "deepseek-chat";     // DeepSeek model name
input double           InpTemperature    = 0.2;                 // Temperature
input int              InpMaxTokens      = 400;                 // Max response tokens
input bool             InpJsonMode       = true;                // Request JSON response_format
input int              InpTimeoutMs      = 60000;               // HTTP timeout (ms)

//--- inputs: schedule ------------------------------------------------
input group "When to ask the AI"
input ENUM_TIMEFRAMES  InpTimeframe      = PERIOD_H1;           // Decision timeframe (asks on each new bar)
input int              InpBarsForAI      = 30;                  // Closed bars sent to the AI
input int              InpMaxAICallsDay  = 24;                  // Max AI calls per day (cost control)
input int              InpStartHour      = 1;                   // Trading window start hour (server time)
input int              InpEndHour        = 21;                  // Trading window end hour (server time, exclusive)

//--- inputs: hard risk limits (AI cannot override) -------------------
input group "Hard risk limits"
input bool             InpDryRun         = true;                // Dry run: log decisions, do NOT send orders
input double           InpMaxRiskPct     = 1.0;                 // Max risk per trade (% of equity)
input double           InpMinConfidence  = 0.65;                // Min AI confidence to trade (0..1)
input double           InpMinRR          = 1.5;                 // Min reward:risk
input double           InpMinSlAtr       = 0.5;                 // Min SL distance (x ATR)
input double           InpMaxSlAtr       = 3.0;                 // Max SL distance (x ATR)
input double           InpMaxDailyLossPct= 3.0;                 // Stop for the day after this equity drawdown (%)
input int              InpMaxTradesDay   = 4;                   // Max new trades per day
input int              InpMaxPositions   = 1;                   // Max open positions (this symbol + magic)
input int              InpMaxSpreadPts   = 50;                  // Max spread (points) to enter
input double           InpBreakevenR     = 1.0;                 // Move SL to breakeven at this R (0 = off)

//--- inputs: misc ----------------------------------------------------
input group "Misc"
input ulong            InpMagic          = 26112401;            // Magic number
input int              InpSlippagePts    = 30;                  // Max slippage (points)
input string           InpLogFile        = "AIRiskEA_log.csv";  // Decision log in MQL5\Files

//--- decision returned by the AI -------------------------------------
struct AIDecision
  {
   string            action;     // BUY / SELL / HOLD
   double            confidence; // 0..1
   double            risk_pct;   // % of equity
   double            sl;
   double            tp;
   string            reason;
  };

//--- globals ---------------------------------------------------------
CTrade   g_trade;
string   g_apiKey   = "";
int      g_hATR     = INVALID_HANDLE;
int      g_hRSI     = INVALID_HANDLE;
int      g_hEMA20   = INVALID_HANDLE;
int      g_hEMA50   = INVALID_HANDLE;
int      g_hEMA200  = INVALID_HANDLE;
datetime g_lastBar  = 0;
datetime g_day      = 0;
int      g_callsToday = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_apiKey = InpApiKey;
   if(g_apiKey == "")
      g_apiKey = ReadKeyFile(InpApiKeyFile);
   if(g_apiKey == "")
     {
      Print("AIRiskEA: no API key. Set the 'API key' input or put the key in <Common>\\Files\\", InpApiKeyFile);
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMaxRiskPct <= 0 || InpMaxRiskPct > 5)
     {
      Print("AIRiskEA: Max risk per trade must be in (0, 5] %");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(MQLInfoInteger(MQL_TESTER))
      Print("AIRiskEA: WebRequest does not work in the Strategy Tester; the EA will not trade there.");

   g_hATR    = iATR(_Symbol, InpTimeframe, 14);
   g_hRSI    = iRSI(_Symbol, InpTimeframe, 14, PRICE_CLOSE);
   g_hEMA20  = iMA(_Symbol, InpTimeframe, 20, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA50  = iMA(_Symbol, InpTimeframe, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA200 = iMA(_Symbol, InpTimeframe, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hATR == INVALID_HANDLE || g_hRSI == INVALID_HANDLE || g_hEMA20 == INVALID_HANDLE ||
      g_hEMA50 == INVALID_HANDLE || g_hEMA200 == INVALID_HANDLE)
     {
      Print("AIRiskEA: failed to create indicator handles");
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBar = iTime(_Symbol, InpTimeframe, 0); // wait for the NEXT bar before the first call
   PrintFormat("AIRiskEA started on %s %s via %s, dry run=%s, max risk=%.2f%%",
               _Symbol, EnumToString(InpTimeframe), ProviderName(),
               InpDryRun ? "ON" : "OFF", InpMaxRiskPct);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(g_hATR);
   IndicatorRelease(g_hRSI);
   IndicatorRelease(g_hEMA20);
   IndicatorRelease(g_hEMA50);
   IndicatorRelease(g_hEMA200);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ManageBreakeven();

   datetime bar = iTime(_Symbol, InpTimeframe, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   RollDay();

   string why = "";
   if(!PreChecks(why))
     {
      Print("AIRiskEA: skip - ", why);
      return;
     }

   string context = BuildMarketContext();
   if(context == "")
      return;

   g_callsToday++;
   string content = "";
   if(!CallAI(SystemPrompt(), context, content))
      return;

   AIDecision d;
   if(!ParseDecision(content, d))
     {
      Print("AIRiskEA: could not parse AI reply: ", content);
      LogDecision(d, 0, "PARSE_ERROR");
      return;
     }
   PrintFormat("AIRiskEA: AI -> %s conf=%.2f risk=%.2f%% sl=%s tp=%s | %s",
               d.action, d.confidence, d.risk_pct,
               DoubleToString(d.sl, _Digits), DoubleToString(d.tp, _Digits), d.reason);

   ExecuteDecision(d);
  }

//+------------------------------------------------------------------+
//| Checks that do not need the AI (saves API calls)                  |
//+------------------------------------------------------------------+
bool PreChecks(string &why)
  {
   if(MQLInfoInteger(MQL_TESTER))
     { why = "strategy tester (WebRequest unavailable)"; return false; }
   if(!InpDryRun && (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)))
     { why = "algorithmic trading is disabled (terminal 'Algo Trading' button or EA 'Allow Algo Trading')"; return false; }

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.hour < InpStartHour || t.hour >= InpEndHour)
     { why = StringFormat("outside trading window (%02d:00-%02d:00)", InpStartHour, InpEndHour); return false; }

   if(g_callsToday >= InpMaxAICallsDay)
     { why = "daily AI call budget used"; return false; }
   if(CountOpenPositions() >= InpMaxPositions)
     { why = "max open positions reached"; return false; }
   if(CountTodayEntries() >= InpMaxTradesDay)
     { why = "max trades for today reached"; return false; }

   double dayEq = DayStartEquity();
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayEq > 0 && (dayEq - eq) / dayEq * 100.0 >= InpMaxDailyLossPct)
     { why = StringFormat("daily loss limit hit (%.2f%%)", (dayEq - eq) / dayEq * 100.0); return false; }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)
     { why = StringFormat("spread %d > %d points", (int)spread, InpMaxSpreadPts); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Validate the AI decision against the hard limits and trade        |
//+------------------------------------------------------------------+
void ExecuteDecision(AIDecision &d)
  {
   if(d.action != "BUY" && d.action != "SELL")
     { LogDecision(d, 0, "HOLD"); return; }
   if(d.confidence < InpMinConfidence)
     { Reject(d, StringFormat("confidence %.2f < %.2f", d.confidence, InpMinConfidence)); return; }
   if(d.risk_pct <= 0)
     { Reject(d, "AI risk_percent <= 0"); return; }

   double riskPct = MathMin(d.risk_pct, InpMaxRiskPct); // AI can never exceed the cap
   bool   isBuy   = (d.action == "BUY");
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry   = isBuy ? ask : bid;
   double sl      = NormalizePrice(d.sl);
   double tp      = NormalizePrice(d.tp);

   // SL / TP on the correct side
   if(isBuy  && !(sl < bid && tp > ask)) { Reject(d, "BUY needs sl < bid and tp > ask"); return; }
   if(!isBuy && !(sl > ask && tp < bid)) { Reject(d, "SELL needs sl > ask and tp < bid"); return; }

   // SL distance vs ATR and broker stop level
   double atr = BufferValue(g_hATR, 1);
   double slDist = MathAbs(entry - sl);
   double tpDist = MathAbs(tp - entry);
   if(atr <= 0) { Reject(d, "ATR unavailable"); return; }
   if(slDist < InpMinSlAtr * atr || slDist > InpMaxSlAtr * atr)
     { Reject(d, StringFormat("SL distance %.2f ATR outside [%.2f, %.2f]", slDist / atr, InpMinSlAtr, InpMaxSlAtr)); return; }
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist <= minStop || tpDist <= minStop)
     { Reject(d, "SL/TP inside broker stop level"); return; }
   if(tpDist / slDist < InpMinRR)
     { Reject(d, StringFormat("reward:risk %.2f < %.2f", tpDist / slDist, InpMinRR)); return; }

   // Position size from risk
   double lots = LotsForRisk(isBuy, entry, sl, riskPct);
   if(lots <= 0)
     { Reject(d, "risk too small for minimum lot, or not enough margin"); return; }

   if(InpDryRun)
     {
      PrintFormat("AIRiskEA [DRY RUN]: would %s %.2f lots @ %s sl=%s tp=%s risk=%.2f%%",
                  d.action, lots, DoubleToString(entry, _Digits),
                  DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), riskPct);
      LogDecision(d, lots, "DRY_RUN");
      return;
     }

   string comment = StringFormat("AI %.0f%% r%.2f", d.confidence * 100, riskPct);
   bool ok = isBuy ? g_trade.Buy(lots, _Symbol, ask, sl, tp, comment)
                   : g_trade.Sell(lots, _Symbol, bid, sl, tp, comment);
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      PrintFormat("AIRiskEA: %s %.2f lots placed, ticket %I64u", d.action, lots, g_trade.ResultOrder());
      LogDecision(d, lots, "PLACED");
     }
   else
     {
      PrintFormat("AIRiskEA: order failed, retcode %u (%s)", rc, g_trade.ResultRetcodeDescription());
      LogDecision(d, lots, "ORDER_FAILED_" + IntegerToString(rc));
     }
  }

void Reject(AIDecision &d, string why)
  {
   Print("AIRiskEA: rejected - ", why);
   LogDecision(d, 0, "REJECTED: " + why);
  }

//+------------------------------------------------------------------+
//| Lots so that hitting SL loses riskPct of equity                   |
//+------------------------------------------------------------------+
double LotsForRisk(bool isBuy, double entry, double sl, double riskPct)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   double pnlPerLot = 0.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, sl, pnlPerLot) || pnlPerLot >= 0)
      return 0.0;
   double lossPerLot = -pnlPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots < vmin)
      return 0.0;                     // never round UP past the risk budget
   lots = MathMin(lots, vmax);

   // shrink to fit free margin
   double margin = 0.0, free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lots >= vmin && OrderCalcMargin(type, _Symbol, lots, entry, margin) && margin > free * 0.9)
      lots -= step;
   if(lots < vmin)
      return 0.0;
   return NormalizeDouble(lots, VolumeDigits(step));
  }

int VolumeDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step - MathRound(step)) > 1e-9)
     { step *= 10; d++; }
   return d;
  }

double NormalizePrice(double p)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) return NormalizeDouble(p, _Digits);
   return NormalizeDouble(MathRound(p / tick) * tick, _Digits);
  }

//+------------------------------------------------------------------+
//| Move SL to breakeven once price has moved InpBreakevenR x risk    |
//+------------------------------------------------------------------+
void ManageBreakeven()
  {
   if(InpBreakevenR <= 0 || InpDryRun)
      return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      if(sl == 0) continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double risk = isBuy ? open - sl : sl - open;
      if(risk <= 0) continue;                       // already at/after breakeven
      double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double moved = isBuy ? price - open : open - price;
      if(moved >= InpBreakevenR * risk)
        {
         double newSl = NormalizePrice(isBuy ? open + 2 * _Point : open - 2 * _Point);
         if(g_trade.PositionModify(ticket, newSl, tp))
            PrintFormat("AIRiskEA: ticket %I64u moved to breakeven", ticket);
        }
     }
  }

//+------------------------------------------------------------------+
//| Prompt building                                                   |
//+------------------------------------------------------------------+
string SystemPrompt()
  {
   return StringFormat(
      "You are a disciplined intraday trader and risk manager for %s. "
      "From the market data, decide whether to open ONE new position now, and how much to risk. "
      "Reply with ONLY a JSON object, no other text: "
      "{\"action\":\"BUY\"|\"SELL\"|\"HOLD\",\"confidence\":0.0-1.0,\"risk_percent\":0.0-%.2f,"
      "\"sl\":price,\"tp\":price,\"reason\":\"max 30 words\"}. "
      "Rules: risk_percent is the %% of equity lost if SL is hit; lower it when volatility is high, "
      "trend is unclear, or price is near major levels; use HOLD with risk_percent 0 when there is no clear edge. "
      "BUY enters at ask, SELL at bid. SL must sit beyond a logical swing level and be %.1f-%.1f ATR from entry. "
      "TP must be at least %.1f x the SL distance. Prices use %d decimals. HOLD is a valid and common answer.",
      _Symbol, InpMaxRiskPct, InpMinSlAtr, InpMaxSlAtr, InpMinRR, _Digits);
  }

string BuildMarketContext()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, InpTimeframe, 1, InpBarsForAI, r); // closed bars only
   if(n <= 0)
     { Print("AIRiskEA: CopyRates failed ", GetLastError()); return ""; }

   double atr = BufferValue(g_hATR, 1), rsi = BufferValue(g_hRSI, 1);
   double e20 = BufferValue(g_hEMA20, 1), e50 = BufferValue(g_hEMA50, 1), e200 = BufferValue(g_hEMA200, 1);
   int dg = _Digits;

   string s = "";
   s += StringFormat("Symbol: %s | Timeframe: %s | Server time: %s\n", _Symbol,
                     EnumToString(InpTimeframe), TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
   s += StringFormat("Bid: %s Ask: %s Spread(points): %d\n", DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), dg),
                     DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), dg), (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   s += StringFormat("ATR14: %s RSI14: %.1f EMA20: %s EMA50: %s EMA200: %s\n", DoubleToString(atr, dg), rsi,
                     DoubleToString(e20, dg), DoubleToString(e50, dg), DoubleToString(e200, dg));

   MqlRates dr[];
   ArraySetAsSeries(dr, true);
   int nd = CopyRates(_Symbol, PERIOD_D1, 0, 6, dr);
   if(nd > 0)
     {
      s += StringFormat("Today so far: O %s H %s L %s\n", DoubleToString(dr[0].open, dg),
                        DoubleToString(dr[0].high, dg), DoubleToString(dr[0].low, dg));
      s += "Previous daily bars (date,open,high,low,close):\n";
      for(int i = nd - 1; i >= 1; i--)
         s += StringFormat("%s,%s,%s,%s,%s\n", TimeToString(dr[i].time, TIME_DATE), DoubleToString(dr[i].open, dg),
                           DoubleToString(dr[i].high, dg), DoubleToString(dr[i].low, dg), DoubleToString(dr[i].close, dg));
     }

   s += StringFormat("Last %d closed %s bars, oldest first (time,open,high,low,close,tick_volume):\n", n, EnumToString(InpTimeframe));
   for(int i = n - 1; i >= 0; i--)
      s += StringFormat("%s,%s,%s,%s,%s,%I64d\n", TimeToString(r[i].time, TIME_DATE | TIME_MINUTES),
                        DoubleToString(r[i].open, dg), DoubleToString(r[i].high, dg),
                        DoubleToString(r[i].low, dg), DoubleToString(r[i].close, dg), r[i].tick_volume);

   double dayEq = DayStartEquity(), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   s += StringFormat("Account: equity %.2f %s, today's P/L %.2f%%, trades today %d of %d max, open positions %d\n",
                     eq, AccountInfoString(ACCOUNT_CURRENCY), dayEq > 0 ? (eq - dayEq) / dayEq * 100.0 : 0.0,
                     CountTodayEntries(), InpMaxTradesDay, CountOpenPositions());
   return s;
  }

double BufferValue(int handle, int shift)
  {
   double b[];
   if(CopyBuffer(handle, 0, shift, 1, b) != 1)
      return 0.0;
   return b[0];
  }

//+------------------------------------------------------------------+
//| HTTP call (OpenAI-compatible chat completions)                    |
//+------------------------------------------------------------------+
string ProviderName() { return InpProvider == PROVIDER_OPENROUTER ? "OpenRouter" : "DeepSeek"; }

bool CallAI(const string system, const string user, string &content)
  {
   string url, model;
   if(InpProvider == PROVIDER_OPENROUTER)
     { url = "https://openrouter.ai/api/v1/chat/completions"; model = InpModelOpenRouter; }
   else
     { url = "https://api.deepseek.com/chat/completions"; model = InpModelDeepSeek; }

   string body = "{";
   body += "\"model\":\"" + JsonEscape(model) + "\",";
   body += "\"temperature\":" + DoubleToString(InpTemperature, 2) + ",";
   body += "\"max_tokens\":" + IntegerToString(InpMaxTokens) + ",";
   if(InpJsonMode)
      body += "\"response_format\":{\"type\":\"json_object\"},";
   body += "\"messages\":[";
   body += "{\"role\":\"system\",\"content\":\"" + JsonEscape(system) + "\"},";
   body += "{\"role\":\"user\",\"content\":\"" + JsonEscape(user) + "\"}";
   body += "]}";

   string headers = "Content-Type: application/json\r\n";
   headers += "Authorization: Bearer " + g_apiKey + "\r\n";
   if(InpProvider == PROVIDER_OPENROUTER)
      headers += "X-Title: AIRiskEA\r\n";

   char data[], result[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1); // drop the trailing \0
   string resHeaders;

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpTimeoutMs, data, result, resHeaders);
   if(code == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         PrintFormat("AIRiskEA: WebRequest blocked. Add %s to Tools > Options > Expert Advisors > 'Allow WebRequest for listed URL'.",
                     InpProvider == PROVIDER_OPENROUTER ? "https://openrouter.ai" : "https://api.deepseek.com");
      else
         PrintFormat("AIRiskEA: WebRequest failed, error %d", err);
      return false;
     }

   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code != 200)
     {
      PrintFormat("AIRiskEA: HTTP %d from %s: %s", code, ProviderName(), StringSubstr(resp, 0, 500));
      return false;
     }

   // choices[0].message.content
   int p = JsonValueStart(resp, "content", StringFind(resp, "\"choices\""));
   if(p < 0 || !JsonReadString(resp, p, content))
     {
      Print("AIRiskEA: no content in response: ", StringSubstr(resp, 0, 500));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Parse the AI's JSON object                                        |
//+------------------------------------------------------------------+
bool ParseDecision(string content, AIDecision &d)
  {
   d.action = ""; d.confidence = 0; d.risk_pct = 0; d.sl = 0; d.tp = 0; d.reason = "";

   int think = StringFind(content, "</think>");          // some models emit reasoning first
   if(think >= 0)
      content = StringSubstr(content, think + 8);
   int a = StringFind(content, "{");
   int b = LastIndexOf(content, "}");
   if(a < 0 || b <= a)
      return false;
   string obj = StringSubstr(content, a, b - a + 1);

   d.action = JsonGetString(obj, "action");
   StringToUpper(d.action);
   StringTrimLeft(d.action);
   StringTrimRight(d.action);
   if(d.action != "BUY" && d.action != "SELL" && d.action != "HOLD")
      return false;
   d.confidence = JsonGetNumber(obj, "confidence");
   d.risk_pct   = JsonGetNumber(obj, "risk_percent");
   d.sl         = JsonGetNumber(obj, "sl");
   d.tp         = JsonGetNumber(obj, "tp");
   d.reason     = JsonGetString(obj, "reason");
   if(d.confidence > 1.0 && d.confidence <= 100.0) // tolerate "75" meaning 75%
      d.confidence /= 100.0;
   return true;
  }

//+------------------------------------------------------------------+
//| Minimal JSON helpers                                              |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
  {
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '"')       out += "\\\"";
      else if(c == '\\') out += "\\\\";
      else if(c == '\n') out += "\\n";
      else if(c == '\r') out += "\\r";
      else if(c == '\t') out += "\\t";
      else if(c < 0x20)  out += StringFormat("\\u%04x", c);
      else               out += ShortToString(c);
     }
   return out;
  }

bool IsWs(ushort c) { return c == ' ' || c == '\n' || c == '\r' || c == '\t'; }

// Returns the index of the first character of the value for "key", or -1.
int JsonValueStart(const string s, const string key, int from = 0)
  {
   if(from < 0) from = 0;
   string pat = "\"" + key + "\"";
   int n = StringLen(s);
   int idx = StringFind(s, pat, from);
   while(idx >= 0)
     {
      bool escaped = (idx > 0 && StringGetCharacter(s, idx - 1) == '\\');
      int p = idx + StringLen(pat);
      while(p < n && IsWs(StringGetCharacter(s, p))) p++;
      if(!escaped && p < n && StringGetCharacter(s, p) == ':')
        {
         p++;
         while(p < n && IsWs(StringGetCharacter(s, p))) p++;
         return p < n ? p : -1;
        }
      idx = StringFind(s, pat, idx + 1);
     }
   return -1;
  }

int HexVal(ushort c)
  {
   if(c >= '0' && c <= '9') return c - '0';
   if(c >= 'a' && c <= 'f') return c - 'a' + 10;
   if(c >= 'A' && c <= 'F') return c - 'A' + 10;
   return -1;
  }

// s[p] must be the opening quote. Decodes escapes into out.
bool JsonReadString(const string s, int p, string &out)
  {
   out = "";
   int n = StringLen(s);
   if(p >= n || StringGetCharacter(s, p) != '"')
      return false;
   for(int i = p + 1; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '"')
         return true;
      if(c != '\\')
        { out += ShortToString(c); continue; }
      if(++i >= n) return false;
      ushort e = StringGetCharacter(s, i);
      if(e == 'n')      out += "\n";
      else if(e == 't') out += "\t";
      else if(e == 'r') out += "\r";
      else if(e == 'b' || e == 'f') { }
      else if(e == 'u' && i + 4 < n)
        {
         int v = 0;
         for(int k = 1; k <= 4; k++)
           {
            int h = HexVal(StringGetCharacter(s, i + k));
            if(h < 0) return false;
            v = v * 16 + h;
           }
         out += ShortToString((ushort)v);
         i += 4;
        }
      else out += ShortToString(e); // \" \\ \/
     }
   return false;
  }

string JsonGetString(const string obj, const string key)
  {
   int p = JsonValueStart(obj, key);
   if(p < 0) return "";
   string v = "";
   if(StringGetCharacter(obj, p) == '"')
     {
      JsonReadString(obj, p, v);
      return v;
     }
   return "";
  }

double JsonGetNumber(const string obj, const string key)
  {
   int p = JsonValueStart(obj, key);
   if(p < 0) return 0.0;
   if(StringGetCharacter(obj, p) == '"') // number sent as a string
     {
      string v;
      JsonReadString(obj, p, v);
      return StringToDouble(v);
     }
   int n = StringLen(obj), q = p;
   while(q < n)
     {
      ushort c = StringGetCharacter(obj, q);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') q++;
      else break;
     }
   return q > p ? StringToDouble(StringSubstr(obj, p, q - p)) : 0.0;
  }

int LastIndexOf(const string s, const string sub)
  {
   int last = -1, i = StringFind(s, sub);
   while(i >= 0) { last = i; i = StringFind(s, sub, i + 1); }
   return last;
  }

//+------------------------------------------------------------------+
//| Account / history helpers                                         |
//+------------------------------------------------------------------+
datetime DayStart() { long t = (long)TimeCurrent(); return (datetime)(t - t % 86400); }

void RollDay()
  {
   datetime d = DayStart();
   if(d != g_day)
     {
      g_day = d;
      g_callsToday = 0;
     }
  }

// Equity at the first check of the server day, persisted in a terminal global variable.
double DayStartEquity()
  {
   string kDay = "AIRiskEA_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_day";
   string kEq  = "AIRiskEA_" + IntegerToString((long)InpMagic) + "_" + _Symbol + "_eq";
   double day = (double)DayStart();
   if(!GlobalVariableCheck(kDay) || GlobalVariableGet(kDay) != day)
     {
      GlobalVariableSet(kDay, day);
      GlobalVariableSet(kEq, AccountInfoDouble(ACCOUNT_EQUITY));
     }
   return GlobalVariableGet(kEq);
  }

int CountOpenPositions()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         c++;
     }
   return c;
  }

int CountTodayEntries()
  {
   if(!HistorySelect(DayStart(), TimeCurrent() + 60))
      return 0;
   int c = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol &&
         (ulong)HistoryDealGetInteger(t, DEAL_MAGIC) == InpMagic &&
         HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//| CSV decision log (MQL5\Files)                                     |
//+------------------------------------------------------------------+
void LogDecision(AIDecision &d, double lots, string status)
  {
   int h = FileOpen(InpLogFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   if(FileSize(h) == 0)
      FileWrite(h, "time", "symbol", "provider", "action", "confidence", "risk_pct", "sl", "tp", "lots", "status", "reason");
   FileSeek(h, 0, SEEK_END);
   string reason = d.reason;
   StringReplace(reason, ",", ";");
   StringReplace(reason, "\n", " ");
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), _Symbol, ProviderName(), d.action,
             DoubleToString(d.confidence, 2), DoubleToString(d.risk_pct, 2),
             DoubleToString(d.sl, _Digits), DoubleToString(d.tp, _Digits),
             DoubleToString(lots, 2), status, reason);
   FileClose(h);
  }

string ReadKeyFile(const string name)
  {
   int h = FileOpen(name, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
      return "";
   string key = FileReadString(h);
   FileClose(h);
   StringTrimLeft(key);
   StringTrimRight(key);
   return key;
  }
//+------------------------------------------------------------------+
