//+------------------------------------------------------------------+
//|                                               HighwayMatrix.mq5  |
//|  MQL5 port of highway_matrix.pine — a clean-room rebuild of the  |
//|  "UC Highway Matrix" look seen in the Ultimate CEO Highway video.|
//|  See README.md for the analysis and caveats.                     |
//+------------------------------------------------------------------+
#property copyright   "Highway Matrix rebuild"
#property version     "1.00"
#property description "Kernel envelope sell/buy zones, HTF stepped highway, H-Buy/H-Sell signals,"
#property description "next-zone box, echo forecast and trend dashboard."
#property description "Repainting mode reproduces the video look but redraws history — do not trade it."
#property indicator_chart_window
#property indicator_buffers 21
#property indicator_plots   13

//--- 0: sell zone fill
#property indicator_label1  "Sell zone"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  C'70,20,32',C'70,20,32'
//--- 1: buy zone fill
#property indicator_label2  "Buy zone"
#property indicator_type2   DRAW_FILLING
#property indicator_color2  C'14,58,60',C'14,58,60'
//--- 2: highway fill
#property indicator_label3  "Highway"
#property indicator_type3   DRAW_FILLING
#property indicator_color3  C'38,40,50',C'38,40,50'
//--- 3..6: band lines
#property indicator_label4  "Upper outer"
#property indicator_type4   DRAW_LINE
#property indicator_color4  C'38,194,129'
#property indicator_width4  2
#property indicator_label5  "Upper inner"
#property indicator_type5   DRAW_LINE
#property indicator_color5  C'176,176,176'
#property indicator_width5  1
#property indicator_label6  "Lower inner"
#property indicator_type6   DRAW_LINE
#property indicator_color6  C'176,176,176'
#property indicator_width6  1
#property indicator_label7  "Lower outer"
#property indicator_type7   DRAW_LINE
#property indicator_color7  C'38,194,129'
#property indicator_width7  2
//--- 7..8: highway lines
#property indicator_label8  "Highway upper"
#property indicator_type8   DRAW_LINE
#property indicator_color8  C'61,139,253'
#property indicator_width8  1
#property indicator_label9  "Highway lower"
#property indicator_type9   DRAW_LINE
#property indicator_color9  C'61,139,253'
#property indicator_width9  1
//--- 9..12: signal arrows
#property indicator_label10 "H-Sell"
#property indicator_type10  DRAW_ARROW
#property indicator_color10 C'229,57,80'
#property indicator_width10 2
#property indicator_label11 "Sell (counter)"
#property indicator_type11  DRAW_ARROW
#property indicator_color11 C'160,70,85'
#property indicator_width11 1
#property indicator_label12 "H-Buy"
#property indicator_type12  DRAW_ARROW
#property indicator_color12 C'34,181,115'
#property indicator_width12 2
#property indicator_label13 "Buy (counter)"
#property indicator_type13  DRAW_ARROW
#property indicator_color13 C'60,140,105'
#property indicator_width13 1

//+------------------------------------------------------------------+
enum ENUM_HWM_MODE  { HWM_NON_REPAINTING = 0, // Non-repainting
                      HWM_REPAINTING     = 1  // Repainting (video look)
                    };
enum ENUM_DASH_POS  { DP_TOP_RIGHT, DP_MIDDLE_RIGHT, DP_BOTTOM_RIGHT,
                      DP_TOP_LEFT,  DP_MIDDLE_LEFT,  DP_BOTTOM_LEFT };
enum ENUM_DASH_SIZE { DS_TINY, DS_SMALL, DS_NORMAL };

input group "Kernel envelope (curved zones)"
input ENUM_APPLIED_PRICE InpPrice      = PRICE_CLOSE;        // Source
input double             InpBandwidth  = 20.0;               // Bandwidth / smoothness
input int                InpWindow     = 500;                // Window (bars)
input double             InpInnerMult  = 1.5;                // Inner band x MAE (grey)
input double             InpOuterMult  = 3.0;                // Outer band x MAE (green)
input ENUM_HWM_MODE      InpMode       = HWM_NON_REPAINTING; // Mode
input int                InpMaxBars    = 5000;               // Max bars to calculate (0 = all)
input bool               InpShowFills  = true;               // Show zone fills
input bool               InpBarsOnTop  = true;               // Draw candles over fills

input group "Highway (stepped HTF band)"
input ENUM_TIMEFRAMES    InpHwTF       = PERIOD_M30;         // Highway timeframe
input int                InpHwLen      = 20;                 // Highway EMA length
input int                InpHwAtrLen   = 14;                 // Highway ATR length
input double             InpHwMult     = 0.5;                // Highway width x ATR

input group "Signals"
input bool               InpUseMom     = true;               // Require EMA momentum confirm
input int                InpEmaFast    = 5;                  // Momentum EMA length
input int                InpCooldown   = 10;                 // Cooldown bars between signals
input bool               InpShowText   = true;               // Show H-Sell / H-Buy text
input bool               InpAlerts     = true;               // Popup alerts on new signals
input bool               InpPush       = false;              // Push notifications

input group "Projection"
input bool               InpShowBox    = true;               // Show next-zone box
input int                InpBoxLen     = 40;                 // Box length (bars)
input bool               InpForecast   = true;               // Show echo forecast (dotted)
input int                InpFcLook     = 1000;               // Forecast search lookback
input int                InpFcPat      = 50;                 // Pattern length
input int                InpFcHor      = 120;                // Forecast horizon (bars)

input group "Dashboard"
input ENUM_DASH_POS      InpDashPos    = DP_MIDDLE_RIGHT;    // Position
input ENUM_DASH_SIZE     InpDashSize   = DS_SMALL;           // Size

//--- buffers
double sUO[], sUI[], bLI[], bLO[], fHU[], fHL[];
double lUO[], lUI[], lLI[], lLO[], lHU[], lHL[];
double aHS[], aS[], aHB[], aB[];
double midB[], maeB[], trendB[], srcB[], emaB[];

//--- state
#define PFX     "HWM_"
#define PFX_SIG "HWM_sig_"
#define PFX_RP  "HWM_rp_"
#define PFX_FC  "HWM_fc_"

double   g_w[];          // Gaussian weights g_w[d] = exp(-d^2 / 2h^2)
int      g_kLen  = 60;   // endpoint kernel length
int      g_kRep  = 80;   // half-width for centred (repainting) kernel
int      g_lastSig = -1000000;

datetime g_htfTime[];
double   g_htfEma[], g_htfAtr[];
bool     g_htfReady = false;

string   g_dashTrend  = "sideway";
string   g_dashStatus = "waiting";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpBandwidth <= 0 || InpWindow < 50 || InpHwLen < 1 || InpHwAtrLen < 1)
      return(INIT_PARAMETERS_INCORRECT);

   SetIndexBuffer(0,  sUO, INDICATOR_DATA);
   SetIndexBuffer(1,  sUI, INDICATOR_DATA);
   SetIndexBuffer(2,  bLI, INDICATOR_DATA);
   SetIndexBuffer(3,  bLO, INDICATOR_DATA);
   SetIndexBuffer(4,  fHU, INDICATOR_DATA);
   SetIndexBuffer(5,  fHL, INDICATOR_DATA);
   SetIndexBuffer(6,  lUO, INDICATOR_DATA);
   SetIndexBuffer(7,  lUI, INDICATOR_DATA);
   SetIndexBuffer(8,  lLI, INDICATOR_DATA);
   SetIndexBuffer(9,  lLO, INDICATOR_DATA);
   SetIndexBuffer(10, lHU, INDICATOR_DATA);
   SetIndexBuffer(11, lHL, INDICATOR_DATA);
   SetIndexBuffer(12, aHS, INDICATOR_DATA);
   SetIndexBuffer(13, aS,  INDICATOR_DATA);
   SetIndexBuffer(14, aHB, INDICATOR_DATA);
   SetIndexBuffer(15, aB,  INDICATOR_DATA);
   SetIndexBuffer(16, midB,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(17, maeB,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(18, trendB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(19, srcB,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(20, emaB,   INDICATOR_CALCULATIONS);

   for(int p = 0; p < 13; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   PlotIndexSetInteger(9,  PLOT_ARROW, 234);   // down arrow
   PlotIndexSetInteger(10, PLOT_ARROW, 234);
   PlotIndexSetInteger(11, PLOT_ARROW, 233);   // up arrow
   PlotIndexSetInteger(12, PLOT_ARROW, 233);
   PlotIndexSetInteger(9,  PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(10, PLOT_ARROW_SHIFT, -12);
   PlotIndexSetInteger(11, PLOT_ARROW_SHIFT,  12);
   PlotIndexSetInteger(12, PLOT_ARROW_SHIFT,  12);

   if(!InpShowFills)
      for(int p = 0; p < 3; p++)
         PlotIndexSetInteger(p, PLOT_DRAW_TYPE, DRAW_NONE);

   if(InpBarsOnTop)
      ChartSetInteger(0, CHART_FOREGROUND, true);

   //--- Gaussian weight table
   g_kLen = (int)MathMin(MathCeil(InpBandwidth * 3.0), 499.0);
   g_kRep = (int)MathCeil(InpBandwidth * 4.0);
   int wn = MathMax(g_kLen, g_kRep) + 1;
   ArrayResize(g_w, wn);
   for(int d = 0; d < wn; d++)
      g_w[d] = MathExp(-(double)(d * d) / (2.0 * InpBandwidth * InpBandwidth));

   IndicatorSetString(INDICATOR_SHORTNAME, "Highway Matrix");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
double PriceAt(const int i, const double &o[], const double &h[], const double &l[], const double &c[])
  {
   switch(InpPrice)
     {
      case PRICE_OPEN:     return o[i];
      case PRICE_HIGH:     return h[i];
      case PRICE_LOW:      return l[i];
      case PRICE_MEDIAN:   return (h[i] + l[i]) / 2.0;
      case PRICE_TYPICAL:  return (h[i] + l[i] + c[i]) / 3.0;
      case PRICE_WEIGHTED: return (h[i] + l[i] + 2.0 * c[i]) / 4.0;
      default:             return c[i];
     }
  }

//+------------------------------------------------------------------+
//| Load HTF rates and compute EMA + ATR (RMA) on them               |
//+------------------------------------------------------------------+
bool UpdateHTF(const datetime fromTime, const datetime toTime)
  {
   int avail = Bars(_Symbol, InpHwTF);
   if(avail <= 0)
      return false;
   int need = Bars(_Symbol, InpHwTF, fromTime, toTime) + 10 * MathMax(InpHwLen, InpHwAtrLen) + 50;
   int count = MathMin(avail, MathMax(need, 100));

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(_Symbol, InpHwTF, 0, count, r);
   if(got <= 1)
      return false;

   ArrayResize(g_htfTime, got);
   ArrayResize(g_htfEma,  got);
   ArrayResize(g_htfAtr,  got);

   double a = 2.0 / (InpHwLen + 1.0);
   double trSum = 0.0;
   for(int j = 0; j < got; j++)
     {
      g_htfTime[j] = r[j].time;
      g_htfEma[j]  = (j == 0) ? r[j].close : a * r[j].close + (1.0 - a) * g_htfEma[j - 1];

      double tr = r[j].high - r[j].low;
      if(j > 0)
         tr = MathMax(tr, MathMax(MathAbs(r[j].high - r[j - 1].close), MathAbs(r[j].low - r[j - 1].close)));
      if(j < InpHwAtrLen)
        {
         trSum += tr;
         g_htfAtr[j] = trSum / (j + 1);
        }
      else
         g_htfAtr[j] = (g_htfAtr[j - 1] * (InpHwAtrLen - 1) + tr) / InpHwAtrLen;
     }
   return true;
  }

//--- index of the latest HTF bar whose open time <= t, or -1
int HtfIndex(const datetime t)
  {
   int lo = 0, hi = ArraySize(g_htfTime) - 1, ans = -1;
   while(lo <= hi)
     {
      int m = (lo + hi) >> 1;
      if(g_htfTime[m] <= t) { ans = m; lo = m + 1; }
      else                    hi = m - 1;
     }
   return ans;
  }

//+------------------------------------------------------------------+
void SetBands(const int i, const double mid, const double mae)
  {
   double uo = mid + mae * InpOuterMult, ui = mid + mae * InpInnerMult;
   double li = mid - mae * InpInnerMult, lo = mid - mae * InpOuterMult;
   sUO[i] = uo; sUI[i] = ui; bLI[i] = li; bLO[i] = lo;
   lUO[i] = uo; lUI[i] = ui; lLI[i] = li; lLO[i] = lo;
  }

void ClearBands(const int i)
  {
   sUO[i] = EMPTY_VALUE; sUI[i] = EMPTY_VALUE; bLI[i] = EMPTY_VALUE; bLO[i] = EMPTY_VALUE;
   lUO[i] = EMPTY_VALUE; lUI[i] = EMPTY_VALUE; lLI[i] = EMPTY_VALUE; lLO[i] = EMPTY_VALUE;
  }

void TextLabel(const string name, const datetime t, const double price, const string txt,
               const color clr, const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
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
   if(rates_total < 100)
      return 0;

   const int  last  = rates_total - 1;
   const int  first = (InpMaxBars > 0) ? MathMax(0, rates_total - InpMaxBars) : 0;
   const bool fresh = (prev_calculated <= 0);
   const bool newBar = fresh || rates_total > prev_calculated;

   if(fresh)
     {
      ArrayInitialize(sUO, EMPTY_VALUE); ArrayInitialize(sUI, EMPTY_VALUE);
      ArrayInitialize(bLI, EMPTY_VALUE); ArrayInitialize(bLO, EMPTY_VALUE);
      ArrayInitialize(fHU, EMPTY_VALUE); ArrayInitialize(fHL, EMPTY_VALUE);
      ArrayInitialize(lUO, EMPTY_VALUE); ArrayInitialize(lUI, EMPTY_VALUE);
      ArrayInitialize(lLI, EMPTY_VALUE); ArrayInitialize(lLO, EMPTY_VALUE);
      ArrayInitialize(lHU, EMPTY_VALUE); ArrayInitialize(lHL, EMPTY_VALUE);
      ArrayInitialize(aHS, EMPTY_VALUE); ArrayInitialize(aS,  EMPTY_VALUE);
      ArrayInitialize(aHB, EMPTY_VALUE); ArrayInitialize(aB,  EMPTY_VALUE);
      ArrayInitialize(midB, EMPTY_VALUE); ArrayInitialize(maeB, EMPTY_VALUE);
      ArrayInitialize(trendB, 0.0);
      g_lastSig = -1000000;
      ObjectsDeleteAll(0, PFX_SIG);
     }

   //--- higher-timeframe highway data (refreshed once per new chart bar)
   if(newBar || !g_htfReady)
      g_htfReady = UpdateHTF(time[first], time[last]);
   if(!g_htfReady)
      return 0;   // HTF history not loaded yet — try again next tick

   const int start = fresh ? 0 : prev_calculated - 1;

   //--- source + momentum EMA (all bars, cheap)
   const double ae = 2.0 / (InpEmaFast + 1.0);
   for(int i = start; i < rates_total; i++)
     {
      srcB[i] = PriceAt(i, open, high, low, close);
      emaB[i] = (i == 0) ? srcB[i] : ae * srcB[i] + (1.0 - ae) * emaB[i - 1];
     }

   const int kStart = MathMax(start, first);

   //--- endpoint (causal) Gaussian kernel
   for(int i = kStart; i < rates_total; i++)
     {
      double num = 0.0, den = 0.0;
      int kMax = MathMin(g_kLen, i + 1);
      for(int k = 0; k < kMax; k++)
        {
         num += srcB[i - k] * g_w[k];
         den += g_w[k];
        }
      midB[i] = (den > 0.0) ? num / den : EMPTY_VALUE;
     }

   //--- MAE, bands, highway, trend
   for(int i = kStart; i < rates_total; i++)
     {
      double s = 0.0;
      int    c = 0;
      for(int j = MathMax(first, i - InpWindow + 1); j <= i; j++)
         if(midB[j] != EMPTY_VALUE) { s += MathAbs(srcB[j] - midB[j]); c++; }
      maeB[i] = (c > 0) ? s / c : 0.0;

      if(InpMode == HWM_NON_REPAINTING)
         SetBands(i, midB[i], maeB[i]);

      // highway: previous *completed* HTF bar → no repaint
      int hi = HtfIndex(time[i]);
      double hu = EMPTY_VALUE, hl = EMPTY_VALUE;
      if(hi >= 1)
        {
         hu = g_htfEma[hi - 1] + g_htfAtr[hi - 1] * InpHwMult;
         hl = g_htfEma[hi - 1] - g_htfAtr[hi - 1] * InpHwMult;
        }
      lHU[i] = hu; lHL[i] = hl; fHU[i] = hu; fHL[i] = hl;

      double slope = (i > first && midB[i - 1] != EMPTY_VALUE) ? midB[i] - midB[i - 1] : 0.0;
      int tr = 0;
      if(hu != EMPTY_VALUE)
        {
         if(close[i] > hu && slope > 0)      tr = 1;
         else if(close[i] < hl && slope < 0) tr = -1;
        }
      trendB[i] = tr;
     }

   //--- signals on closed bars only (each closed bar is processed exactly once)
   for(int i = MathMax(kStart, first + 1); i < last; i++)
     {
      aHS[i] = EMPTY_VALUE; aS[i] = EMPTY_VALUE; aHB[i] = EMPTY_VALUE; aB[i] = EMPTY_VALUE;
      if(InpMode != HWM_NON_REPAINTING)
         continue;

      double upIprev = midB[i - 1] + maeB[i - 1] * InpInnerMult;
      double loIprev = midB[i - 1] - maeB[i - 1] * InpInnerMult;
      double upI     = midB[i] + maeB[i] * InpInnerMult;
      double loI     = midB[i] - maeB[i] * InpInnerMult;

      bool rawSell = high[i - 1] >= upIprev && close[i] < upI && close[i] < open[i] &&
                     (!InpUseMom || emaB[i] < emaB[i - 1]);
      bool rawBuy  = low[i - 1]  <= loIprev && close[i] > loI && close[i] > open[i] &&
                     (!InpUseMom || emaB[i] > emaB[i - 1]);

      bool okCd    = (i - g_lastSig) > InpCooldown;
      bool sellSig = rawSell && okCd;
      bool buySig  = rawBuy && okCd && !sellSig;
      if(!sellSig && !buySig)
         continue;
      g_lastSig = i;

      int    tr  = (int)trendB[i];
      string nm  = PFX_SIG + IntegerToString((long)time[i]);
      double off = maeB[i] * 0.6;
      string txt;

      if(sellSig)
        {
         bool h = (tr == -1);
         if(h) aHS[i] = high[i]; else aS[i] = high[i];
         txt = h ? "H-Sell" : "Sell";
         if(InpShowText)
            TextLabel(nm, time[i], high[i] + off, txt, h ? C'229,57,80' : C'160,70,85', ANCHOR_LOWER);
        }
      else
        {
         bool h = (tr == 1);
         if(h) aHB[i] = low[i]; else aB[i] = low[i];
         txt = h ? "H-Buy" : "Buy";
         if(InpShowText)
            TextLabel(nm, time[i], low[i] - off, txt, h ? C'34,181,115' : C'60,140,105', ANCHOR_UPPER);
        }

      if(!fresh && i == last - 1)
        {
         string msg = StringFormat("Highway Matrix %s %s: %s @ %s", _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period),
                                   txt, DoubleToString(close[i], _Digits));
         if(InpAlerts) Alert(msg);
         if(InpPush)   SendNotification(msg);
        }
     }
   aHS[last] = EMPTY_VALUE; aS[last] = EMPTY_VALUE; aHB[last] = EMPTY_VALUE; aB[last] = EMPTY_VALUE;

   //--- repainting (video-look) mode
   if(InpMode == HWM_REPAINTING)
      RepaintPass(rates_total, first, time, high, low, newBar);

   //--- projections
   if(InpShowBox)
      DrawZoneBox(rates_total, time);
   if(InpForecast && newBar)
      DrawForecast(rates_total, time);

   //--- dashboard
   UpdateDashboardText(last, close[last]);
   DrawDashboard();

   return(rates_total);
  }

//+------------------------------------------------------------------+
//| Centred kernel over the last window — redraws history each tick  |
//+------------------------------------------------------------------+
void RepaintPass(const int total, const int first, const datetime &time[],
                 const double &high[], const double &low[], const bool newBar)
  {
   const int last = total - 1;
   const int n = MathMin(InpWindow, total - first);
   if(n < 20)
      return;

   double yh[];
   ArrayResize(yh, n);   // yh[j] = value at bar (last - j)
   for(int j = 0; j < n; j++)
     {
      double num = 0.0, den = 0.0;
      int iMin = MathMax(0, j - g_kRep), iMax = MathMin(n - 1, j + g_kRep);
      for(int i = iMin; i <= iMax; i++)
        {
         int d = (i > j) ? i - j : j - i;
         double w = g_w[d];
         num += srcB[last - i] * w;
         den += w;
        }
      yh[j] = num / den;
     }

   double s = 0.0;
   for(int j = 0; j < n; j++)
      s += MathAbs(srcB[last - j] - yh[j]);
   const double m = s / n;

   // bars that just slid out of the window
   for(int b = MathMax(first, last - n - 5); b <= last - n; b++)
      ClearBands(b);
   for(int j = 0; j < n; j++)
      SetBands(last - j, yh[j], m);

   if(!newBar)
      return;

   // hindsight "perfect" swing labels — only possible because the curve uses future bars
   ObjectsDeleteAll(0, PFX_RP);
   int made = 0;
   for(int j = 2; j <= n - 3 && made < 450; j++)
     {
      int b = last - j;
      double ui = yh[j] + m * InpInnerMult, li = yh[j] - m * InpInnerMult;
      bool isHi = high[b] >= ui && high[b] >= high[b + 1] && high[b] >= high[b + 2] && high[b] > high[b - 1] && high[b] > high[b - 2];
      bool isLo = low[b]  <= li && low[b]  <= low[b + 1]  && low[b]  <= low[b + 2]  && low[b]  < low[b - 1]  && low[b]  < low[b - 2];
      if(isHi) { TextLabel(PFX_RP + "s" + IntegerToString(b), time[b], high[b], "H-Sell", C'229,57,80', ANCHOR_LOWER); made++; }
      if(isLo) { TextLabel(PFX_RP + "b" + IntegerToString(b), time[b], low[b],  "H-Buy",  C'34,181,115', ANCHOR_UPPER); made++; }
     }
  }

//+------------------------------------------------------------------+
void DrawZoneBox(const int total, const datetime &time[])
  {
   const int last = total - 1;
   if(midB[last] == EMPTY_VALUE)
      return;
   const int ps = PeriodSeconds();
   const bool sellSide = ((int)trendB[last] != 1);
   const double mid = midB[last], mae = maeB[last];
   const double top = sellSide ? mid + mae * InpOuterMult : mid - mae * InpInnerMult;
   const double bot = sellSide ? mid + mae * InpInnerMult : mid - mae * InpOuterMult;
   const datetime t1 = time[last] + 5 * ps;
   const datetime t2 = time[last] + (5 + InpBoxLen) * ps;
   const color clr = sellSide ? C'120,30,45' : C'20,95,95';

   string nm = PFX + "box";
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_RECTANGLE, 0, t1, top, t2, bot);
   ObjectMove(0, nm, 0, t1, top);
   ObjectMove(0, nm, 1, t2, bot);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_FILL, true);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);

   TextLabel(PFX + "boxtxt", t1 + (InpBoxLen / 2) * ps, (top + bot) / 2.0,
             sellSide ? "Sell zone" : "Buy zone", clrSilver, ANCHOR_CENTER);
  }

//+------------------------------------------------------------------+
//| Echo forecast: best-correlated past pattern, projected forward   |
//+------------------------------------------------------------------+
void DrawForecast(const int total, const datetime &time[])
  {
   const int last = total - 1;
   const int P = InpFcPat, H = InpFcHor, L = InpFcLook;
   if(last < L + P || H < 1 || P < 2)
      return;

   double mA = 0.0;
   for(int t = 0; t < P; t++) mA += srcB[last - t];
   mA /= P;

   int bestK = -1;
   double bestR = -2.0;
   for(int k = H; k <= L - P; k++)
     {
      double mB = 0.0;
      for(int t = 0; t < P; t++) mB += srcB[last - k - t];
      mB /= P;
      double sab = 0.0, saa = 0.0, sbb = 0.0;
      for(int t = 0; t < P; t++)
        {
         double a = srcB[last - t] - mA;
         double b = srcB[last - k - t] - mB;
         sab += a * b; saa += a * a; sbb += b * b;
        }
      double r = (saa > 0.0 && sbb > 0.0) ? sab / MathSqrt(saa * sbb) : 0.0;
      if(r > bestR) { bestR = r; bestK = k; }
     }
   if(bestK <= 0)
      return;

   ObjectsDeleteAll(0, PFX_FC);
   const int ps = PeriodSeconds();
   const double base = srcB[last - bestK];
   const double now  = srcB[last];
   for(int h = 0; h < H; h++)
     {
      double y1 = now + (srcB[last - bestK + h]     - base);
      double y2 = now + (srcB[last - bestK + h + 1] - base);
      string nm = PFX_FC + IntegerToString(h);
      ObjectCreate(0, nm, OBJ_TREND, 0, time[last] + h * ps, y1, time[last] + (h + 1) * ps, y2);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, C'200,200,200');
      ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateDashboardText(const int last, const double price)
  {
   int tr = (int)trendB[last];
   g_dashTrend = (tr == 1) ? "uptrend" : (tr == -1) ? "downtrend" : "sideway";
   if(midB[last] == EMPTY_VALUE)
     {
      g_dashStatus = "waiting";
      return;
     }
   double upI = midB[last] + maeB[last] * InpInnerMult;
   double loI = midB[last] - maeB[last] * InpInnerMult;
   bool inSell = price >= upI, inBuy = price <= loI;
   if(tr == -1)     g_dashStatus = inSell ? "SELL zone - look for H-Sell" : "wait for price to reach sell zone";
   else if(tr == 1) g_dashStatus = inBuy  ? "BUY zone - look for H-Buy"   : "wait for price to reach buy zone";
   else             g_dashStatus = inSell ? "sell zone (counter only)" : inBuy ? "buy zone (counter only)" : "waiting";
  }

void DashLabel(const string nm, const int x, const int y, const string txt, const int fs, const color clr)
  {
   if(ObjectFind(0, nm) < 0)
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_UPPER);
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, nm, OBJPROP_TEXT, txt);
   ObjectSetString(0, nm, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
  }

void DrawDashboard()
  {
   int fs = (InpDashSize == DS_TINY) ? 7 : (InpDashSize == DS_NORMAL) ? 10 : 8;
   int W  = fs * 30, lineH = fs * 2 + 2, H = lineH * 3 + 8;

   int cw = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int ch = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   bool right = (InpDashPos == DP_TOP_RIGHT || InpDashPos == DP_MIDDLE_RIGHT || InpDashPos == DP_BOTTOM_RIGHT);
   int x = right ? cw - W - 10 : 10;
   int y;
   if(InpDashPos == DP_TOP_RIGHT || InpDashPos == DP_TOP_LEFT)            y = 20;
   else if(InpDashPos == DP_BOTTOM_RIGHT || InpDashPos == DP_BOTTOM_LEFT) y = ch - H - 20;
   else                                                                    y = ch / 2 - H / 2;
   x = MathMax(0, x); y = MathMax(0, y);

   string bg = PFX + "dash_bg";
   if(ObjectFind(0, bg) < 0)
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, W);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, H);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'11,30,58');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, C'42,111,219');
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   int cx = x + W / 2;
   DashLabel(PFX + "dash_t", cx, y + 4,               "HIGHWAY TREND DASHBOARD",        fs, clrWhite);
   DashLabel(PFX + "dash_1", cx, y + 4 + lineH,       "current trend = " + g_dashTrend, fs, clrWhite);
   DashLabel(PFX + "dash_2", cx, y + 4 + lineH * 2,   g_dashStatus,                     fs, C'200,210,230');
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      DrawDashboard();
      ChartRedraw();
     }
  }
//+------------------------------------------------------------------+
