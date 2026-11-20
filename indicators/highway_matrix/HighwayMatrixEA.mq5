//+------------------------------------------------------------------+
//|                                             HighwayMatrixEA.mq5  |
//|  Trades the Highway Matrix zone-reversal signals.                |
//|                                                                  |
//|  The logic mirrors research/hwm.py, which was validated on       |
//|  2024-06..2026-11 gold data (see README "EA" section).           |
//|  Validated default: M30, signals filtered by the D1 EMA(50)      |
//|  slope, TP = kernel centre line, SL beyond the outer band.       |
//|  The original "highway" H-signal filter is available but was     |
//|  NOT profitable in testing.                                      |
//+------------------------------------------------------------------+
#property copyright   "Highway Matrix rebuild"
#property version     "1.00"
#property description "Highway Matrix EA — trend-filtered zone-reversal entries."
#property description "Validated only as a small edge (PF ~1.2, t-stat 1.6). Demo-test first."

#include <Trade/Trade.mqh>

enum ENUM_TREND_SRC
  {
   TREND_HTF_EMA_SLOPE = 0, // HTF EMA slope (validated)
   TREND_HIGHWAY       = 1  // Original highway H-signal (not profitable)
  };

input group "Timeframes"
input ENUM_TIMEFRAMES InpTF          = PERIOD_M30;      // Signal timeframe
input ENUM_TREND_SRC  InpTrendSrc    = TREND_HTF_EMA_SLOPE; // Trend filter
input ENUM_TIMEFRAMES InpTrendTF     = PERIOD_D1;       // Trend timeframe (EMA slope)
input int             InpTrendEMA    = 50;              // Trend EMA length
input ENUM_TIMEFRAMES InpHwTF        = PERIOD_H3;       // Highway timeframe (highway mode)
input int             InpHwLen       = 20;              // Highway EMA length
input int             InpHwAtrLen    = 14;              // Highway ATR length
input double          InpHwMult      = 0.5;             // Highway width x ATR

input group "Kernel envelope"
input double          InpBandwidth   = 20.0;            // Bandwidth
input int             InpWindow      = 500;             // MAE window (bars)
input double          InpInnerMult   = 1.5;             // Inner band x MAE
input double          InpOuterMult   = 3.0;             // Outer band x MAE
input int             InpEmaFast     = 5;               // Momentum EMA length
input bool            InpUseMom      = true;            // Require momentum confirm
input int             InpCooldown    = 10;              // Cooldown bars between signals
input int             InpCalcBars    = 2500;            // Bars used for calculation

input group "Trade management"
input double          InpSlBufMAE    = 0.25;            // SL buffer beyond outer band (x MAE)
input int             InpMaxHoldBars = 48;              // Max bars in trade
input bool            InpAllowLong   = true;            // Allow buys
input bool            InpAllowShort  = true;            // Allow sells

input group "Risk"
input double          InpRiskPct     = 0.5;             // Risk per trade (% of equity)
input double          InpFixedLots   = 0.0;             // Fixed lots (0 = use risk %)
input double          InpMaxDailyLossPct = 2.0;         // Stop new trades after daily loss % (0 = off)
input double          InpMaxSpread   = 0.60;            // Max spread to enter (price units, e.g. 0.60 = 60 cents on gold)
input int             InpFridayCloseHour = 22;          // Close positions Friday at hour (server, -1 = off)
input int             InpFridayCloseMin  = 30;          // ...and minute

input group "Misc"
input ulong           InpMagic       = 20261120;        // Magic number
input int             InpSlippagePts = 30;              // Max deviation (points)

CTrade   g_trade;
double   g_w[];
int      g_kLen;
datetime g_lastBar = 0;
datetime g_dayStart = 0;
double   g_dayStartEquity = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpBandwidth <= 0 || InpWindow < 50 || InpCalcBars < InpWindow + 200 ||
      InpInnerMult <= 0 || InpOuterMult <= InpInnerMult || InpTrendEMA < 2 || InpMaxHoldBars < 1)
     {
      Print("HighwayMatrixEA: invalid inputs");
      return(INIT_PARAMETERS_INCORRECT);
     }
   g_kLen = (int)MathMin(MathCeil(InpBandwidth * 3.0), 499.0);
   ArrayResize(g_w, g_kLen);
   for(int k = 0; k < g_kLen; k++)
      g_w[k] = MathExp(-(double)(k * k) / (2.0 * InpBandwidth * InpBandwidth));

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(_Period != InpTF)
      PrintFormat("HighwayMatrixEA: note — chart is %s, signals use %s.",
                  EnumToString((ENUM_TIMEFRAMES)_Period), EnumToString(InpTF));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| EMA over a chronologically ordered array                         |
//+------------------------------------------------------------------+
void EmaArr(const double &x[], const int n, const int len, double &out[])
  {
   ArrayResize(out, n);
   double a = 2.0 / (len + 1.0);
   for(int i = 0; i < n; i++)
      out[i] = (i == 0) ? x[i] : a * x[i] + (1.0 - a) * out[i - 1];
  }

//+------------------------------------------------------------------+
//| Trend on the HTF, using only bars completed before `t`'s HTF bar |
//| returns +1 / -1 / 0 ; `ok` false if data not ready               |
//+------------------------------------------------------------------+
int HtfEmaSlope(const datetime t, bool &ok)
  {
   ok = false;
   int sh = iBarShift(_Symbol, InpTrendTF, t, false);
   if(sh < 0)
      return 0;
   int need = InpTrendEMA * 6 + 10;
   double cl[];
   ArraySetAsSeries(cl, false);
   int got = CopyClose(_Symbol, InpTrendTF, sh + 1, need, cl);   // completed HTF bars only
   if(got < InpTrendEMA + 2)
      return 0;
   double e[];
   EmaArr(cl, got, InpTrendEMA, e);
   ok = true;
   double d = e[got - 1] - e[got - 2];
   return (d > 0) ? 1 : (d < 0 ? -1 : 0);
  }

//--- original highway band for bar time t (previous completed HTF bar)
bool HighwayAt(const datetime t, double &hu, double &hl)
  {
   int sh = iBarShift(_Symbol, InpHwTF, t, false);
   if(sh < 0)
      return false;
   int need = MathMax(InpHwLen, InpHwAtrLen) * 10 + 50;
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(_Symbol, InpHwTF, sh + 1, need, r);
   if(got < MathMax(InpHwLen, InpHwAtrLen) + 2)
      return false;
   double a = 2.0 / (InpHwLen + 1.0), ema = 0, atr = 0, trSum = 0;
   for(int j = 0; j < got; j++)
     {
      ema = (j == 0) ? r[j].close : a * r[j].close + (1.0 - a) * ema;
      double tr = r[j].high - r[j].low;
      if(j > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[j].high - r[j - 1].close), MathAbs(r[j].low - r[j - 1].close)));
      if(j < InpHwAtrLen) { trSum += tr; atr = trSum / (j + 1); }
      else                  atr = (atr * (InpHwAtrLen - 1) + tr) / InpHwAtrLen;
     }
   hu = ema + atr * InpHwMult;
   hl = ema - atr * InpHwMult;
   return true;
  }

//+------------------------------------------------------------------+
//| Compute the signal on the last closed bar of InpTF.              |
//| Returns +1 buy, -1 sell, 0 none, -2 data not ready (retry).      |
//+------------------------------------------------------------------+
int ComputeSignal(double &midOut, double &maeOut, double &upOOut, double &loOOut, datetime &barTime)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, InpTF, 1, InpCalcBars, r);   // closed bars only; r[n-1] = last closed
   if(n < InpWindow + 100)
      return -2;                                           // history not ready

   double src[], mid[], mae[], ema[];
   ArrayResize(src, n); ArrayResize(mid, n); ArrayResize(mae, n);
   for(int i = 0; i < n; i++)
      src[i] = r[i].close;

   // endpoint Gaussian kernel (identical to indicator / research)
   for(int i = 0; i < n; i++)
     {
      double num = 0, den = 0;
      int kMax = MathMin(g_kLen, i + 1);
      for(int k = 0; k < kMax; k++) { num += src[i - k] * g_w[k]; den += g_w[k]; }
      mid[i] = num / den;
     }
   // rolling MAE (running sum)
   double s = 0;
   for(int i = 0; i < n; i++)
     {
      s += MathAbs(src[i] - mid[i]);
      if(i >= InpWindow) s -= MathAbs(src[i - InpWindow] - mid[i - InpWindow]);
      mae[i] = s / MathMin(i + 1, InpWindow);
     }
   EmaArr(src, n, InpEmaFast, ema);

   // raw signals + cooldown (any side), same order of precedence as research
   int lastSig = -1000000, sigLast = 0;
   for(int i = 1; i < n; i++)
     {
      if(i - lastSig <= InpCooldown) continue;
      double upIp = mid[i - 1] + mae[i - 1] * InpInnerMult, loIp = mid[i - 1] - mae[i - 1] * InpInnerMult;
      double upI  = mid[i] + mae[i] * InpInnerMult,         loI  = mid[i] - mae[i] * InpInnerMult;
      bool rs = r[i - 1].high >= upIp && r[i].close < upI && r[i].close < r[i].open && (!InpUseMom || ema[i] < ema[i - 1]);
      bool rb = r[i - 1].low  <= loIp && r[i].close > loI && r[i].close > r[i].open && (!InpUseMom || ema[i] > ema[i - 1]);
      int sg = rs ? -1 : (rb ? 1 : 0);
      if(sg != 0)
        {
         lastSig = i;
         if(i == n - 1) sigLast = sg;
        }
     }

   const int L = n - 1;
   midOut = mid[L]; maeOut = mae[L];
   upOOut = mid[L] + mae[L] * InpOuterMult;
   loOOut = mid[L] - mae[L] * InpOuterMult;
   barTime = r[L].time;
   if(sigLast == 0)
      return 0;

   // trend filter
   int trend = 0;
   if(InpTrendSrc == TREND_HTF_EMA_SLOPE)
     {
      bool ok;
      trend = HtfEmaSlope(r[L].time, ok);
      if(!ok) return -2;
     }
   else
     {
      double hu, hl;
      if(!HighwayAt(r[L].time, hu, hl)) return -2;
      double slope = mid[L] - mid[L - 1];
      trend = (r[L].close > hu && slope > 0) ? 1 : ((r[L].close < hl && slope < 0) ? -1 : 0);
     }
   return (sigLast == trend) ? sigLast : 0;
  }

//+------------------------------------------------------------------+
bool HasPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { ticket = tk; return true; }
     }
   return false;
  }

double LotsForRisk(const double riskPrice)
  {
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots;
   if(InpFixedLots > 0)
      lots = InpFixedLots;
   else
     {
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0 || tickSize <= 0 || riskPrice <= 0) return 0;
      double lossPerLot = riskPrice / tickSize * tickVal;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0 / lossPerLot;
     }
   lots = MathFloor(lots / step) * step;
   if(lots < minL) return 0;      // risk too small for min lot — skip rather than over-risk
   return MathMin(lots, maxL);
  }

bool DailyLossHit()
  {
   if(InpMaxDailyLossPct <= 0) return false;
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_dayStart)
     {
      g_dayStart = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
     }
   return (g_dayStartEquity > 0 &&
           AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpMaxDailyLossPct / 100.0));
  }

bool FridayCloseTime()
  {
   if(InpFridayCloseHour < 0) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_week == 5 && (dt.hour > InpFridayCloseHour || (dt.hour == InpFridayCloseHour && dt.min >= InpFridayCloseMin));
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ulong ticket = 0;
   bool inPos = HasPosition(ticket);
   DailyLossHit();   // keeps the daily anchor current

   //--- weekend flat
   if(inPos && FridayCloseTime())
     {
      g_trade.PositionClose(ticket);
      return;
     }

   //--- act once per new bar of the signal timeframe
   datetime bt = iTime(_Symbol, InpTF, 0);
   if(bt == 0 || bt == g_lastBar)
      return;

   //--- time exit
   if(inPos && PositionSelectByTicket(ticket))
     {
      datetime et = (datetime)PositionGetInteger(POSITION_TIME);
      int held = iBarShift(_Symbol, InpTF, et, false);
      if(held > InpMaxHoldBars)
        {
         if(g_trade.PositionClose(ticket)) inPos = false;
        }
     }

   double mid, mae, upO, loO;
   datetime sigBar;
   int sig = ComputeSignal(mid, mae, upO, loO, sigBar);
   if(sig == -2)
      return;          // history still loading: retry on next tick, bar not marked done
   g_lastBar = bt;
   if(sig == 0 || inPos)
      return;
   if((sig == 1 && !InpAllowLong) || (sig == -1 && !InpAllowShort))
      return;
   if(FridayCloseTime() || DailyLossHit())
      return;
   if(SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID) > InpMaxSpread)
     {
      Print("HighwayMatrixEA: spread too wide, signal skipped");
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;

   double entry, sl, tp;
   if(sig == -1)
     {
      entry = bid;
      sl = upO + InpSlBufMAE * mae;
      tp = mid;
      if(tp >= entry || sl <= entry) return;                 // research skips these too
      if(sl - entry < minDist || entry - tp < minDist) return;
     }
   else
     {
      entry = ask;
      sl = loO - InpSlBufMAE * mae;
      tp = mid;
      if(tp <= entry || sl >= entry) return;
      if(entry - sl < minDist || tp - entry < minDist) return;
     }
   sl = NormalizeDouble(sl, dg);
   tp = NormalizeDouble(tp, dg);

   double lots = LotsForRisk(MathAbs(entry - sl));
   if(lots <= 0)
     {
      Print("HighwayMatrixEA: lot size below minimum for the configured risk, signal skipped");
      return;
     }

   string cmt = "HWM " + (sig == 1 ? "buy" : "sell");
   bool ok = (sig == 1) ? g_trade.Buy(lots, _Symbol, 0, sl, tp, cmt)
                        : g_trade.Sell(lots, _Symbol, 0, sl, tp, cmt);
   if(!ok)
      PrintFormat("HighwayMatrixEA: order failed %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
  }
//+------------------------------------------------------------------+
