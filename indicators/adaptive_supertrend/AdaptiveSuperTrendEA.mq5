//+------------------------------------------------------------------+
//|                                        AdaptiveSuperTrendEA.mq5  |
//|  Trend-following EA on the Adaptive SuperTrend confirmed flips.  |
//|                                                                  |
//|  SWING mode (default, recommended) mirrors                       |
//|  adaptive_supertrend/research/ea_modes.py "confirm" mode:        |
//|   - enter at the open after a confirmed flip                     |
//|   - hold until the next confirmed flip (stop-and-reverse)        |
//|   - hard stop = SuperTrend line -/+ 2 x ATR at entry (server)    |
//|   - hold overnight and over weekends                             |
//|  INTRADAY mode (optional) mirrors                                |
//|  gold_intraday/research/intraday.py st_intraday():               |
//|   - new entries only from London 08:00 to New York 15:00         |
//|   - flat at New York 16:00, never holds overnight                |
//|   - optional 4H SuperTrend trend filter                          |
//|   Tested near breakeven on gold (PF ~1.06) - see README.         |
//+------------------------------------------------------------------+
#property copyright   "Adaptive SuperTrend rebuild"
#property version     "1.10"
#property description "Stop-and-reverse on confirmed Adaptive SuperTrend flips with a hard ATR stop."
#property description "Swing mode on XAUUSD M30 was the best tested setup (PF ~1.3). Intraday mode tested ~breakeven."

#include <Trade/Trade.mqh>

enum ENUM_TREND_FILTER { TF_NONE = 0,   // None
                         TF_ST_H4 = 1   // 4H SuperTrend direction
                       };

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
input ENUM_TREND_FILTER InpTrendFilter = TF_NONE; // Higher-timeframe trend filter for entries

input group "Intraday mode (optional)"
input bool   InpIntraday     = false; // Intraday: London 08:00 -> NY 15:00 entries, flat at NY 16:00
input int    InpServerGMT    = 2;     // Broker server GMT offset in winter (hours)
input bool   InpServerUSDST  = true;  // Server adds +1h during US daylight saving (typical GMT+2/+3 brokers)

input group "Trade management"
input double InpStopAtr   = 2.0;   // Hard stop beyond the line (x ATR)
input bool   InpAllowLong = true;  // Allow buys
input bool   InpAllowShort= true;  // Allow sells
input bool   InpFridayClose = false; // Close on Friday (tested worse in swing mode)
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
      InpCalcBars < InpAtrLen + InpVolAvg + 100 || InpServerGMT < -12 || InpServerGMT > 14)
      return(INIT_PARAMETERS_INCORRECT);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Time zones (DST-correct London / New York from server time)      |
//+------------------------------------------------------------------+
datetime NthSunday(const int year, const int month, const int n)   // n = 1..4, or -1 for last
  {
   MqlDateTime d; ZeroMemory(d); d.year = year; d.mon = month; d.day = 1;
   datetime first = StructToTime(d);
   TimeToStruct(first, d);
   int add = (7 - d.day_of_week) % 7;                // days to first Sunday
   datetime s = first + add * 86400;
   if(n > 0) return s + (n - 1) * 7 * 86400;
   datetime last = s;
   MqlDateTime t;
   while(true) { datetime nx = last + 7 * 86400; TimeToStruct(nx, t); if(t.mon != month) break; last = nx; }
   return last;
  }

bool UsDst(const datetime utc)        // 2nd Sun Mar 07:00 UTC -> 1st Sun Nov 06:00 UTC
  {
   MqlDateTime d; TimeToStruct(utc, d);
   datetime a = NthSunday(d.year, 3, 2) + 7 * 3600, b = NthSunday(d.year, 11, 1) + 6 * 3600;
   return utc >= a && utc < b;
  }

bool EuDst(const datetime utc)        // last Sun Mar 01:00 UTC -> last Sun Oct 01:00 UTC
  {
   MqlDateTime d; TimeToStruct(utc, d);
   datetime a = NthSunday(d.year, 3, -1) + 3600, b = NthSunday(d.year, 10, -1) + 3600;
   return utc >= a && utc < b;
  }

datetime ServerToUtc(const datetime srv)
  {
   datetime utc = srv - InpServerGMT * 3600;
   if(InpServerUSDST && UsDst(utc - 3600)) utc -= 3600;   // server is one hour further ahead in US summer
   return utc;
  }

int MinuteOfDay(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.hour * 60 + d.min; }
int LondonMinute(const datetime srv) { datetime u = ServerToUtc(srv); return MinuteOfDay(u + (EuDst(u) ? 3600 : 0)); }
int NyMinute(const datetime srv)     { datetime u = ServerToUtc(srv); return MinuteOfDay(u - (UsDst(u) ? 4 : 5) * 3600); }

// research: entries when the flip bar opens at London >= 08:00 and New York < 15:00; flat from New York 16:00
bool InEntryWindow(const datetime barOpenSrv) { return LondonMinute(barOpenSrv) >= 480 && NyMinute(barOpenSrv) < 900; }
bool IsFlatTime(const datetime srv)          { int m = NyMinute(srv); return m >= 960 || m < 180; }  // 16:00-03:00 NY

//+------------------------------------------------------------------+
//| SuperTrend on closed bars of `tf`, ending `startShift` bars back. |
//| Returns false if history isn't ready.                            |
//+------------------------------------------------------------------+
bool RunST(const ENUM_TIMEFRAMES tf, const int startShift, const double baseF, const int baseConf, const bool adaptive,
           int &flip, int &confDir, double &line, double &atrOut, datetime &barTime)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, tf, startShift, InpCalcBars, r);   // r[n-1] = last bar used
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
      double vr = 1.0;
      if(i >= InpAtrLen - 1 + InpVolAvg - 1)
        {
         double s = 0; for(int k = 0; k < InpVolAvg; k++) s += atr[i - k];
         if(s > 0) vr = atr[i] / (s / InpVolAvg);
        }
      double factor = adaptive ? baseF * MathMax(InpFMin, MathMin(InpFMax, vr)) : baseF;
      double er = 0;
      if(i >= InpErLen)
        {
         double path = 0; for(int k = 0; k < InpErLen; k++) path += MathAbs(r[i - k].close - r[i - k - 1].close);
         if(path > 0) er = MathAbs(r[i].close - r[i - InpErLen].close) / path;
        }
      int confN = !adaptive ? baseConf
                  : (er < InpErChop ? baseConf + 1 : (er > InpErTrend ? MathMax(1, baseConf - 1) : baseConf));
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
         confDir = conf;
         line = (raw == 1) ? upB : dnB;
         atrOut = atr[i];
         barTime = r[i].time;
        }
     }
   return true;
  }

//--- 4H SuperTrend(14, 3.5, confirm 2, plain) direction from H4 bars completed before `t`
bool TrendDir(const datetime t, int &dir)
  {
   dir = 0;
   if(InpTrendFilter == TF_NONE) { dir = 0; return true; }
   int sh = iBarShift(_Symbol, PERIOD_H4, t, false);
   if(sh < 0) return false;
   int f, cd; double ln, at; datetime bt;
   if(!RunST(PERIOD_H4, sh + 1, 3.5, 2, false, f, cd, ln, at, bt)) return false;
   dir = cd;
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
   datetime now = TimeCurrent();

   //--- forced flat: Friday option (swing) or New York 16:00 (intraday)
   if(dir != 0 && (IsFridayClose() || (InpIntraday && IsFlatTime(now))))
     {
      if(g_trade.PositionClose(ticket)) dir = 0;
      g_pendDir = 0;
      return;
     }

   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt == 0) return;

   //--- pending entry from this bar's signal (waiting for spread)
   if(g_pendDir != 0)
     {
      if(g_pendBar != bt) { Print("AST EA: spread stayed too wide for the whole bar; entry abandoned"); g_pendDir = 0; }
      else if(dir == 0 && TryEnter()) g_pendDir = 0;
     }

   if(bt == g_lastBar) return;
   int flip, cd; double line = 0, atr = 0; datetime sigTime;
   if(!RunST(InpTF, 1, InpBaseF, InpBaseConf, InpAdaptive, flip, cd, line, atr, sigTime))
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

   //--- entry gates
   int trend = 0;
   if(!TrendDir(sigTime, trend))
      return;                                            // H4 history loading; retry
   g_lastBar = bt;
   if(dir != 0) return;
   if((flip == 1 && !InpAllowLong) || (flip == -1 && !InpAllowShort) || IsFridayClose()) return;
   if(InpTrendFilter != TF_NONE && trend != flip) return;
   if(InpIntraday && (!InEntryWindow(sigTime) || IsFlatTime(now))) return;

   g_pendDir = flip;
   g_pendSL  = (flip == 1) ? line - InpStopAtr * atr : line + InpStopAtr * atr;
   g_pendBar = bt;
   if(TryEnter()) g_pendDir = 0;
  }
//+------------------------------------------------------------------+
