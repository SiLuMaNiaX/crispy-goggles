//+------------------------------------------------------------------+
//|                                     XAUUSD_M1_MarketPhases.mq5   |
//|  MT5 indicator port of the TradingView indicator                  |
//|  "XAUUSD M1 - Economics + Structure + Market Phases" (Pine v6).   |
//|                                                                  |
//|  Everything is evaluated on CLOSED candles only (Pine             |
//|  barstate.isconfirmed). The forming candle is left empty.         |
//|  Arrays are oldest-first: index i-k here is Pine [k].             |
//|                                                                  |
//|  Buffers (readable with iCustom / CopyBuffer, see README):        |
//|   0 BUY            1 SELL           2 Early bull   3 Early bear   |
//|   4 Bull struct    5 Bear struct    6 Fail bull    7 Fail bear    |
//|   8 Phase (0..6)   9 Trend bias    10 Signal type (bitmask, +/-)  |
//|  11 ATR (RMA)     12 Efficiency    13 Range flag  14 Structure    |
//|  15 Pressure                                                      |
//+------------------------------------------------------------------+
#property copyright "Port of Pine indicator - use at your own risk"
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 16
#property indicator_plots   16

#property indicator_label1  "Confirmed BUY"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrLime
#property indicator_width1  2
#property indicator_label2  "Confirmed SELL"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  2
#property indicator_label3  "Early Bullish Warning"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrAqua
#property indicator_label4  "Early Bearish Warning"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrOrange
#property indicator_label5  "Bullish Structural Break"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrLime
#property indicator_label6  "Bearish Structural Break"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrRed
#property indicator_label7  "Failed Bullish Breakout"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrOrange
#property indicator_label8  "Failed Bearish Breakout"
#property indicator_type8   DRAW_ARROW
#property indicator_color8  clrOrange
#property indicator_label9  "Phase"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "Trend Bias"
#property indicator_type10  DRAW_NONE
#property indicator_label11 "Signal Type"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "ATR"
#property indicator_type12  DRAW_NONE
#property indicator_label13 "Directional Efficiency"
#property indicator_type13  DRAW_NONE
#property indicator_label14 "Range Detected"
#property indicator_type14  DRAW_NONE
#property indicator_label15 "Structure"
#property indicator_type15  DRAW_NONE
#property indicator_label16 "Candle Pressure"
#property indicator_type16  DRAW_NONE

//=====================================================================
// 1. INPUTS (same order as the Pine script; the EA passes them in
//    this exact order through iCustom - keep both files in sync)
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

input group "4. Signals"
input bool   InpShowEarlyWarnings   = true;  // Show Early Reversal Warnings
input bool   InpShowConfirmedSignals= true;  // Show Confirmed BUY / SELL Signals
input bool   InpShowFailedBreakouts = true;  // Show Failed Breakout Markers
input bool   InpShowDashboard       = true;  // Show Market Phase Dashboard
input bool   InpShowPhaseBackground = false; // Tint Background by Market Phase
input bool   InpAlerts              = false; // Pop-up alerts (alertcondition)
input int    InpMaxBars             = 5000;  // Bars of history to calculate (0 = all)

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

// Signal type bitmask (buffer 10): positive = BUY, negative = SELL
#define SIG_CONT   1
#define SIG_REV    2
#define SIG_RANGE  4

#define PFX "MPIND_"

//=====================================================================
// BUFFERS
//=====================================================================
double BufBuy[], BufSell[], BufEarlyBull[], BufEarlyBear[];
double BufBullSB[], BufBearSB[], BufFailBull[], BufFailBear[];
double BufPhase[], BufBias[], BufSigType[], BufAtr[];
double BufEff[], BufRange[], BufStruct[], BufPressure[];

//=====================================================================
// PERSISTENT STATE (Pine `var` variables)
//=====================================================================
double g_lastSwingHigh, g_prevSwingHigh, g_lastSwingLow, g_prevSwingLow;
double g_activeBOLevel;
int    g_activeBODir;
int    g_activeBOBar;
int    g_trendBias;
int    g_marketPhase;
int    g_lastSignalDir;
double g_atr;
int    g_next;          // next bar index to process

bool   g_bullStructure, g_bearStructure, g_bullPressure, g_bearPressure, g_compressed;
double g_efficiency;

bool   g_drawObjects;

//+------------------------------------------------------------------+
bool IsNa(const double v) { return v == EMPTY_VALUE; }

void ResetState()
{
   g_lastSwingHigh = g_prevSwingHigh = g_lastSwingLow = g_prevSwingLow = EMPTY_VALUE;
   g_activeBOLevel = EMPTY_VALUE; g_activeBODir = 0; g_activeBOBar = -1;
   g_trendBias = 0; g_marketPhase = PH_UNCLASSIFIED; g_lastSignalDir = 0;
   g_atr = EMPTY_VALUE;
   g_bullStructure = g_bearStructure = g_bullPressure = g_bearPressure = g_compressed = false;
   g_efficiency = 0.0;
}

int FirstIndex()
{
   // Oldest index with enough history for every lookback
   return MathMax(InpRangeLookback, MathMax(2 * InpPivotLen, InpAtrLen)) + 1;
}

void SetupArrowPlot(int plot, int code, int shift, bool visible)
{
   PlotIndexSetInteger(plot, PLOT_DRAW_TYPE, visible ? DRAW_ARROW : DRAW_NONE);
   PlotIndexSetInteger(plot, PLOT_ARROW, code);
   PlotIndexSetInteger(plot, PLOT_ARROW_SHIFT, shift);
   PlotIndexSetDouble(plot, PLOT_EMPTY_VALUE, EMPTY_VALUE);
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPivotLen < 1 || InpRangeLookback < 5 || InpAtrLen < 1)
      return INIT_PARAMETERS_INCORRECT;

   SetIndexBuffer(0,  BufBuy,       INDICATOR_DATA);
   SetIndexBuffer(1,  BufSell,      INDICATOR_DATA);
   SetIndexBuffer(2,  BufEarlyBull, INDICATOR_DATA);
   SetIndexBuffer(3,  BufEarlyBear, INDICATOR_DATA);
   SetIndexBuffer(4,  BufBullSB,    INDICATOR_DATA);
   SetIndexBuffer(5,  BufBearSB,    INDICATOR_DATA);
   SetIndexBuffer(6,  BufFailBull,  INDICATOR_DATA);
   SetIndexBuffer(7,  BufFailBear,  INDICATOR_DATA);
   SetIndexBuffer(8,  BufPhase,     INDICATOR_DATA);
   SetIndexBuffer(9,  BufBias,      INDICATOR_DATA);
   SetIndexBuffer(10, BufSigType,   INDICATOR_DATA);
   SetIndexBuffer(11, BufAtr,       INDICATOR_DATA);
   SetIndexBuffer(12, BufEff,       INDICATOR_DATA);
   SetIndexBuffer(13, BufRange,     INDICATOR_DATA);
   SetIndexBuffer(14, BufStruct,    INDICATOR_DATA);
   SetIndexBuffer(15, BufPressure,  INDICATOR_DATA);

   // Arrow plots: hidden plots still hold data, so the EA can always read them.
   // Positive shift = below the price, negative = above (pixels).
   SetupArrowPlot(0, 233,  20, InpShowConfirmedSignals);  // BUY below low
   SetupArrowPlot(1, 234, -20, InpShowConfirmedSignals);  // SELL above high
   SetupArrowPlot(2, 217,  38, InpShowEarlyWarnings);
   SetupArrowPlot(3, 218, -38, InpShowEarlyWarnings);
   SetupArrowPlot(4, 159,  52, InpShowSwingBreaks);
   SetupArrowPlot(5, 159, -52, InpShowSwingBreaks);
   SetupArrowPlot(6, 251, -66, InpShowFailedBreakouts);    // Pine: abovebar
   SetupArrowPlot(7, 251,  66, InpShowFailedBreakouts);    // Pine: belowbar
   for(int p = 8; p < 16; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetString(INDICATOR_SHORTNAME, "MarketPhases");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_drawObjects = !MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE);
   ResetState();
   g_next = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void ClearBar(int i)
{
   BufBuy[i] = BufSell[i] = BufEarlyBull[i] = BufEarlyBear[i] = EMPTY_VALUE;
   BufBullSB[i] = BufBearSB[i] = BufFailBull[i] = BufFailBear[i] = EMPTY_VALUE;
   BufPhase[i] = BufBias[i] = BufSigType[i] = BufAtr[i] = EMPTY_VALUE;
   BufEff[i] = BufRange[i] = BufStruct[i] = BufPressure[i] = EMPTY_VALUE;
}

double TrueRange(int i, const double &high[], const double &low[], const double &close[])
{
   double pc = close[i - 1];
   return MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - pc), MathAbs(low[i] - pc)));
}

// Pine ta.pivothigh(high, n, n) evaluated at bar i -> pivot candle is i-n.
double PivotHigh(int i, int n, const double &high[])
{
   int c = i - n;
   double v = high[c];
   for(int k = 1; k <= n; k++)
   {
      if(high[c - k] >= v) return EMPTY_VALUE;  // left (older): strictly higher
      if(high[c + k] >  v) return EMPTY_VALUE;  // right (newer): not exceeded
   }
   return v;
}

double PivotLow(int i, int n, const double &low[])
{
   int c = i - n;
   double v = low[c];
   for(int k = 1; k <= n; k++)
   {
      if(low[c - k] <= v) return EMPTY_VALUE;
      if(low[c + k] <  v) return EMPTY_VALUE;
   }
   return v;
}

//+------------------------------------------------------------------+
//| Core engine: one closed bar, called oldest -> newest             |
//+------------------------------------------------------------------+
void ProcessBar(int i, const double &open[], const double &high[],
                const double &low[], const double &close[])
{
   const int lb = InpRangeLookback;
   const int pl = InpPivotLen;

   //--- 3. Candle pressure
   double o = open[i], h = high[i], l = low[i], c = close[i];
   double cRange  = h - l;
   double bodyRat = cRange > 0 ? MathAbs(c - o) / cRange : 0.0;
   bool bullP  = (c > o && bodyRat >= InpMinBodyRatio);
   bool bearP  = (c < o && bodyRat >= InpMinBodyRatio);
   bool bullOK = !InpUsePressureFilter || bullP;
   bool bearOK = !InpUsePressureFilter || bearP;

   //--- ATR: Wilder RMA seeded with an SMA (Pine ta.atr)
   if(IsNa(g_atr))
   {
      double sum = 0;
      for(int k = 0; k < InpAtrLen; k++) sum += TrueRange(i - k, high, low, close);
      g_atr = sum / InpAtrLen;
   }
   else
      g_atr = (g_atr * (InpAtrLen - 1) + TrueRange(i, high, low, close)) / InpAtrLen;
   double atr = g_atr;

   //--- Directional efficiency
   double net = MathAbs(c - close[i - lb]);
   double total = 0;
   for(int k = 0; k < lb; k++) total += MathAbs(close[i - k] - close[i - k - 1]);
   double eff = total > 0 ? net / total : 1.0;

   //--- 4. Confirmed market structure
   double ph = PivotHigh(i, pl, high);
   double pv = PivotLow(i, pl, low);
   if(!IsNa(ph)) { g_prevSwingHigh = g_lastSwingHigh; g_lastSwingHigh = ph; }
   if(!IsNa(pv)) { g_prevSwingLow  = g_lastSwingLow;  g_lastSwingLow  = pv; }

   bool haveHi = !IsNa(g_lastSwingHigh) && !IsNa(g_prevSwingHigh);
   bool haveLo = !IsNa(g_lastSwingLow)  && !IsNa(g_prevSwingLow);
   bool HH = haveHi && g_lastSwingHigh > g_prevSwingHigh;
   bool LH = haveHi && g_lastSwingHigh < g_prevSwingHigh;
   bool HL = haveLo && g_lastSwingLow  > g_prevSwingLow;
   bool LL = haveLo && g_lastSwingLow  < g_prevSwingLow;

   double c1 = close[i - 1];
   bool bullSB = !IsNa(g_lastSwingHigh) && c > g_lastSwingHigh && c1 <= g_lastSwingHigh;
   bool bearSB = !IsNa(g_lastSwingLow)  && c < g_lastSwingLow  && c1 >= g_lastSwingLow;

   //--- 5. Trading range from prior completed candles
   double rHi = -DBL_MAX, rLo = DBL_MAX;
   for(int k = 1; k <= lb; k++)
   {
      rHi = MathMax(rHi, high[i - k]);
      rLo = MathMin(rLo, low[i - k]);
   }
   bool compressed = (rHi - rLo <= atr * InpRangeAtrMult) && (eff <= InpMaxEfficiency);
   double buf = atr * InpBreakoutBufferATR;
   bool bullRB = compressed && c > rHi + buf && c1 <= rHi + buf;
   bool bearRB = compressed && c < rLo - buf && c1 >= rLo - buf;

   //--- 6. Breakout failure detection
   bool failBull = false, failBear = false;
   if(g_activeBODir == 1 && g_activeBOBar >= 0 && i > g_activeBOBar && c < g_activeBOLevel)
   {
      failBull = true;
      g_activeBODir = 0; g_activeBOLevel = EMPTY_VALUE; g_activeBOBar = -1;
   }
   else if(g_activeBODir == -1 && g_activeBOBar >= 0 && i > g_activeBOBar && c > g_activeBOLevel)
   {
      failBear = true;
      g_activeBODir = 0; g_activeBOLevel = EMPTY_VALUE; g_activeBOBar = -1;
   }
   if(bullRB)      { g_activeBODir =  1; g_activeBOLevel = rHi; g_activeBOBar = i; }
   else if(bearRB) { g_activeBODir = -1; g_activeBOLevel = rLo; g_activeBOBar = i; }

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
   bool earlyBull = g_trendBias <= 0 && bullP && c > high[i - 1] && !bullTrans;
   bool earlyBear = g_trendBias >= 0 && bearP && c < low[i - 1]  && !bearTrans;

   //--- 9. Confirmed signals
   bool bullCont  = g_marketPhase == PH_MARKUP   && c > high[i - 1] && bullOK;
   bool bearCont  = g_marketPhase == PH_MARKDOWN && c < low[i - 1]  && bearOK;
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

   int sigType = 0;
   if(buy)  sigType =  ((bullCont ? SIG_CONT : 0) | (bullRev ? SIG_REV : 0) | (bullRange ? SIG_RANGE : 0));
   if(sell) sigType = -((bearCont ? SIG_CONT : 0) | (bearRev ? SIG_REV : 0) | (bearRange ? SIG_RANGE : 0));

   //--- write buffers
   BufBuy[i]       = buy  ? l : EMPTY_VALUE;
   BufSell[i]      = sell ? h : EMPTY_VALUE;
   BufEarlyBull[i] = (earlyBull && !buy)  ? l : EMPTY_VALUE;
   BufEarlyBear[i] = (earlyBear && !sell) ? h : EMPTY_VALUE;
   BufBullSB[i]    = bullSB   ? l : EMPTY_VALUE;
   BufBearSB[i]    = bearSB   ? h : EMPTY_VALUE;
   BufFailBull[i]  = failBull ? h : EMPTY_VALUE;
   BufFailBear[i]  = failBear ? l : EMPTY_VALUE;
   BufPhase[i]     = g_marketPhase;
   BufBias[i]      = g_trendBias;
   BufSigType[i]   = sigType;
   BufAtr[i]       = atr;
   BufEff[i]       = eff;
   BufRange[i]     = compressed ? 1 : 0;
   BufStruct[i]    = (HH && HL) ? 1 : (LH && LL) ? -1 : 0;
   BufPressure[i]  = bullP ? 1 : bearP ? -1 : 0;

   g_bullStructure = HH && HL;
   g_bearStructure = LH && LL;
   g_bullPressure  = bullP;
   g_bearPressure  = bearP;
   g_compressed    = compressed;
   g_efficiency    = eff;
}

//=====================================================================
// 10/12. PHASE NAMES, COLOURS, BACKGROUND
//=====================================================================
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

// Muted version of the phase colour, so candles stay readable on top of it
color MutedColor(color clr)
{
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   int r = ((clr & 0xFF) + 5 * (bg & 0xFF)) / 6;
   int g = (((clr >> 8) & 0xFF) + 5 * ((bg >> 8) & 0xFF)) / 6;
   int b = (((clr >> 16) & 0xFF) + 5 * ((bg >> 16) & 0xFF)) / 6;
   return (color)(r | (g << 8) | (b << 16));
}

void DrawPhaseBackground(int i, const datetime &time[])
{
   datetime t0 = time[i];
   string name = PFX + "BG_" + IntegerToString((long)t0);
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t0, 0.0, t0 + PeriodSeconds(_Period), 1.0e7);
   ObjectSetInteger(0, name, OBJPROP_COLOR, MutedColor(PhaseColor((int)BufPhase[i])));
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//=====================================================================
// 13. DASHBOARD
//=====================================================================
void DashCell(int row, int col, string text, color bg, color fg)
{
   const int x0 = 10, colW0 = 150, colW1 = 190, rowH = 20, y0 = 20;
   int w = (col == 0) ? colW0 : colW1;
   int x = (col == 0) ? x0 + colW1 + 2 : x0;      // distance from the right edge
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
   if(!InpShowDashboard || !g_drawObjects) return;
   color lbl = C'60,60,60';
   color val = C'85,85,85';

   string structTxt = g_bullStructure ? "HH + HL" : g_bearStructure ? "LH + LL" : "MIXED / UNKNOWN";
   string pressTxt  = g_bullPressure ? "BUYING PROXY" : g_bearPressure ? "SELLING PROXY" : "WEAK / MIXED";
   string biasTxt   = g_trendBias == 1 ? "BULLISH" : g_trendBias == -1 ? "BEARISH" : "NEUTRAL";
   string rangeTxt  = g_compressed ? "RANGE DETECTED" : "NO RANGE";

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
   DashCell(5, 1, rangeTxt, g_compressed ? clrOrange : val, clrBlack);
   DashCell(6, 0, "Directional Efficiency", lbl, clrWhite);
   DashCell(6, 1, DoubleToString(g_efficiency, 2), val, clrWhite);
}

//=====================================================================
// 14. ALERTS
//=====================================================================
void FireAlerts(int i)
{
   if(!InpAlerts) return;
   string tf = StringSubstr(EnumToString(_Period), 7);
   if(!IsNa(BufBuy[i]))       Alert("Confirmed BUY signal on ", _Symbol, " ", tf);
   if(!IsNa(BufSell[i]))      Alert("Confirmed SELL signal on ", _Symbol, " ", tf);
   if(!IsNa(BufEarlyBull[i])) Alert("Early bullish warning on ", _Symbol, " ", tf);
   if(!IsNa(BufEarlyBear[i])) Alert("Early bearish warning on ", _Symbol, " ", tf);
   if(!IsNa(BufFailBull[i]))  Alert("Potential failed bullish breakout on ", _Symbol, " ", tf);
   if(!IsNa(BufFailBear[i]))  Alert("Potential failed bearish breakout on ", _Symbol, " ", tf);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   int first = FirstIndex();
   if(rates_total < first + 2) return 0;

   bool live = prev_calculated > 0;
   if(!live)
   {
      // Full (re)calculation: history loaded, inputs changed or chart refreshed
      ObjectsDeleteAll(0, PFX + "BG_");
      ResetState();
      for(int i = 0; i < rates_total; i++) ClearBar(i);
      g_next = first;
      if(InpMaxBars > 0) g_next = MathMax(first, rates_total - 1 - InpMaxBars);
   }
   else
   {
      // Newly appended bars (including the forming one) start empty
      for(int i = prev_calculated - 1; i < rates_total; i++)
         if(i >= g_next) ClearBar(i);
   }

   // Process every closed bar not yet handled; the last index is still forming
   bool processedAny = false;
   while(g_next <= rates_total - 2)
   {
      int i = g_next;
      ProcessBar(i, open, high, low, close);
      if(InpShowPhaseBackground && g_drawObjects) DrawPhaseBackground(i, time);
      if(live && i == rates_total - 2) FireAlerts(i);
      g_next++;
      processedAny = true;
   }

   if(processedAny || !live) UpdateDashboard();
   return rates_total;
}
//+------------------------------------------------------------------+
