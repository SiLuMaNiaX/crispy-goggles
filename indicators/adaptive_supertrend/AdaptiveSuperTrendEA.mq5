//+------------------------------------------------------------------+
//|                                        AdaptiveSuperTrendEA.mq5  |
//|  Trend-following EA on the Adaptive SuperTrend confirmed flips.  |
//|                                                                  |
//|  Mirrors research/adst.py + research/ea_modes.py ("confirm"      |
//|  mode), which was tested on 2024-06..2026-11 gold data:          |
//|   - enter at the open after a confirmed flip                     |
//|   - hold until the next confirmed flip (stop-and-reverse)        |
//|   - hard stop = SuperTrend line -/+ 2 x ATR at entry (server)    |
//|   - hold over weekends (closing on Friday tested worse)          |
//|   - flip grades are NOT used: they had no predictive value       |
//+------------------------------------------------------------------+
#property copyright   "Adaptive SuperTrend rebuild"
#property version     "1.00"
#property description "Stop-and-reverse on confirmed Adaptive SuperTrend flips with a hard ATR stop."
#property description "Tested PF ~1.25 (neighbourhood median) on gold M30. Demo-test before live use."

#include <Trade/Trade.mqh>

input group "Signal"
input ENUM_TIMEFRAMES InpTF       = PERIOD_M30; // Signal timeframe
input int    InpAtrLen    = 14;    // ATR Length
input double InpBaseF     = 3.5;   // Base Factor
input int    InpErLen     = 10;    // ER Length
input int    InpBaseConf  = 2;     // Confirm Bars
input bool   InpAdaptive  = true;  // Adaptive factor/confirmation (false = plain SuperTrend)
input int    InpVolAvg    = 50;    // Volatility average length
input double InpFMin      = 0.75;  // Min factor scale
input double InpFMax      = 1.4;   // Max factor scale
input double InpErChop    = 0.30;  // ER below = +1 confirm bar
input double InpErTrend   = 0.60;  // ER above = -1 confirm bar
input int    InpCalcBars  = 1500;  // Closed bars used per calculation

input group "Trade management"
input double InpStopAtr   = 2.0;   // Hard stop beyond the line (x ATR)
input bool   InpAllowLong = true;  // Allow buys
input bool   InpAllowShort= true;  // Allow sells
input bool   InpFridayClose = false; // Close on Friday (tested worse; off by default)
input int    InpFridayHour  = 22;    // Friday close hour (server)

input group "Risk"
input double InpRiskPct   = 0.5;   // Risk per trade (% equity, to the hard stop)
input double InpFixedLots = 0.0;   // Fixed lots (0 = use risk %)
input double InpMaxSpread = 0.60;  // Max spread to enter (price units)

input group "Misc"
input ulong  InpMagic     = 20261122; // Magic number
input int    InpSlippage  = 30;       // Max deviation (points)

CTrade   g_trade;
datetime g_lastBar = 0;
int      g_pendDir = 0;       // entry waiting for acceptable spread (current bar only)
double   g_pendSL  = 0;
datetime g_pendBar = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpAtrLen < 1 || InpErLen < 2 || InpBaseConf < 1 || InpVolAvg < 2 || InpStopAtr < 0 ||
      InpCalcBars < InpAtrLen + InpVolAvg + 100)
      return(INIT_PARAMETERS_INCORRECT);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| SuperTrend on closed bars. Returns false if history isn't ready. |
//| flip: +1/-1 on the last closed bar, 0 otherwise.                 |
//+------------------------------------------------------------------+
bool ComputeST(int &flip, double &line, double &atrOut)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, InpTF, 1, InpCalcBars, r);   // r[n-1] = last closed bar
   if(n < InpAtrLen + InpVolAvg + 50)
      return false;

   double atr[];
   ArrayResize(atr, n);
   double trSum = 0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low
                  : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < InpAtrLen - 1)       { trSum += tr; atr[i] = EMPTY_VALUE; }
      else if(i == InpAtrLen - 1) { trSum += tr; atr[i] = trSum / InpAtrLen; }
      else                          atr[i] = (atr[i - 1] * (InpAtrLen - 1) + tr) / InpAtrLen;
     }

   double upB = EMPTY_VALUE, dnB = EMPTY_VALUE;
   int raw = 1, conf = 1, held = 0;
   flip = 0;
   for(int i = 0; i < n; i++)
     {
      if(atr[i] == EMPTY_VALUE)
         continue;
      // volatility ratio (needs a full SMA window of valid ATR values)
      double vr = 1.0;
      if(i >= InpAtrLen - 1 + InpVolAvg - 1)
        {
         double s = 0; for(int k = 0; k < InpVolAvg; k++) s += atr[i - k];
         if(s > 0) vr = atr[i] / (s / InpVolAvg);
        }
      double factor = InpAdaptive ? InpBaseF * MathMax(InpFMin, MathMin(InpFMax, vr)) : InpBaseF;
      // efficiency ratio
      double er = 0;
      if(i >= InpErLen)
        {
         double path = 0; for(int k = 0; k < InpErLen; k++) path += MathAbs(r[i - k].close - r[i - k - 1].close);
         if(path > 0) er = MathAbs(r[i].close - r[i - InpErLen].close) / path;
        }
      int confN = !InpAdaptive ? InpBaseConf
                  : (er < InpErChop ? InpBaseConf + 1 : (er > InpErTrend ? MathMax(1, InpBaseConf - 1) : InpBaseConf));
      // bands
      double src = (r[i].high + r[i].low) / 2.0;
      double upN = src - factor * atr[i], dnN = src + factor * atr[i];
      upB = (upB == EMPTY_VALUE) ? upN : (r[i - 1].close > upB ? MathMax(upN, upB) : upN);
      dnB = (dnB == EMPTY_VALUE) ? dnN : (r[i - 1].close < dnB ? MathMin(dnN, dnB) : dnN);
      int prev = raw;
      if(raw == 1 && r[i].close < upB)       raw = -1;
      else if(raw == -1 && r[i].close > dnB) raw = 1;
      held = (raw != prev) ? 1 : held + 1;
      bool f = (raw != conf && held >= confN);
      if(f) conf = raw;
      if(i == n - 1)
        {
         flip = f ? conf : 0;
         line = (raw == 1) ? upB : dnB;
         atrOut = atr[i];
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
int PositionDir(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
        {
         ticket = tk;
         return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
        }
     }
   return 0;
  }

double LotsForRisk(const double dist)
  {
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), lots;
   if(InpFixedLots > 0) lots = InpFixedLots;
   else
     {
      double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tv <= 0 || ts <= 0 || dist <= 0) return 0;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0 / (dist / ts * tv);
     }
   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0;      // never round up past the risk budget
   return MathMin(lots, maxL);
  }

//--- try to open the pending entry; returns true when done (opened or abandoned)
bool TryEnter()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask - bid > InpMaxSpread)
      return false;                                      // retry on later ticks of this bar
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
   double entry = (g_pendDir == 1) ? ask : bid;
   double sl = NormalizeDouble(g_pendSL, dg);
   double dist = (g_pendDir == 1) ? entry - sl : sl - entry;
   if(dist < minDist)
     {
      Print("AST EA: hard stop on the wrong side of price or too close; entry skipped");
      return true;                                       // same rule as the research (skip)
     }
   double lots = LotsForRisk(dist);
   if(lots <= 0)
     {
      Print("AST EA: min lot exceeds the risk budget; entry skipped");
      return true;
     }
   bool ok = (g_pendDir == 1) ? g_trade.Buy(lots, _Symbol, 0, sl, 0, "AST long")
                              : g_trade.Sell(lots, _Symbol, 0, sl, 0, "AST short");
   if(!ok)
     {
      PrintFormat("AST EA: order failed %d %s — will retry", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return false;
     }
   return true;
  }

bool IsFridayClose()
  {
   if(!InpFridayClose) return false;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_week == 5 && dt.hour >= InpFridayHour;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ulong ticket = 0;
   int dir = PositionDir(ticket);
   if(dir != 0 && IsFridayClose())
     { g_trade.PositionClose(ticket); return; }

   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt == 0) return;

   //--- pending entry from this bar's signal (waiting for spread)
   if(g_pendDir != 0)
     {
      if(g_pendBar != bt) { Print("AST EA: spread stayed too wide for the whole bar; entry abandoned"); g_pendDir = 0; }
      else if(dir == 0 && !IsFridayClose() && TryEnter()) g_pendDir = 0;
     }

   if(bt == g_lastBar) return;
   int flip; double line = 0, atr = 0;
   if(!ComputeST(flip, line, atr))
      return;                                            // history still loading; retry next tick
   if(flip == 0) { g_lastBar = bt; return; }

   //--- reverse: close the opposite position first
   if(dir != 0 && dir != flip)
     {
      if(!g_trade.PositionClose(ticket))
        {
         PrintFormat("AST EA: close failed %d — retrying next tick", g_trade.ResultRetcode());
         return;                                         // bar not marked done
        }
      dir = 0;
     }
   g_lastBar = bt;
   if(dir != 0) return;                                  // already positioned in the flip direction
   if((flip == 1 && !InpAllowLong) || (flip == -1 && !InpAllowShort) || IsFridayClose()) return;

   g_pendDir = flip;
   g_pendSL  = (flip == 1) ? line - InpStopAtr * atr : line + InpStopAtr * atr;
   g_pendBar = bt;
   if(TryEnter()) g_pendDir = 0;
  }
//+------------------------------------------------------------------+
