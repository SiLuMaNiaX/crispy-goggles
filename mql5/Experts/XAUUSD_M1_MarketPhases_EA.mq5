//+------------------------------------------------------------------+
//|                                  XAUUSD_M1_MarketPhases_EA.mq5   |
//|  MT5 Expert Advisor port of the TradingView indicator             |
//|  "XAUUSD M1 - Economics + Structure + Market Phases" (Pine v6).   |
//|                                                                  |
//|  The signal engine reproduces the Pine logic bar by bar on        |
//|  CLOSED candles only (Pine barstate.isconfirmed). Shift 1 in this |
//|  file is the candle that has just closed; shift 1+k is Pine [k].  |
//|                                                                  |
//|  Trading layer (not in the original indicator) is added on top:   |
//|  entries on confirmed BUY/SELL, ATR stop, R-multiple target,      |
//|  optional exit on opposite signal / failed breakout.              |
//+------------------------------------------------------------------+
#property copyright "Port of Pine indicator - use at your own risk"
#property version   "1.00"

#include <Trade\Trade.mqh>

//=====================================================================
// 1. INPUTS (mirrors the Pine inputs)
//=====================================================================
input group "1. Market Structure"
input int    InpPivotLen            = 3;     // Pivot Confirmation Length
input bool   InpShowSwingBreaks     = true;  // Show Structural Breaks

input group "2. Trading Range"
input int    InpRangeLookback       = 30;    // Range Lookback
input int    InpAtrLen              = 7;     // ATR Length (Wilder/RMA, like Pine ta.atr)
input double InpRangeAtrMult        = 3.0;   // Maximum Range Width / ATR
input double InpMaxEfficiency       = 0.30;  // Maximum Directional Efficiency
input double InpBreakoutBufferATR   = 0.05;  // Breakout Buffer (ATR)
input bool   InpEnableRangeBreakouts= true;  // Enable Range Breakout Signals

input group "3. Candle Pressure Proxies"
input double InpMinBodyRatio        = 0.50;  // Minimum Candle Body / Full Range
input bool   InpUsePressureFilter   = true;  // Require Candle Pressure Confirmation

input group "4. Signals / Visuals"
input bool   InpShowEarlyWarnings   = true;  // Show Early Reversal Warnings
input bool   InpShowConfirmedSignals= true;  // Show Confirmed BUY / SELL Signals
input bool   InpShowFailedBreakouts = true;  // Show Failed Breakout Markers
input bool   InpShowDashboard       = true;  // Show Market Phase Dashboard
input bool   InpShowPhaseBackground = false; // Tint Background by Market Phase
input bool   InpAlerts              = false; // Pop-up alerts on signals
input int    InpWarmupBars          = 3000;  // History bars used to build state on start

input group "5. Trading"
input bool   InpEnableTrading       = true;  // Enable live order execution
input ulong  InpMagic               = 26111401; // Magic number
input bool   InpUseRiskPercent      = true;  // Size by risk % (else fixed lots)
input double InpRiskPercent         = 0.5;   // Risk % of balance per trade
input double InpFixedLots           = 0.01;  // Fixed lots
input double InpSL_ATR              = 1.5;   // Stop loss distance (x ATR)
input double InpTP_R                = 2.0;   // Take profit (R multiple, 0 = none)
input bool   InpCloseOnOpposite     = true;  // Close on opposite confirmed signal
input bool   InpReverseOnOpposite   = true;  // Open opposite trade after closing
input bool   InpCloseOnFailedBO     = true;  // Close on failed breakout against position
input bool   InpTradeContinuation   = true;  // Trade continuation signals
input bool   InpTradeReversal       = true;  // Trade reversal (transition) signals
input bool   InpTradeRangeBreakout  = true;  // Trade range breakout signals
input int    InpMaxSpreadPoints     = 60;    // Max spread in points (0 = off)
input int    InpSlippagePoints      = 30;    // Max deviation in points
input bool   InpUseSession          = false; // Restrict entries to server hours
input int    InpSessionStartHour    = 8;     // Session start hour (server)
input int    InpSessionEndHour      = 20;    // Session end hour (server, exclusive)

//=====================================================================
// 2. CONSTANTS
//=====================================================================
#define PH_UNCLASSIFIED     0
#define PH_RANGE_DECLINE    1
#define PH_MARKUP           2
#define PH_RANGE_ADVANCE    3
#define PH_MARKDOWN         4
#define PH_BULL_TRANSITION  5
#define PH_BEAR_TRANSITION  6

#define PFX "MPEA_"

//=====================================================================
// PERSISTENT STATE (Pine `var` variables)
//=====================================================================
double   g_lastSwingHigh      = EMPTY_VALUE;
double   g_prevSwingHigh      = EMPTY_VALUE;
double   g_lastSwingLow       = EMPTY_VALUE;
double   g_prevSwingLow       = EMPTY_VALUE;

double   g_activeBOLevel      = EMPTY_VALUE;
int      g_activeBODir        = 0;
long     g_activeBOBar        = -1;

int      g_trendBias          = 0;
int      g_marketPhase        = PH_UNCLASSIFIED;
int      g_lastSignalDir      = 0;

double   g_atr                = EMPTY_VALUE;   // RMA ATR state
long     g_barIndex           = 0;             // running bar counter
datetime g_lastProcessed      = 0;

// Last computed per-bar values (for dashboard)
bool     g_bullishStructure   = false;
bool     g_bearishStructure   = false;
bool     g_bullPressure       = false;
bool     g_bearPressure       = false;
bool     g_compressedRange    = false;
double   g_efficiency         = 0.0;

CTrade   g_trade;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool IsNa(const double v) { return v == EMPTY_VALUE; }

double H(int s) { return iHigh(_Symbol, _Period, s);  }
double L(int s) { return iLow(_Symbol, _Period, s);   }
double O(int s) { return iOpen(_Symbol, _Period, s);  }
double C(int s) { return iClose(_Symbol, _Period, s); }
datetime T(int s) { return iTime(_Symbol, _Period, s); }

double TrueRange(int s)
{
   double h = H(s), l = L(s), pc = C(s + 1);
   return MathMax(h - l, MathMax(MathAbs(h - pc), MathAbs(l - pc)));
}

// Pine ta.pivothigh(high, n, n) evaluated at bar s -> pivot candle is s+n.
// Center must be strictly higher than the n left bars and not exceeded by the n right bars.
double PivotHigh(int s, int n)
{
   int c = s + n;
   double v = H(c);
   for(int i = 1; i <= n; i++)
   {
      if(H(c + i) >= v) return EMPTY_VALUE;   // left side (older)
      if(H(c - i) >  v) return EMPTY_VALUE;   // right side (newer)
   }
   return v;
}

double PivotLow(int s, int n)
{
   int c = s + n;
   double v = L(c);
   for(int i = 1; i <= n; i++)
   {
      if(L(c + i) <= v) return EMPTY_VALUE;
      if(L(c - i) <  v) return EMPTY_VALUE;
   }
   return v;
}

string PhaseName(int p)
{
   switch(p)
   {
      case PH_RANGE_DECLINE:   return "RANGE AFTER DECLINE";
      case PH_MARKUP:          return "MARKUP";
      case PH_RANGE_ADVANCE:   return "RANGE AFTER ADVANCE";
      case PH_MARKDOWN:        return "MARKDOWN";
      case PH_BULL_TRANSITION: return "BULLISH TRANSITION";
      case PH_BEAR_TRANSITION: return "BEARISH TRANSITION";
   }
   return "UNCLASSIFIED / NO TRADE";
}

color PhaseColor(int p)
{
   switch(p)
   {
      case PH_RANGE_DECLINE:   return clrYellow;
      case PH_MARKUP:          return clrLime;
      case PH_RANGE_ADVANCE:   return clrOrange;
      case PH_MARKDOWN:        return clrRed;
      case PH_BULL_TRANSITION: return clrAqua;
      case PH_BEAR_TRANSITION: return clrFuchsia;
   }
   return clrGray;
}

//=====================================================================
// Signal result for one closed bar
//=====================================================================
struct BarSignals
{
   bool buy, sell;
   bool buyCont, buyRev, buyRange;
   bool sellCont, sellRev, sellRange;
   bool earlyBull, earlyBear;
   bool bullSB, bearSB;
   bool failBull, failBear;
   double atr;
};

//+------------------------------------------------------------------+
//| Core engine: process one closed bar at shift s (s >= 1).         |
//| Must be called oldest -> newest, once per bar.                   |
//+------------------------------------------------------------------+
bool ProcessBar(int s, BarSignals &out)
{
   ZeroMemory(out);
   const int lb  = InpRangeLookback;
   const int pl  = InpPivotLen;

   // Need enough older bars for every lookback
   int need = MathMax(lb + 1, MathMax(2 * pl + 1, InpAtrLen + 1)) + 1;
   if(s + need >= iBars(_Symbol, _Period)) return false;

   g_barIndex++;

   //--- 3. Candle pressure proxies
   double o = O(s), h = H(s), l = L(s), c = C(s);
   double cRange   = h - l;
   double body     = MathAbs(c - o);
   double bodyRat  = cRange > 0 ? body / cRange : 0.0;

   bool bullP = (c > o && bodyRat >= InpMinBodyRatio);
   bool bearP = (c < o && bodyRat >= InpMinBodyRatio);
   bool bullOK = !InpUsePressureFilter || bullP;
   bool bearOK = !InpUsePressureFilter || bearP;

   //--- ATR (Wilder RMA, seeded with SMA like Pine)
   double tr = TrueRange(s);
   if(IsNa(g_atr))
   {
      double sum = 0;
      for(int i = 0; i < InpAtrLen; i++) sum += TrueRange(s + i);
      g_atr = sum / InpAtrLen;
   }
   else
      g_atr = (g_atr * (InpAtrLen - 1) + tr) / InpAtrLen;
   double atr = g_atr;

   //--- Directional efficiency
   double net   = MathAbs(c - C(s + lb));
   double total = 0;
   for(int i = 0; i < lb; i++) total += MathAbs(C(s + i) - C(s + i + 1));
   double eff = total > 0 ? net / total : 1.0;

   //--- 4. Confirmed market structure
   double ph = PivotHigh(s, pl);
   double pv = PivotLow(s, pl);
   if(!IsNa(ph)) { g_prevSwingHigh = g_lastSwingHigh; g_lastSwingHigh = ph; }
   if(!IsNa(pv)) { g_prevSwingLow  = g_lastSwingLow;  g_lastSwingLow  = pv; }

   bool haveHi = !IsNa(g_lastSwingHigh) && !IsNa(g_prevSwingHigh);
   bool haveLo = !IsNa(g_lastSwingLow)  && !IsNa(g_prevSwingLow);
   bool HH = haveHi && g_lastSwingHigh > g_prevSwingHigh;
   bool LH = haveHi && g_lastSwingHigh < g_prevSwingHigh;
   bool HL = haveLo && g_lastSwingLow  > g_prevSwingLow;
   bool LL = haveLo && g_lastSwingLow  < g_prevSwingLow;

   double c1 = C(s + 1);
   bool bullSB = !IsNa(g_lastSwingHigh) && c > g_lastSwingHigh && c1 <= g_lastSwingHigh;
   bool bearSB = !IsNa(g_lastSwingLow)  && c < g_lastSwingLow  && c1 >= g_lastSwingLow;

   //--- 5. Trading range (prior completed candles only)
   double rHi = -DBL_MAX, rLo = DBL_MAX;
   for(int i = 1; i <= lb; i++)
   {
      rHi = MathMax(rHi, H(s + i));
      rLo = MathMin(rLo, L(s + i));
   }
   double rWidth = rHi - rLo;
   bool compressed = (rWidth <= atr * InpRangeAtrMult) && (eff <= InpMaxEfficiency);
   double buf = atr * InpBreakoutBufferATR;

   bool bullRB = compressed && c > rHi + buf && c1 <= rHi + buf;
   bool bearRB = compressed && c < rLo - buf && c1 >= rLo - buf;

   //--- 6. Breakout failure detection
   bool failBull = false, failBear = false;
   if(g_activeBODir == 1 && g_activeBOBar >= 0 && g_barIndex > g_activeBOBar && c < g_activeBOLevel)
   {
      failBull = true;
      g_activeBODir = 0; g_activeBOLevel = EMPTY_VALUE; g_activeBOBar = -1;
   }
   else if(g_activeBODir == -1 && g_activeBOBar >= 0 && g_barIndex > g_activeBOBar && c > g_activeBOLevel)
   {
      failBear = true;
      g_activeBODir = 0; g_activeBOLevel = EMPTY_VALUE; g_activeBOBar = -1;
   }
   if(bullRB)      { g_activeBODir =  1; g_activeBOLevel = rHi; g_activeBOBar = g_barIndex; }
   else if(bearRB) { g_activeBODir = -1; g_activeBOLevel = rLo; g_activeBOBar = g_barIndex; }

   //--- 7. Phase classifier
   int  priorBias = g_trendBias;
   bool bullBreak = bullSB || (InpEnableRangeBreakouts && bullRB);
   bool bearBreak = bearSB || (InpEnableRangeBreakouts && bearRB);
   bool bullTrans = bullBreak && priorBias <= 0;
   bool bearTrans = bearBreak && priorBias >= 0;

   if(bullBreak)      g_trendBias =  1;
   else if(bearBreak) g_trendBias = -1;

   if(bullTrans)       g_marketPhase = PH_BULL_TRANSITION;
   else if(bearTrans)  g_marketPhase = PH_BEAR_TRANSITION;
   else if(compressed && !bullRB && !bearRB)
      g_marketPhase = (g_trendBias <= 0) ? PH_RANGE_DECLINE : PH_RANGE_ADVANCE;
   else if(g_trendBias ==  1) g_marketPhase = PH_MARKUP;
   else if(g_trendBias == -1) g_marketPhase = PH_MARKDOWN;
   else                       g_marketPhase = PH_UNCLASSIFIED;

   //--- 8. Early warnings
   bool earlyBull = g_trendBias <= 0 && bullP && c > H(s + 1) && !bullTrans;
   bool earlyBear = g_trendBias >= 0 && bearP && c < L(s + 1) && !bearTrans;

   //--- 9. Confirmed signals
   bool bullCont  = g_marketPhase == PH_MARKUP   && c > H(s + 1) && bullOK;
   bool bearCont  = g_marketPhase == PH_MARKDOWN && c < L(s + 1) && bearOK;
   bool bullRev   = bullTrans && bullOK;
   bool bearRev   = bearTrans && bearOK;
   bool bullRange = InpEnableRangeBreakouts && bullRB && bullOK;
   bool bearRange = InpEnableRangeBreakouts && bearRB && bearOK;

   bool rawBuy  = bullCont || bullRev || bullRange;
   bool rawSell = bearCont || bearRev || bearRange;

   if(g_marketPhase == PH_UNCLASSIFIED || g_marketPhase == PH_RANGE_DECLINE || g_marketPhase == PH_RANGE_ADVANCE)
      g_lastSignalDir = 0;

   bool buy = false, sell = false;
   if(rawBuy && g_lastSignalDir != 1)        { buy  = true; g_lastSignalDir =  1; }
   else if(rawSell && g_lastSignalDir != -1) { sell = true; g_lastSignalDir = -1; }

   //--- store for dashboard
   g_bullishStructure = HH && HL;
   g_bearishStructure = LH && LL;
   g_bullPressure     = bullP;
   g_bearPressure     = bearP;
   g_compressedRange  = compressed;
   g_efficiency       = eff;

   out.buy = buy; out.sell = sell;
   out.buyCont = bullCont; out.buyRev = bullRev; out.buyRange = bullRange;
   out.sellCont = bearCont; out.sellRev = bearRev; out.sellRange = bearRange;
   out.earlyBull = earlyBull; out.earlyBear = earlyBear;
   out.bullSB = bullSB; out.bearSB = bearSB;
   out.failBull = failBull; out.failBear = failBear;
   out.atr = atr;
   return true;
}

//=====================================================================
// 11/12. CHART MARKERS
//=====================================================================
void DrawArrow(string tag, datetime t, double price, int code, color clr, int anchor, string tip)
{
   string name = PFX + tag + "_" + IntegerToString((long)t);
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_ARROW, 0, t, price);
   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
}

// Muted version of the phase colour, so candles stay readable on top of it
color MutedColor(color clr)
{
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int r = ((clr & 0xFF) + 5 * (bg & 0xFF)) / 6;
   int g = (((clr >> 8) & 0xFF) + 5 * ((bg >> 8) & 0xFF)) / 6;
   int b = (((clr >> 16) & 0xFF) + 5 * ((bg >> 16) & 0xFF)) / 6;
   return (color)(r | (g << 8) | (b << 16));
}

void DrawPhaseBackground(int s)
{
   datetime t0 = T(s);
   datetime t1 = t0 + PeriodSeconds(_Period);
   string name = PFX + "BG_" + IntegerToString((long)t0);
   if(ObjectFind(0, name) >= 0) return;
   double top = 1.0e7;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, 0.0, t1, top);
   ObjectSetInteger(0, name, OBJPROP_COLOR, MutedColor(PhaseColor(g_marketPhase)));
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

void DrawMarkers(int s, const BarSignals &sg)
{
   datetime t = T(s);
   double off = sg.atr * 0.3;
   if(InpShowConfirmedSignals && sg.buy)
      DrawArrow("BUY", t, L(s) - off, 233, clrLime, ANCHOR_TOP, "Confirmed BUY");
   if(InpShowConfirmedSignals && sg.sell)
      DrawArrow("SELL", t, H(s) + off, 234, clrRed, ANCHOR_BOTTOM, "Confirmed SELL");
   if(InpShowEarlyWarnings && sg.earlyBull && !sg.buy)
      DrawArrow("EWB", t, L(s) - off * 2, 217, clrAqua, ANCHOR_TOP, "Early bullish warning");
   if(InpShowEarlyWarnings && sg.earlyBear && !sg.sell)
      DrawArrow("EWS", t, H(s) + off * 2, 218, clrOrange, ANCHOR_BOTTOM, "Early bearish warning");
   if(InpShowSwingBreaks && sg.bullSB)
      DrawArrow("SBB", t, L(s) - off * 3, 159, clrLime, ANCHOR_TOP, "Bullish structural break");
   if(InpShowSwingBreaks && sg.bearSB)
      DrawArrow("SBS", t, H(s) + off * 3, 159, clrRed, ANCHOR_BOTTOM, "Bearish structural break");
   if(InpShowFailedBreakouts && sg.failBull)
      DrawArrow("FBB", t, H(s) + off * 4, 251, clrOrange, ANCHOR_BOTTOM, "Failed bullish breakout");
   if(InpShowFailedBreakouts && sg.failBear)
      DrawArrow("FBS", t, L(s) - off * 4, 251, clrOrange, ANCHOR_TOP, "Failed bearish breakout");
   if(InpShowPhaseBackground)
      DrawPhaseBackground(s);
}

//=====================================================================
// 13. DASHBOARD
//=====================================================================
void DashCell(int row, int col, string text, color bg, color fg)
{
   const int x0 = 10, colW0 = 150, colW1 = 190, rowH = 20, y0 = 20;
   int w = (col == 0) ? colW0 : colW1;
   int x = (col == 0) ? x0 + colW1 + 2 : x0;   // measured from right corner
   int y = y0 + row * (rowH + 1);

   string bgName = PFX + "D_BG_" + IntegerToString(row) + "_" + IntegerToString(col);
   string txName = PFX + "D_TX_" + IntegerToString(row) + "_" + IntegerToString(col);
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, x + w);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, rowH);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR, clrBlack);

   if(ObjectFind(0, txName) < 0)
   {
      ObjectCreate(0, txName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, txName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, txName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, txName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, txName, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, txName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, txName, OBJPROP_HIDDEN, true);
   }
   ObjectSetInteger(0, txName, OBJPROP_XDISTANCE, x + w - 5);
   ObjectSetInteger(0, txName, OBJPROP_YDISTANCE, y + 4);
   ObjectSetInteger(0, txName, OBJPROP_COLOR, fg);
   ObjectSetString(0, txName, OBJPROP_TEXT, text);
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;
   color lbl = C'60,60,60';
   color val = C'85,85,85';

   string structTxt = g_bullishStructure ? "HH + HL" : g_bearishStructure ? "LH + LL" : "MIXED / UNKNOWN";
   string pressTxt  = g_bullPressure ? "BUYING PROXY" : g_bearPressure ? "SELLING PROXY" : "WEAK / MIXED";
   string biasTxt   = g_trendBias == 1 ? "BULLISH" : g_trendBias == -1 ? "BEARISH" : "NEUTRAL";
   string rangeTxt  = g_compressedRange ? "RANGE DETECTED" : "NO RANGE";

   DashCell(0, 0, "MARKET PHASE", clrBlack, clrWhite);
   DashCell(0, 1, _Symbol + " " + StringSubstr(EnumToString(_Period), 7), clrBlack, clrWhite);
   DashCell(1, 0, "Current State", lbl, clrWhite);
   DashCell(1, 1, PhaseName(g_marketPhase), PhaseColor(g_marketPhase), clrBlack);
   DashCell(2, 0, "Trend Bias", lbl, clrWhite);
   DashCell(2, 1, biasTxt, g_trendBias == 1 ? clrGreen : g_trendBias == -1 ? clrRed : clrGray, clrWhite);
   DashCell(3, 0, "Structure", lbl, clrWhite);
   DashCell(3, 1, structTxt, val, clrWhite);
   DashCell(4, 0, "Candle Pressure", lbl, clrWhite);
   DashCell(4, 1, pressTxt, g_bullPressure ? clrGreen : g_bearPressure ? clrRed : clrGray, clrWhite);
   DashCell(5, 0, "Range Status", lbl, clrWhite);
   DashCell(5, 1, rangeTxt, g_compressedRange ? clrOrange : val, clrBlack);
   DashCell(6, 0, "Directional Efficiency", lbl, clrWhite);
   DashCell(6, 1, DoubleToString(g_efficiency, 2), val, clrWhite);
}

//=====================================================================
// TRADING LAYER
//=====================================================================
int CurrentPositionDir(ulong &ticket)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      ticket = tk;
      return PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1;
   }
   return 0;
}

void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!g_trade.PositionClose(tk))
         PrintFormat("Close failed #%I64u: %d %s", tk, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}

double NormalizeLots(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step) * step;
   lots = MathMax(vmin, MathMin(vmax, lots));
   return NormalizeDouble(lots, 8);
}

double CalcLots(double slDistance)
{
   if(!InpUseRiskPercent || slDistance <= 0) return NormalizeLots(InpFixedLots);
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickVal <= 0) tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal <= 0 || tickSize <= 0) return NormalizeLots(InpFixedLots);
   double riskMoney   = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lossPerLot  = slDistance / tickSize * tickVal;
   if(lossPerLot <= 0) return NormalizeLots(InpFixedLots);
   return NormalizeLots(riskMoney / lossPerLot);
}

bool EntryFiltersOK()
{
   if(InpMaxSpreadPoints > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints) { PrintFormat("Entry skipped: spread %d > %d", spread, InpMaxSpreadPoints); return false; }
   }
   if(InpUseSession)
   {
      MqlDateTime dt; TimeCurrent(dt);
      bool in = (InpSessionStartHour <= InpSessionEndHour)
                ? (dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour)
                : (dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
      if(!in) return false;
   }
   return true;
}

void OpenTrade(int dir, double atr, string why)
{
   if(!EntryFiltersOK()) return;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   double slDist = MathMax(atr * InpSL_ATR, stopsLvl + 2 * _Point);
   double price  = dir == 1 ? ask : bid;
   double sl     = dir == 1 ? price - slDist : price + slDist;
   double tp     = 0;
   if(InpTP_R > 0) tp = dir == 1 ? price + slDist * InpTP_R : price - slDist * InpTP_R;
   sl = NormalizeDouble(sl, digits);
   tp = tp > 0 ? NormalizeDouble(tp, digits) : 0;

   double lots = CalcLots(slDist);
   bool ok = dir == 1 ? g_trade.Buy(lots, _Symbol, 0, sl, tp, "MP " + why)
                      : g_trade.Sell(lots, _Symbol, 0, sl, tp, "MP " + why);
   if(!ok)
      PrintFormat("Order failed: %d %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

void HandleTrading(const BarSignals &sg)
{
   if(!InpEnableTrading) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   ulong tk;
   int pos = CurrentPositionDir(tk);

   // Exit on failed breakout against the position
   if(InpCloseOnFailedBO && pos != 0)
   {
      if((pos == 1 && sg.failBull) || (pos == -1 && sg.failBear))
      {
         CloseAll();
         pos = CurrentPositionDir(tk);
      }
   }

   bool buyOK  = sg.buy  && ((InpTradeContinuation && sg.buyCont)  || (InpTradeReversal && sg.buyRev)  || (InpTradeRangeBreakout && sg.buyRange));
   bool sellOK = sg.sell && ((InpTradeContinuation && sg.sellCont) || (InpTradeReversal && sg.sellRev) || (InpTradeRangeBreakout && sg.sellRange));

   // Opposite signal handling (uses any confirmed signal, even if its type isn't traded)
   if(pos == 1 && sg.sell && InpCloseOnOpposite)  { CloseAll(); pos = CurrentPositionDir(tk); if(!InpReverseOnOpposite) sellOK = false; }
   if(pos == -1 && sg.buy && InpCloseOnOpposite)  { CloseAll(); pos = CurrentPositionDir(tk); if(!InpReverseOnOpposite) buyOK  = false; }

   if(pos != 0) return; // one position at a time

   string why;
   if(buyOK)
   {
      why = sg.buyRev ? "REV" : sg.buyRange ? "RANGE" : "CONT";
      OpenTrade(1, sg.atr, why);
   }
   else if(sellOK)
   {
      why = sg.sellRev ? "REV" : sg.sellRange ? "RANGE" : "CONT";
      OpenTrade(-1, sg.atr, why);
   }
}

void FireAlerts(const BarSignals &sg)
{
   if(!InpAlerts) return;
   string tf = StringSubstr(EnumToString(_Period), 7);
   if(sg.buy)       Alert("Confirmed BUY signal on ", _Symbol, " ", tf);
   if(sg.sell)      Alert("Confirmed SELL signal on ", _Symbol, " ", tf);
   if(sg.earlyBull) Alert("Early bullish warning on ", _Symbol, " ", tf);
   if(sg.earlyBear) Alert("Early bearish warning on ", _Symbol, " ", tf);
   if(sg.failBull)  Alert("Potential failed bullish breakout on ", _Symbol, " ", tf);
   if(sg.failBear)  Alert("Potential failed bearish breakout on ", _Symbol, " ", tf);
}

//=====================================================================
// STATE RESET / WARMUP
//=====================================================================
void ResetState()
{
   g_lastSwingHigh = g_prevSwingHigh = g_lastSwingLow = g_prevSwingLow = EMPTY_VALUE;
   g_activeBOLevel = EMPTY_VALUE; g_activeBODir = 0; g_activeBOBar = -1;
   g_trendBias = 0; g_marketPhase = PH_UNCLASSIFIED; g_lastSignalDir = 0;
   g_atr = EMPTY_VALUE; g_barIndex = 0; g_lastProcessed = 0;
}

bool Warmup()
{
   ResetState();
   int bars = iBars(_Symbol, _Period);
   int need = MathMax(InpRangeLookback + 1, MathMax(2 * InpPivotLen + 1, InpAtrLen + 1)) + 2;
   if(bars < need + 2) return false;

   int start = MathMin(InpWarmupBars, bars - need - 1);
   if(start < 1) return false;

   bool draw = !MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE);
   BarSignals sg;
   for(int s = start; s >= 1; s--)
   {
      if(ProcessBar(s, sg) && draw) DrawMarkers(s, sg);
   }
   g_lastProcessed = T(1);
   UpdateDashboard();
   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPivotLen < 1 || InpRangeLookback < 5 || InpAtrLen < 1)
   {
      Print("Invalid inputs");
      return INIT_PARAMETERS_INCORRECT;
   }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(_Period != PERIOD_M1 || StringFind(_Symbol, "XAU") < 0)
      Print("Note: logic was designed for XAUUSD M1; running on ", _Symbol, " ", EnumToString(_Period));

   Warmup(); // if history isn't ready yet, OnTick retries
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Tick: process only newly closed candles                          |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime closedTime = T(1);
   if(closedTime == 0) return;

   if(g_lastProcessed == 0)
   {
      if(!Warmup()) return;
      return; // state built; do not trade on historical bars
   }
   if(closedTime == g_lastProcessed) return;

   // Process every bar that closed since the last one handled (handles gaps / reconnects)
   int lastShift = iBarShift(_Symbol, _Period, g_lastProcessed, true);
   if(lastShift < 0)
   {
      // History changed (e.g. reload) - rebuild state from scratch
      Warmup();
      return;
   }

   bool draw = !MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE);
   BarSignals sg;
   for(int s = lastShift - 1; s >= 1; s--)
   {
      if(!ProcessBar(s, sg)) continue;
      if(draw) DrawMarkers(s, sg);
      if(s == 1)            // act only on the freshest closed bar
      {
         FireAlerts(sg);
         HandleTrading(sg);
      }
   }
   g_lastProcessed = closedTime;
   UpdateDashboard();
   if(draw) ChartRedraw();
}
//+------------------------------------------------------------------+
