//+------------------------------------------------------------------+
//|                                     MathematicalIndicatorEA.mq5  |
//|  MT5 port of "The Mathematical Indicator · 2-Candle Bias"        |
//|  (roan-maverick/tradingview-mathematical-indicator @ 8a53719,    |
//|  MIT). Logic follows research/mi.py exec="ea", the realistic     |
//|  execution model, with ticks in place of 5m sub-bars.            |
//|                                                                  |
//|  WARNING: backtested on gold (PAXG proxy, 2024-06..2026-11) this |
//|  strategy LOST money: PF ~0.5 at default settings, every year    |
//|  negative, confirmed by an independent audit. Built on request   |
//|  for verification in the Strategy Tester. Do not run it live.    |
//+------------------------------------------------------------------+
#property copyright   "Port of roan-maverick/tradingview-mathematical-indicator (MIT)"
#property version     "1.00"
#property description "2-candle bias session strategy: story -> zone -> range breakout -> rubber-band stop entry."
#property description "Backtested NEGATIVE on gold (PF ~0.5). For Strategy Tester verification only."

#include <Trade/Trade.mqh>

//--- inputs (script defaults)
input group "Timeframes"
input ENUM_TIMEFRAMES InpTF   = PERIOD_M15;  // Chart / signal timeframe
input int    InpWarmupBars    = 3000;        // Bars replayed at start to rebuild levels and zones

input group "Server time"
input int    InpServerGMT     = 2;           // Broker server GMT offset in winter (hours)
input bool   InpServerUSDST   = true;        // Server adds +1h during US daylight saving (typical GMT+2/+3)

input group "Sessions (first hour, local time)"
input bool   InpAsia   = true;   input string InpAsiaT  = "09:00-10:00"; // Asia (Tokyo)
input bool   InpLondon = true;   input string InpLonT   = "08:00-09:00"; // London
input bool   InpNY     = false;  input string InpNYT    = "08:30-09:30"; // New York
input bool   InpNYSE   = true;   input string InpNYSET  = "09:30-10:30"; // NYSE open (New York)
input bool   InpPower  = false;  input string InpPowT   = "15:00-16:00"; // Power hour (New York)
input int    InpMaxTradesSess = 2;           // Max trades per session
input int    InpMaxHoldMin    = 240;         // Close a trade still open after (minutes, 0 = never)

input group "Story"
enum ENUM_TIE { TIE_STORY = 0, // Tell the story
                TIE_DAILY = 1, // Daily candle wins
                TIE_SKIP  = 2  // Stand aside
              };
input ENUM_TIE InpTie         = TIE_STORY;   // When the 2 candles disagree
input int    InpStairLen      = 2;           // Staircase swing strength

input group "Levels"
input int    InpPivHtf        = 1;           // Daily & 4H: candles each side of the turn
input int    InpPivLtf        = 2;           // 1H & chart: candles each side of the turn
input int    InpKeepLvl       = 3;           // Keep levels per timeframe per side
input double InpMergeAtr      = 0.15;        // Merge levels closer than (x ATR of their timeframe)

input group "Clean zones"
input int    InpZoneRun       = 3;           // Min candles in one direction
input double InpZoneMove      = 1.5;         // Min move (x ATR)
input bool   InpZoneReq       = true;        // Entries must be inside a clean zone
input int    InpKeepZones     = 8;           // Keep zones

input group "Positioning / mode"
input double InpProxAtr       = 0.25;        // 'At' a daily level = within (x daily ATR)
input bool   InpBlockCeil     = true;        // No buys at a daily ceiling, no sells at a daily floor
input bool   InpModeOn        = true;        // If the pre-session 4H candle already ran, wait for a pullback
input double InpTrendBody     = 60;          // Ran = body at least % of the candle
input double InpTrendSize     = 1.0;         // ...and size at least (x 4H ATR)
input double InpPbDepth       = 38.2;        // Pullback depth into the pre-session candle (%)

input group "Trigger"
input int    InpMinRange      = 3;           // Range: min candles
input int    InpMaxRange      = 20;          // Range: max candles
input int    InpMinOpp        = 2;           // Range: min opposite candles
input double InpMinRangeAtr   = 0.5;         // Range: min height (x ATR)
input double InpMaxRangeAtr   = 4.0;         // Range: max height (x ATR)
input double InpMinBody       = 50;          // Breakout candle: body at least % of the candle
input double InpMaxBreak      = 50;          // Breakout candle: no bigger than % of the range
input double InpWickAtr       = 0.10;        // Rubber band dip: at least (x ATR)
input double InpWickPct       = 20;          // Rubber band wick on a closed candle: at least % of it
input int    InpMaxWait       = 6;           // Cancel the setup after (candles)
input double InpStopBuf       = 0.0;         // Stop loss buffer (price units)

input group "Exits"
enum ENUM_EXIT { EX_LEVEL = 0, // 1R partial, then the next level
                 EX_1R    = 1  // 1:1 only
               };
input ENUM_EXIT InpExitPlan   = EX_LEVEL;    // Exit plan
input double InpPartPct       = 50;          // Close % at 1R
input double InpMaxR          = 3.0;         // Target cap when no level is ahead (R)
input bool   InpFastExit      = true;        // Too-fast take profit
input double InpFastR         = 1.5;         // ...once the trade is up at least (R)
input int    InpFastBars      = 3;           // ...after this many straight candles

input group "Risk"
input double InpRiskPct       = 0.5;         // Risk per trade (% equity)
input double InpFixedLots     = 0.0;         // Fixed lots (0 = use risk %)
input double InpMaxSpread     = 0.60;        // Max spread to enter (price units)

input group "Misc"
input ulong  InpMagic         = 20261123;    // Magic number
input int    InpSlippage      = 30;          // Max deviation (points)
input bool   InpShowPanel     = true;        // Show status in the chart comment

//+------------------------------------------------------------------+
struct Level { double price; int dir; int tfc; bool broken; };
struct Zone  { double top; double bot; bool active; };

CTrade   g_trade;
Level    g_lv[];
Zone     g_zn[];

//--- clean-zone state machine
int      z_dir = 0, z_count = 0, z_opp = 0;
double   z_start = 0, z_ext = 0;
bool     z_pend = false; double z_pTop = 0, z_pBot = 0;

//--- session / story state
int      g_prevSess = 0, g_sIdx = 0, g_sBias = 0, g_sMode = 1, g_tradesSess = 0;
double   g_preHi = EMPTY_VALUE, g_preLo = EMPTY_VALUE;
bool     g_blkL = false, g_blkS = false;
string   g_why = "";

//--- setup / trade state: 0 looking, 1 setup working, 2 in trade
int      g_st = 0, g_stAtOpen = 0, g_sd = 0, g_barsSince = 0;
double   g_rTop = 0, g_rBot = 0, g_bHi = 0, g_bLo = 0, g_trig = 0, g_atrLast = 0;
bool     g_wickSeen = false;
double   g_eP = 0, g_sP = 0, g_risk = 0, g_r1 = 0, g_tgt = 0, g_pre = EMPTY_VALUE;
bool     g_beOn = false, g_partDone = false;
int      g_fastCnt = 0;
datetime g_eBarTime = 0;
datetime g_lastBar = 0;
string   g_last = "";

//+------------------------------------------------------------------+
//| Time zones                                                       |
//+------------------------------------------------------------------+
datetime NthSunday(const int year, const int month, const int n)
  {
   MqlDateTime d; ZeroMemory(d); d.year = year; d.mon = month; d.day = 1;
   datetime first = StructToTime(d); TimeToStruct(first, d);
   datetime s = first + ((7 - d.day_of_week) % 7) * 86400;
   if(n > 0) return s + (n - 1) * 7 * 86400;
   MqlDateTime t;
   while(true) { datetime nx = s + 7 * 86400; TimeToStruct(nx, t); if(t.mon != month) break; s = nx; }
   return s;
  }
bool UsDst(const datetime u) { MqlDateTime d; TimeToStruct(u, d); return u >= NthSunday(d.year, 3, 2) + 7 * 3600 && u < NthSunday(d.year, 11, 1) + 6 * 3600; }
bool EuDst(const datetime u) { MqlDateTime d; TimeToStruct(u, d); return u >= NthSunday(d.year, 3, -1) + 3600 && u < NthSunday(d.year, 10, -1) + 3600; }
datetime ServerToUtc(const datetime s)
  {
   datetime u = s - InpServerGMT * 3600;
   if(InpServerUSDST && UsDst(u - 3600)) u -= 3600;
   return u;
  }
int MinOfDay(const datetime t) { MqlDateTime d; TimeToStruct(t, d); return d.hour * 60 + d.min; }
int LocalMin(const datetime srv, const int zone)   // 0 Tokyo, 1 London, 2 New York
  {
   datetime u = ServerToUtc(srv);
   if(zone == 0) return MinOfDay(u + 9 * 3600);
   if(zone == 1) return MinOfDay(u + (EuDst(u) ? 3600 : 0));
   return MinOfDay(u - (UsDst(u) ? 4 : 5) * 3600);
  }
bool InWin(const datetime srv, const int zone, const string win)
  {
   int a = (int)StringToInteger(StringSubstr(win, 0, 2)) * 60 + (int)StringToInteger(StringSubstr(win, 3, 2));
   int b = (int)StringToInteger(StringSubstr(win, 6, 2)) * 60 + (int)StringToInteger(StringSubstr(win, 9, 2));
   int m = LocalMin(srv, zone);
   return m >= a && m < b;
  }
int SessionOf(const datetime barOpen)   // first match wins, like the script
  {
   if(InpAsia   && InWin(barOpen, 0, InpAsiaT)) return 1;
   if(InpLondon && InWin(barOpen, 1, InpLonT))  return 2;
   if(InpNY     && InWin(barOpen, 2, InpNYT))   return 3;
   if(InpNYSE   && InWin(barOpen, 2, InpNYSET)) return 4;
   if(InpPower  && InWin(barOpen, 2, InpPowT))  return 5;
   return 0;
  }
string SessName(const int i) { return i == 1 ? "Asia" : i == 2 ? "London" : i == 3 ? "New York" : i == 4 ? "NYSE" : i == 5 ? "Power hour" : "-"; }

//+------------------------------------------------------------------+
//| Indicator maths                                                  |
//+------------------------------------------------------------------+
//--- Wilder ATR(14) seeded with an SMA, like ta.atr; out[] aligned with r[]
void AtrArr(const MqlRates &r[], const int n, double &out[])
  {
   ArrayResize(out, n);
   double s = 0;
   for(int i = 0; i < n; i++)
     {
      double tr = (i == 0) ? r[i].high - r[i].low
                  : MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i - 1].close), MathAbs(r[i].low - r[i - 1].close)));
      if(i < 13)       { s += tr; out[i] = EMPTY_VALUE; }
      else if(i == 13) { s += tr; out[i] = s / 14.0; }
      else               out[i] = (out[i - 1] * 13.0 + tr) / 14.0;
     }
  }

//--- body turn at index j (n candles each side): res / sup or EMPTY_VALUE
void BodyPiv(const MqlRates &r[], const int j, const int n, double &res, double &sup)
  {
   res = EMPTY_VALUE; sup = EMPTY_VALUE;
   if(j - (2 * n - 1) < 0) return;
   bool isR = true, isS = true; double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < 2 * n; i++)
     {
      bool g = r[j - i].close > r[j - i].open, rd = r[j - i].close < r[j - i].open;
      if(i < n) { isR = isR && rd; isS = isS && g; }
      else      { isR = isR && g;  isS = isS && rd; }
      hi = MathMax(hi, MathMax(r[j - i].open, r[j - i].close));
      lo = MathMin(lo, MathMin(r[j - i].open, r[j - i].close));
     }
   if(isR) res = hi;
   if(isS) sup = lo;
  }

//--- staircase at the last element: 1 up, -1 down, 0 box, 2 = not enough swings
int StairLast(const MqlRates &r[], const int n, const int ln)
  {
   double h1 = EMPTY_VALUE, h2 = EMPTY_VALUE, l1 = EMPTY_VALUE, l2 = EMPTY_VALUE;
   for(int j = 0; j < n; j++)
     {
      int p = j - ln;
      if(p - ln < 0) continue;
      double lmaxH = -DBL_MAX, rmaxH = -DBL_MAX, lminL = DBL_MAX, rminL = DBL_MAX;
      for(int k = 1; k <= ln; k++)
        {
         lmaxH = MathMax(lmaxH, r[p - k].high); rmaxH = MathMax(rmaxH, r[p + k].high);
         lminL = MathMin(lminL, r[p - k].low);  rminL = MathMin(rminL, r[p + k].low);
        }
      if(r[p].high > lmaxH && r[p].high >= rmaxH) { h2 = h1; h1 = r[p].high; }
      if(r[p].low  < lminL && r[p].low  <= rminL) { l2 = l1; l1 = r[p].low; }
     }
   if(h2 == EMPTY_VALUE || l2 == EMPTY_VALUE) return 2;
   if(h1 > h2 && l1 > l2) return 1;
   if(h1 < h2 && l1 < l2) return -1;
   return 0;
  }

//--- previous CLOSED higher-timeframe candle relative to chart time t
bool HtfPrev(const ENUM_TIMEFRAMES tf, const datetime t, const int need, MqlRates &h[], double &atr[])
  {
   int sh = iBarShift(_Symbol, tf, t, false);
   if(sh < 0) return false;
   ArraySetAsSeries(h, false);
   int n = CopyRates(_Symbol, tf, sh + 1, need, h);     // h[n-1] = previous closed HTF candle
   if(n < 16) return false;
   AtrArr(h, n, atr);
   return true;
  }

//+------------------------------------------------------------------+
//| Levels and zones                                                 |
//+------------------------------------------------------------------+
void Trim(const int tfc, const int dir)
  {
   int cnt = 0, brk = 0;
   for(int i = ArraySize(g_lv) - 1; i >= 0; i--)
     {
      if(g_lv[i].tfc != tfc || g_lv[i].dir != dir) continue;
      if(g_lv[i].broken) { brk++; if(brk > 1) ArrayRemove(g_lv, i, 1); }
      else               { cnt++; if(cnt > InpKeepLvl) ArrayRemove(g_lv, i, 1); }
     }
  }

void AddLevel(const double px, const int dir, const int tfc, const double tol)
  {
   for(int i = 0; i < ArraySize(g_lv); i++)
      if(g_lv[i].tfc == tfc && g_lv[i].dir == dir && !g_lv[i].broken && MathAbs(g_lv[i].price - px) <= tol)
         return;                                         // merged: a touch, no new level
   int k = ArraySize(g_lv); ArrayResize(g_lv, k + 1);
   g_lv[k].price = px; g_lv[k].dir = dir; g_lv[k].tfc = tfc; g_lv[k].broken = false;
   Trim(tfc, dir);
   if(tfc >= 1 && tfc <= 3)                             // a new 4H/1H level inside a clean zone makes it messy
      for(int z = 0; z < ArraySize(g_zn); z++)
        {
         double pad = (g_zn[z].top - g_zn[z].bot) * 0.08;
         if(g_zn[z].active && px > g_zn[z].bot + pad && px < g_zn[z].top - pad) g_zn[z].active = false;
        }
  }

void Feed(const int tfc, const double c, const double res, const double sup, const double tol)
  {
   for(int i = 0; i < ArraySize(g_lv); i++)
      if(g_lv[i].tfc == tfc && !g_lv[i].broken && ((g_lv[i].dir == 1) ? c > g_lv[i].price : c < g_lv[i].price))
         g_lv[i].broken = true;
   Trim(tfc, 1); Trim(tfc, -1);
   if(res != EMPTY_VALUE) AddLevel(res, 1, tfc, tol);
   if(sup != EMPTY_VALUE) AddLevel(sup, -1, tfc, tol);
  }

bool FeedHtf(const ENUM_TIMEFRAMES tf, const int tfc, const int n, const datetime t)
  {
   MqlRates h[]; double a[];
   if(!HtfPrev(tf, t, 520, h, a)) return false;
   int j = ArraySize(h) - 1;
   double res, sup; BodyPiv(h, j, n, res, sup);
   Feed(tfc, h[j].close, res, sup, InpMergeAtr * (a[j] == EMPTY_VALUE ? 0 : a[j]));
   return true;
  }

double NextLevel(const int side, const double from, const double minDist)
  {
   double best = EMPTY_VALUE;
   for(int i = 0; i < ArraySize(g_lv); i++)
     {
      if(g_lv[i].broken || g_lv[i].dir != side) continue;
      double p = g_lv[i].price;
      bool ahead = side == 1 ? p > from + minDist : p < from - minDist;
      if(ahead && (best == EMPTY_VALUE || (side == 1 ? p < best : p > best))) best = p;
     }
   return best;
  }

bool InZone(const double px)
  {
   for(int z = 0; z < ArraySize(g_zn); z++)
      if(g_zn[z].active && px >= g_zn[z].bot && px <= g_zn[z].top) return true;
   return false;
  }

void DailyProximity(const double px, const double prox, bool &atC, bool &atF)
  {
   atC = false; atF = false;
   for(int i = 0; i < ArraySize(g_lv); i++)
     {
      if(g_lv[i].tfc != 0 || g_lv[i].broken) continue;
      if(g_lv[i].dir == 1 && px >= g_lv[i].price - prox) atC = true;
      if(g_lv[i].dir == -1 && px <= g_lv[i].price + prox) atF = true;
     }
  }

//+------------------------------------------------------------------+
//| Process one CLOSED chart bar (at series shift `s`)               |
//| live=false during warm-up: state only, no setups or trades.      |
//+------------------------------------------------------------------+
bool ProcessBarClose(const int s, const bool live)
  {
   MqlRates r[]; ArraySetAsSeries(r, false);
   int n = CopyRates(_Symbol, InpTF, s, 650, r);        // r[n-1] = the closed bar
   if(n < 100) return false;
   double a[]; AtrArr(r, n, a);
   const int i = n - 1;
   const datetime t = r[i].time;
   //--- all higher-timeframe history must be ready BEFORE any state changes (a retry must not double-count)
   ENUM_TIMEFRAMES need[4] = {PERIOD_D1, PERIOD_H4, PERIOD_H1, PERIOD_W1};
   for(int q = 0; q < 4; q++)
     {
      int sh = iBarShift(_Symbol, need[q], t, false);
      if(sh < 0 || iTime(_Symbol, need[q], sh + 1) == 0 || Bars(_Symbol, need[q]) < 30) return false;
     }

   //--- ① levels: D, 4H, 1H on a new higher-timeframe candle, then the chart's own
   if(iBarShift(_Symbol, PERIOD_D1, t) != iBarShift(_Symbol, PERIOD_D1, r[i - 1].time) && !FeedHtf(PERIOD_D1, 0, InpPivHtf, t)) return false;
   if(iBarShift(_Symbol, PERIOD_H4, t) != iBarShift(_Symbol, PERIOD_H4, r[i - 1].time) && !FeedHtf(PERIOD_H4, 1, InpPivHtf, t)) return false;
   if(iBarShift(_Symbol, PERIOD_H1, t) != iBarShift(_Symbol, PERIOD_H1, r[i - 1].time) && !FeedHtf(PERIOD_H1, 2, InpPivLtf, t)) return false;
   double cres, csup; BodyPiv(r, i, InpPivLtf, cres, csup);
   Feed(4, r[i].close, cres, csup, InpMergeAtr * (a[i] == EMPTY_VALUE ? 0 : a[i]));

   //--- clean zone found on the previous bar becomes active now
   if(z_pend)
     {
      int k = ArraySize(g_zn); ArrayResize(g_zn, k + 1);
      g_zn[k].top = z_pTop; g_zn[k].bot = z_pBot; g_zn[k].active = true;
      while(ArraySize(g_zn) > InpKeepZones) ArrayRemove(g_zn, 0, 1);
      z_pend = false;
     }
   //--- clean-move state machine on this bar
   int cd = r[i].close > r[i].open ? 1 : r[i].close < r[i].open ? -1 : 0;
   if(z_dir == 0)
     { if(cd != 0) { z_dir = cd; z_count = 1; z_opp = 0; z_start = r[i].open; z_ext = r[i].close; } }
   else if(cd == z_dir)
     {
      z_count++; z_opp = 0;
      if((z_dir == 1 && r[i].close > z_ext) || (z_dir == -1 && r[i].close < z_ext)) z_ext = r[i].close;
     }
   else if(cd == -z_dir)
     {
      z_opp++;
      if(z_opp >= 2)
        {
         if(z_count >= InpZoneRun && a[i] != EMPTY_VALUE && MathAbs(z_ext - z_start) >= InpZoneMove * a[i])
           { z_pend = true; z_pTop = MathMax(z_start, z_ext); z_pBot = MathMin(z_start, z_ext); }
         z_dir = cd; z_count = 2; z_opp = 0; z_start = r[i - 1].open;
         z_ext = cd == 1 ? MathMax(r[i].close, r[i - 1].close) : MathMin(r[i].close, r[i - 1].close);
        }
     }

   int sess = SessionOf(t);
   if(a[i] == EMPTY_VALUE) { g_prevSess = sess; return true; }
   g_atrLast = a[i];

   //--- daily ATR (cached per day) + proximity, needed for blocks and the MIXED tie-break
   static datetime dKey = 0;
   static double   dAtrC = EMPTY_VALUE;
   int dsh = iBarShift(_Symbol, PERIOD_D1, t);
   datetime key = (dsh >= 0) ? iTime(_Symbol, PERIOD_D1, dsh + 1) : 0;
   if(key == 0) return false;
   if(key != dKey)
     {
      MqlRates dx[]; double dxa[];
      if(!HtfPrev(PERIOD_D1, t, 520, dx, dxa)) return false;
      dKey = key; dAtrC = dxa[ArraySize(dxa) - 1];
     }
   double prox = InpProxAtr * (dAtrC != EMPTY_VALUE ? dAtrC : a[i] * 10);
   bool atC, atF; DailyProximity(r[i].close, prox, atC, atF);

   //--- new broker day resets the blocks
   MqlDateTime d0, d1; TimeToStruct(t, d0); TimeToStruct(r[i - 1].time, d1);
   if(d0.day != d1.day || d0.mon != d1.mon || d0.year != d1.year) { g_blkL = false; g_blkS = false; }

   //--- ① story, frozen at the first bar of each session window
   if(sess != 0 && sess != g_prevSess)
     {
      MqlRates hh[], dh[]; double ha[], da[];
      if(!HtfPrev(PERIOD_H4, t, 520, hh, ha) || !HtfPrev(PERIOD_D1, t, 520, dh, da)) return false;
      int hj = ArraySize(hh) - 1, dj = ArraySize(dh) - 1;
      int dDir = dh[dj].close > dh[dj].open ? 1 : dh[dj].close < dh[dj].open ? -1 : 0;
      int hDir = hh[hj].close > hh[hj].open ? 1 : hh[hj].close < hh[hj].open ? -1 : 0;
      MqlRates wr[]; ArraySetAsSeries(wr, false);
      int story = 2, wsh = iBarShift(_Symbol, PERIOD_W1, t);
      int wn = (wsh >= 0) ? CopyRates(_Symbol, PERIOD_W1, wsh + 1, 300, wr) : 0;
      if(wn > 0) story = StairLast(wr, wn, InpStairLen);
      if(story == 2) story = StairLast(dh, ArraySize(dh), InpStairLen);
      int bias; string why;
      if(dDir != 0 && dDir == hDir)              { bias = dDir; why = "2 candles agree"; }
      else if(InpTie == TIE_SKIP)                { bias = 0;    why = "mixed -> stand aside"; }
      else if(InpTie == TIE_DAILY)               { bias = dDir; why = "mixed -> daily wins"; }
      else if(atC && !atF)                       { bias = -1;   why = "mixed -> at daily ceiling"; }
      else if(atF && !atC)                       { bias = 1;    why = "mixed -> at daily floor"; }
      else if(story == 1 || story == -1)         { bias = story; why = "mixed -> staircase"; }
      else                                       { bias = dDir != 0 ? dDir : hDir; why = "mixed -> daily candle"; }
      double pr = hh[hj].high - hh[hj].low;
      bool preRan = pr > 0 && MathAbs(hh[hj].close - hh[hj].open) >= InpTrendBody / 100.0 * pr &&
                    ha[hj] != EMPTY_VALUE && pr >= InpTrendSize * ha[hj];
      int preDir = hh[hj].close > hh[hj].open ? 1 : hh[hj].close < hh[hj].open ? -1 : 0;
      g_sBias = bias; g_why = why;
      g_sMode = (InpModeOn && preRan && preDir == bias && bias != 0) ? 2 : 1;
      g_preHi = hh[hj].high; g_preLo = hh[hj].low; g_sIdx = sess; g_tradesSess = 0;
     }
   g_prevSess = sess;
   if(sess != 0 && InpBlockCeil)
     {
      if(g_sBias == 1 && atC)  g_blkL = true;
      if(g_sBias == -1 && atF) g_blkS = true;
     }

   //--- ③ look for a breakout candle (only if flat for the whole bar)
   if(live && g_st == 0 && g_stAtOpen == 0 && sess != 0 && g_sIdx == sess && g_tradesSess < InpMaxTradesSess &&
      g_sBias != 0 && i >= InpMaxRange + 1)
      LookForBreakout(r, i, a[i]);

   //--- working setup: close-of-bar checks
   if(live && g_st == 1 && g_stAtOpen == 1)
     {
      double lw = g_sd == 1 ? MathMin(r[i].open, r[i].close) - r[i].low : r[i].high - MathMax(r[i].open, r[i].close);
      double rg = r[i].high - r[i].low;
      if(lw >= InpWickAtr * a[i] && rg > 0 && lw >= InpWickPct / 100.0 * rg) g_wickSeen = true;
      g_barsSince++;
      if(g_sd == 1 ? r[i].close < g_rTop : r[i].close > g_rBot) CancelSetup("closed back inside the range");
      else if(g_barsSince >= InpMaxWait)                         CancelSetup("setup expired");
     }

   //--- open trade: too-fast and time exits (not on the fill bar)
   if(live && g_st == 2 && t != g_eBarTime)
     {
      ulong tk; double vol;
      if(PositionOpen(tk, vol))
        {
         bool straight = g_sd == 1 ? (r[i].close > r[i].open && r[i].close > r[i - 1].close)
                                   : (r[i].close < r[i].open && r[i].close < r[i - 1].close);
         g_fastCnt = straight ? g_fastCnt + 1 : 0;
         double rNow = (r[i].close - g_eP) * g_sd / g_risk;
         if(InpFastExit && rNow >= InpFastR && g_fastCnt >= InpFastBars) CloseTrade(tk, "too fast - took profit");
         else if(InpMaxHoldMin > 0 && (t + PeriodSeconds(InpTF) - g_eBarTime) >= InpMaxHoldMin * 60) CloseTrade(tk, "time exit");
         SaveState();
        }
     }
   return true;
  }

void LookForBreakout(const MqlRates &r[], const int i, const double atr)
  {
   int side = g_sBias;
   bool ok = false; double top = 0, bot = 0, T = 0, B = 0; int opp = 0;
   for(int k = 1; k <= InpMaxRange; k++)
     {
      double bt = MathMax(r[i - k].open, r[i - k].close), bb = MathMin(r[i - k].open, r[i - k].close);
      T = (k == 1) ? bt : MathMax(T, bt); B = (k == 1) ? bb : MathMin(B, bb);
      if(side == 1 ? r[i - k].close < r[i - k].open : r[i - k].close > r[i - k].open) opp++;
      if(T - B > InpMaxRangeAtr * atr) break;
      bool outside = side == 1 ? r[i].close > T : r[i].close < B;
      if(k >= InpMinRange && opp >= InpMinOpp && T - B >= InpMinRangeAtr * atr && outside) { ok = true; top = T; bot = B; }
     }
   double rg = r[i].high - r[i].low;
   bool strong = rg > 0 && MathAbs(r[i].close - r[i].open) >= InpMinBody / 100.0 * rg;
   bool dirOk  = side == 1 ? r[i].close > r[i].open : r[i].close < r[i].open;
   if(!(ok && dirOk && strong)) return;
   double hgt = top - bot, px = side == 1 ? r[i].high : r[i].low;
   double pb = side == 1 ? g_preHi - InpPbDepth / 100.0 * (g_preHi - g_preLo) : g_preLo + InpPbDepth / 100.0 * (g_preHi - g_preLo);
   if(side == 1 ? g_blkL : g_blkS)                                  { g_last = "skip: at daily level, come back tomorrow"; return; }
   if(rg > InpMaxBreak / 100.0 * hgt)                               { g_last = "skip: breakout candle too big"; return; }
   if(g_sMode == 2 && !(side == 1 ? bot <= pb : top >= pb))         { g_last = "skip: pre-session ran, wait for pullback"; return; }
   if(InpZoneReq && !InZone(px))                                    { g_last = "skip: no clean zone"; return; }
   g_st = 1; g_sd = side; g_rTop = top; g_rBot = bot; g_bHi = r[i].high; g_bLo = r[i].low;
   g_trig = px; g_wickSeen = false; g_barsSince = 0;
   g_last = StringFormat("setup %s, trigger %s", side == 1 ? "BUY" : "SELL", DoubleToString(px, _Digits));
   Print("MI EA: ", g_last);
  }

void CancelSetup(const string why) { g_st = 0; g_last = "cancel: " + why; Print("MI EA: ", g_last); }

//+------------------------------------------------------------------+
//| Orders, positions and state persistence                          |
//+------------------------------------------------------------------+
bool PositionOpen(ulong &ticket, double &vol)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
        { ticket = tk; vol = PositionGetDouble(POSITION_VOLUME); return true; }
     }
   return false;
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
   if(lots < minL) return 0;
   return MathMin(lots, maxL);
  }

void SetTargets()
  {
   g_r1 = g_eP + g_sd * g_risk;
   double nl  = NextLevel(g_sd, g_eP, g_risk * 0.05);
   double far = NextLevel(g_sd, g_r1 - g_sd * g_risk * 0.02, 0);
   double cap = g_eP + g_sd * InpMaxR * g_risk;
   if(InpExitPlan == EX_1R) g_tgt = g_r1;
   else g_tgt = (far == EMPTY_VALUE || (g_sd == 1 ? far > cap : far < cap)) ? cap : far;
   g_pre = (nl != EMPTY_VALUE && (g_sd == 1 ? nl < g_r1 : nl > g_r1)) ? nl : EMPTY_VALUE;
  }

void Enter()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask - bid > InpMaxSpread) return;                 // keep the setup; retry on the next tick
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double stp = g_sd == 1 ? g_bLo - InpStopBuf : g_bHi + InpStopBuf;
   double px = g_sd == 1 ? ask : bid;
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
   if((g_sd == 1 ? px - stp : stp - px) < minDist) { CancelSetup("no room for a stop"); return; }
   g_eP = px; g_risk = MathAbs(px - stp); g_sP = stp; SetTargets();
   double lots = LotsForRisk(g_risk);
   if(lots <= 0) { CancelSetup("min lot exceeds the risk budget"); return; }
   bool ok = g_sd == 1 ? g_trade.Buy(lots, _Symbol, 0, NormalizeDouble(stp, dg), NormalizeDouble(g_tgt, dg), "MI long")
                       : g_trade.Sell(lots, _Symbol, 0, NormalizeDouble(stp, dg), NormalizeDouble(g_tgt, dg), "MI short");
   if(!ok) { PrintFormat("MI EA: entry failed %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()); return; }
   //--- recompute 1R / target from the real fill price
   ulong tk; double vol;
   if(PositionOpen(tk, vol) && PositionSelectByTicket(tk))
     {
      g_eP = PositionGetDouble(POSITION_PRICE_OPEN); g_risk = MathAbs(g_eP - stp); SetTargets();
      g_trade.PositionModify(tk, NormalizeDouble(stp, dg), NormalizeDouble(g_tgt, dg));
     }
   g_st = 2; g_beOn = false; g_partDone = false; g_fastCnt = 0;
   g_eBarTime = iTime(_Symbol, InpTF, 0); g_tradesSess++;
   g_last = StringFormat("ENTRY %s %s, stop %s, 1R %s, target %s", g_sd == 1 ? "BUY" : "SELL", DoubleToString(g_eP, dg),
                         DoubleToString(stp, dg), DoubleToString(g_r1, dg), DoubleToString(g_tgt, dg));
   Print("MI EA: ", g_last);
   SaveState();
  }

void CloseTrade(const ulong tk, const string why)
  {
   if(g_trade.PositionClose(tk)) { g_st = 0; g_last = "exit: " + why; Print("MI EA: ", g_last); ClearState(); }
  }

void MoveToBreakeven(const ulong tk)
  {
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp = PositionSelectByTicket(tk) ? PositionGetDouble(POSITION_TP) : 0;
   if(g_trade.PositionModify(tk, NormalizeDouble(g_eP, dg), tp)) { g_beOn = true; g_sP = g_eP; }
   else PrintFormat("MI EA: breakeven move failed %d (stops level?) - will retry", g_trade.ResultRetcode());
  }

string GvName(const string k) { return StringFormat("MIEA_%I64u_%s_%s", InpMagic, _Symbol, k); }
void SaveState()
  {
   GlobalVariableSet(GvName("sd"), g_sd);     GlobalVariableSet(GvName("eP"), g_eP);
   GlobalVariableSet(GvName("risk"), g_risk); GlobalVariableSet(GvName("r1"), g_r1);
   GlobalVariableSet(GvName("tgt"), g_tgt);   GlobalVariableSet(GvName("pre"), g_pre);
   GlobalVariableSet(GvName("be"), g_beOn);   GlobalVariableSet(GvName("part"), g_partDone);
   GlobalVariableSet(GvName("fast"), g_fastCnt); GlobalVariableSet(GvName("eBar"), (double)g_eBarTime);
  }
void ClearState() { GlobalVariablesDeleteAll(StringFormat("MIEA_%I64u_%s_", InpMagic, _Symbol)); }
bool LoadState()
  {
   if(!GlobalVariableCheck(GvName("sd"))) return false;
   g_sd = (int)GlobalVariableGet(GvName("sd"));     g_eP = GlobalVariableGet(GvName("eP"));
   g_risk = GlobalVariableGet(GvName("risk"));      g_r1 = GlobalVariableGet(GvName("r1"));
   g_tgt = GlobalVariableGet(GvName("tgt"));        g_pre = GlobalVariableGet(GvName("pre"));
   g_beOn = GlobalVariableGet(GvName("be")) != 0;   g_partDone = GlobalVariableGet(GvName("part")) != 0;
   g_fastCnt = (int)GlobalVariableGet(GvName("fast")); g_eBarTime = (datetime)GlobalVariableGet(GvName("eBar"));
   return true;
  }

//+------------------------------------------------------------------+
//| Tick logic: rubber-band entry and live management                |
//+------------------------------------------------------------------+
void TickSetup()
  {
   double o = iOpen(_Symbol, InpTF, 0);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double need = InpWickAtr * g_atrLast;
   //--- dip first: price moved against the trade by the rubber-band distance from this bar's open
   if(g_sd == 1 ? o - iLow(_Symbol, InpTF, 0) >= need : iHigh(_Symbol, InpTF, 0) - o >= need) g_wickSeen = true;
   bool hit = g_sd == 1 ? bid >= g_trig : bid <= g_trig;
   if(!hit) return;
   if(!g_wickSeen) { CancelSetup("broke with no dip first"); return; }
   Enter();
  }

void TickManage()
  {
   ulong tk; double vol;
   if(!PositionOpen(tk, vol)) { g_st = 0; g_last = "exit: stop or target hit"; ClearState(); return; }
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double px = g_sd == 1 ? bid : ask;                    // the price the position would close at
   if(!g_partDone && (g_sd == 1 ? px >= g_r1 : px <= g_r1))
     {
      if(InpExitPlan == EX_1R) { CloseTrade(tk, "1:1 target"); return; }
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double part = MathFloor(vol * InpPartPct / 100.0 / step) * step;
      if(part >= minL && vol - part >= minL) g_trade.PositionClosePartial(tk, part);
      g_partDone = true;
      if(!g_beOn) MoveToBreakeven(tk);
      g_last = "1R reached: partial banked, stop to breakeven";
      SaveState();
     }
   if(!g_beOn && g_pre != EMPTY_VALUE && (g_sd == 1 ? px >= g_pre : px <= g_pre)) { MoveToBreakeven(tk); SaveState(); }
   if(g_partDone && !g_beOn) MoveToBreakeven(tk);       // retry a failed move
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMaxRange < InpMinRange || InpKeepLvl < 1 || InpKeepZones < 1 || InpWarmupBars < 200) return INIT_PARAMETERS_INCORRECT;
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   ArrayResize(g_lv, 0); ArrayResize(g_zn, 0);
   //--- rebuild levels, zones and session state from history (no trading)
   int avail = Bars(_Symbol, InpTF);
   int start = MathMin(InpWarmupBars, avail - 700);
   for(int s = start; s >= 2; s--) ProcessBarClose(s, false);
   g_lastBar = iTime(_Symbol, InpTF, 1);                  // bar 1 is processed live on the next new bar
   //--- resume an open trade after a restart
   ulong tk; double vol;
   if(PositionOpen(tk, vol))
     {
      if(LoadState()) { g_st = 2; g_stAtOpen = 2; Print("MI EA: resumed management of the open trade"); }
      else Print("MI EA: open position found but no saved state; it keeps its server stop/target only");
     }
   else ClearState();
   Print("MI EA: warm-up done, ", ArraySize(g_lv), " levels, ", ArraySize(g_zn), " zones. Backtested NEGATIVE on gold: demo/tester only.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
  {
   datetime b0 = iTime(_Symbol, InpTF, 0);
   if(b0 != 0 && b0 != g_lastBar)
     {
      //--- the bar that just closed is shift 1
      if(!ProcessBarClose(1, true)) return;              // history loading: retry on the next tick
      g_lastBar = b0;
      g_stAtOpen = g_st;                                  // state entering the new bar
     }
   if(g_st == 1) TickSetup();
   else if(g_st == 2) TickManage();
   if(InpShowPanel)
      Comment(StringFormat("Mathematical Indicator EA (backtested NEGATIVE on gold - tester/demo only)\n"
                           "Session: %s   Bias: %s (%s)   Mode: %s\nBlocked: buys %s, sells %s\nState: %s\nLast: %s\nLevels %d, zones %d",
                           SessName(SessionOf(iTime(_Symbol, InpTF, 0))), g_sBias == 1 ? "BUY only" : g_sBias == -1 ? "SELL only" : "none",
                           g_why, g_sMode == 2 ? "wait for pullback" : "breakouts", g_blkL ? "yes" : "no", g_blkS ? "yes" : "no",
                           g_st == 0 ? "looking" : g_st == 1 ? "setup working" : "in trade", g_last, ArraySize(g_lv), ArraySize(g_zn)));
  }
//+------------------------------------------------------------------+
