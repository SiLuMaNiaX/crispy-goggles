//+------------------------------------------------------------------+
//|                                          AdaptiveSuperTrend.mq5  |
//|  MQL5 port of adaptive_supertrend.pine — clean-room rebuild of   |
//|  "SuperTrend" by TheRealDrip2Rip from its public description.    |
//|  Thresholds not stated in the description are marked [ASSUMED].  |
//+------------------------------------------------------------------+
#property copyright   "Adaptive SuperTrend rebuild"
#property version     "1.00"
#property description "SuperTrend with volatility-scaled factor, efficiency-based confirmation and graded flips."
#property indicator_chart_window
#property indicator_buffers 28
#property indicator_plots   5

#property indicator_label1  "Trend shading"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  C'12,52,50',C'64,22,24'
#property indicator_label2  "SuperTrend"
#property indicator_type2   DRAW_COLOR_LINE
#property indicator_color2  C'38,166,154',C'239,83,80'
#property indicator_width2  2
#property indicator_label3  "Candles"
#property indicator_type3   DRAW_COLOR_CANDLES
#property indicator_color3  C'38,166,154',C'239,83,80'
#property indicator_label4  "Long flip"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  C'38,166,154'
#property indicator_width4  2
#property indicator_label5  "Short flip"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  C'239,83,80'
#property indicator_width5  2

enum ENUM_DASH_CORNER { DC_TOP_RIGHT, DC_BOTTOM_RIGHT, DC_TOP_LEFT, DC_BOTTOM_LEFT };

input int    InpAtrLen   = 14;    // ATR Length
input double InpBaseF    = 3.5;   // Base Factor
input int    InpErLen    = 10;    // ER Length
input int    InpBaseConf = 2;     // Confirm Bars
input group  "Adaptation"
input int    InpVolAvg   = 50;    // Volatility average length
input double InpFMin     = 0.75;  // Min factor scale
input double InpFMax     = 1.4;   // Max factor scale
input double InpErChop   = 0.30;  // ER below = Choppy (+1 confirm bar) [ASSUMED]
input double InpErTrend  = 0.60;  // ER above = Trending (-1 confirm bar) [ASSUMED]
input double InpVrHigh   = 1.20;  // ATR ratio above = Elevated [ASSUMED]
input double InpVrLow    = 0.80;  // ATR ratio below = Compressed [ASSUMED]
input group  "Visuals"
input bool   InpShade    = true;  // Shading
input bool   InpCandles  = true;  // Color candles
input bool   InpLabels   = true;  // Flip labels
input bool   InpDash     = true;  // Dashboard
input ENUM_DASH_CORNER InpCorner = DC_TOP_RIGHT; // Dashboard corner
input bool   InpBarsOnTop = true; // Draw candles over shading
input group  "Alerts"
input bool   InpAlerts   = true;  // Popup alert on confirmed flip (bar close)
input bool   InpPush     = false; // Push notification

//--- plot buffers
double fA[], fB[], lineB[], lineC[], cO[], cH[], cL[], cC[], cClr[], aLong[], aShort[];
//--- state buffers (one value per bar so the forming bar can be recomputed safely)
double trB[], atrB[], upB[], dnB[], rawB[], confB[], heldB[], qB[], flipBarB[], erSumB[],
       nLongB[], nShortB[], lastQB[], erB[], vrB[], facB[], confNB[];

#define PFX "AST_"

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpAtrLen < 1 || InpErLen < 2 || InpBaseConf < 1 || InpVolAvg < 2 || InpFMin <= 0 || InpFMax < InpFMin)
      return(INIT_PARAMETERS_INCORRECT);
   int b = 0;
   SetIndexBuffer(b++, fA, INDICATOR_DATA);
   SetIndexBuffer(b++, fB, INDICATOR_DATA);
   SetIndexBuffer(b++, lineB, INDICATOR_DATA);
   SetIndexBuffer(b++, lineC, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(b++, cO, INDICATOR_DATA);
   SetIndexBuffer(b++, cH, INDICATOR_DATA);
   SetIndexBuffer(b++, cL, INDICATOR_DATA);
   SetIndexBuffer(b++, cC, INDICATOR_DATA);
   SetIndexBuffer(b++, cClr, INDICATOR_COLOR_INDEX);
   SetIndexBuffer(b++, aLong, INDICATOR_DATA);
   SetIndexBuffer(b++, aShort, INDICATOR_DATA);
   SetIndexBuffer(b++, trB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, atrB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, upB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, dnB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, rawB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, confB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, heldB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, qB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, flipBarB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, erSumB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, nLongB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, nShortB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, lastQB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, erB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, vrB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, facB, INDICATOR_CALCULATIONS);
   SetIndexBuffer(b++, confNB, INDICATOR_CALCULATIONS);

   for(int p = 0; p < 5; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(3, PLOT_ARROW, 233);
   PlotIndexSetInteger(4, PLOT_ARROW, 234);
   PlotIndexSetInteger(3, PLOT_ARROW_SHIFT, 14);
   PlotIndexSetInteger(4, PLOT_ARROW_SHIFT, -14);
   if(!InpShade)   PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
   if(!InpCandles) PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
   if(InpBarsOnTop) ChartSetInteger(0, CHART_FOREGROUND, true);
   IndicatorSetString(INDICATOR_SHORTNAME, "Adaptive SuperTrend");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { ObjectsDeleteAll(0, PFX); }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[],
                const double &open[], const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
  {
   const int warm = MathMax(InpAtrLen, InpErLen) + 1;
   if(rates_total < warm + 10)
      return 0;
   const bool fresh = (prev_calculated <= 0);
   if(fresh)
      ObjectsDeleteAll(0, PFX);
   const int start = fresh ? 0 : prev_calculated - 1;

   for(int i = start; i < rates_total; i++)
     {
      //--- blank outputs for this bar (it may be recomputed on every tick)
      fA[i] = fB[i] = lineB[i] = EMPTY_VALUE; lineC[i] = 0;
      cO[i] = cH[i] = cL[i] = cC[i] = EMPTY_VALUE; cClr[i] = 0;
      aLong[i] = aShort[i] = EMPTY_VALUE; qB[i] = EMPTY_VALUE;

      //--- true range and ATR (Wilder RMA seeded with an SMA, as ta.atr)
      trB[i] = (i == 0) ? high[i] - low[i]
               : MathMax(high[i] - low[i], MathMax(MathAbs(high[i] - close[i - 1]), MathAbs(low[i] - close[i - 1])));
      if(i < InpAtrLen - 1)       atrB[i] = EMPTY_VALUE;
      else if(i == InpAtrLen - 1)
        {
         double s = 0; for(int k = 0; k < InpAtrLen; k++) s += trB[k];
         atrB[i] = s / InpAtrLen;
        }
      else atrB[i] = (atrB[i - 1] * (InpAtrLen - 1) + trB[i]) / InpAtrLen;

      //--- carry state from the previous bar
      double prevUp = (i > 0) ? upB[i - 1] : EMPTY_VALUE, prevDn = (i > 0) ? dnB[i - 1] : EMPTY_VALUE;
      int    raw  = (i > 0) ? (int)rawB[i - 1] : 1;
      int    conf = (i > 0) ? (int)confB[i - 1] : 1;
      int    held = (i > 0) ? (int)heldB[i - 1] : 0;
      double flipBar = (i > 0) ? flipBarB[i - 1] : -1, erSum = (i > 0) ? erSumB[i - 1] : 0;
      double nL = (i > 0) ? nLongB[i - 1] : 0, nS = (i > 0) ? nShortB[i - 1] : 0, lastQ = (i > 0) ? lastQB[i - 1] : EMPTY_VALUE;

      if(atrB[i] == EMPTY_VALUE || i < warm)
        {
         upB[i] = prevUp; dnB[i] = prevDn; rawB[i] = raw; confB[i] = conf; heldB[i] = held;
         flipBarB[i] = flipBar; erSumB[i] = erSum; nLongB[i] = nL; nShortB[i] = nS; lastQB[i] = lastQ;
         erB[i] = 0; vrB[i] = 1; facB[i] = InpBaseF; confNB[i] = InpBaseConf;
         continue;
        }

      //--- volatility ratio -> adaptive factor
      double vr = 1.0;
      if(i >= InpAtrLen - 1 + InpVolAvg - 1)
        {
         double s = 0; for(int k = 0; k < InpVolAvg; k++) s += atrB[i - k];
         double avg = s / InpVolAvg;
         if(avg > 0) vr = atrB[i] / avg;
        }
      double factor = InpBaseF * MathMax(InpFMin, MathMin(InpFMax, vr));

      //--- Kaufman efficiency ratio -> adaptive confirmation
      double path = 0; for(int k = 0; k < InpErLen; k++) path += MathAbs(close[i - k] - close[i - k - 1]);
      double er = (path > 0) ? MathAbs(close[i] - close[i - InpErLen]) / path : 0.0;
      int confN = (er < InpErChop) ? InpBaseConf + 1 : (er > InpErTrend ? MathMax(1, InpBaseConf - 1) : InpBaseConf);

      //--- SuperTrend bands with per-bar factor
      double src = (high[i] + low[i]) / 2.0;
      double upNew = src - factor * atrB[i], dnNew = src + factor * atrB[i];
      double up = (prevUp == EMPTY_VALUE) ? upNew : (close[i - 1] > prevUp ? MathMax(upNew, prevUp) : upNew);
      double dn = (prevDn == EMPTY_VALUE) ? dnNew : (close[i - 1] < prevDn ? MathMin(dnNew, prevDn) : dnNew);
      int prevRaw = raw;
      if(raw == 1 && close[i] < up)       raw = -1;
      else if(raw == -1 && close[i] > dn) raw = 1;
      held = (raw != prevRaw) ? 1 : held + 1;

      //--- confirmation + quality
      bool flip = (raw != conf && held >= confN);
      if(flip)
        {
         conf = raw;
         double mom5 = (i >= 5) ? (close[i] - close[i - 5]) / atrB[i] * conf : 0.0;
         double effS = er * 100.0;
         double volS = 100.0 * (1.0 - MathMin(MathAbs(vr - 1.0) / 0.5, 1.0));      // [ASSUMED]
         double momS = 100.0 * MathMax(0.0, MathMin(mom5 / 2.0, 1.0));             // [ASSUMED]
         double q = 0.5 * effS + 0.3 * volS + 0.2 * momS;
         qB[i] = q; lastQ = q; flipBar = i; erSum = 0;
         if(conf == 1) nL++; else nS++;
        }
      erSum += er;

      //--- store state
      upB[i] = up; dnB[i] = dn; rawB[i] = raw; confB[i] = conf; heldB[i] = held;
      flipBarB[i] = flipBar; erSumB[i] = erSum; nLongB[i] = nL; nShortB[i] = nS; lastQB[i] = lastQ;
      erB[i] = er; vrB[i] = vr; facB[i] = factor; confNB[i] = confN;

      //--- outputs
      double line = (raw == 1) ? up : dn;
      lineB[i] = line; lineC[i] = (conf == 1) ? 0 : 1;
      fA[i] = close[i]; fB[i] = line;
      cO[i] = open[i]; cH[i] = high[i]; cL[i] = low[i]; cC[i] = close[i]; cClr[i] = (conf == 1) ? 0 : 1;

      string nm = PFX + "lbl_" + IntegerToString((long)time[i]);
      if(flip)
        {
         if(conf == 1) aLong[i] = low[i]; else aShort[i] = high[i];
         if(InpLabels)
           {
            string g = (qB[i] >= 70) ? "A" : (qB[i] >= 50 ? "B" : "C");
            string txt = (conf == 1 ? "LONG " : "SHORT ") + g + "  " + DoubleToString(close[i], _Digits);
            double off = atrB[i] * 0.8;
            if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_TEXT, 0, time[i], conf == 1 ? low[i] - off : high[i] + off);
            ObjectMove(0, nm, 0, time[i], conf == 1 ? low[i] - off : high[i] + off);
            ObjectSetString(0, nm, OBJPROP_TEXT, txt);
            ObjectSetInteger(0, nm, OBJPROP_COLOR, conf == 1 ? C'38,166,154' : C'239,83,80');
            ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, nm, OBJPROP_ANCHOR, conf == 1 ? ANCHOR_UPPER : ANCHOR_LOWER);
            ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
           }
        }
      else if(i == rates_total - 1)
         ObjectDelete(0, nm);   // forming bar un-flipped on this tick: remove a stale label

      //--- alert once, on the bar that just closed
      if(!fresh && i == rates_total - 2 && flip && rates_total > prev_calculated)
        {
         string g = (qB[i] >= 70) ? "A" : (qB[i] >= 50 ? "B" : "C");
         string msg = StringFormat("Adaptive SuperTrend %s %s: %s flip, grade %s (%.0f) @ %s", _Symbol,
                                   EnumToString((ENUM_TIMEFRAMES)_Period), conf == 1 ? "LONG" : "SHORT", g, qB[i],
                                   DoubleToString(close[i], _Digits));
         if(InpAlerts) Alert(msg);
         if(InpPush)   SendNotification(msg);
        }
     }

   if(InpDash) DrawDashboard(rates_total - 1, close[rates_total - 1]);
   return rates_total;
  }

//+------------------------------------------------------------------+
void DashRow(const int r, const string k, const string v, const color vc, const int x, const int y0, const int lh)
  {
   string nk = PFX + "dk" + IntegerToString(r), nv = PFX + "dv" + IntegerToString(r);
   ENUM_BASE_CORNER cr = (InpCorner == DC_TOP_LEFT) ? CORNER_LEFT_UPPER : (InpCorner == DC_BOTTOM_LEFT) ? CORNER_LEFT_LOWER :
                         (InpCorner == DC_BOTTOM_RIGHT) ? CORNER_RIGHT_LOWER : CORNER_RIGHT_UPPER;
   bool right = (InpCorner == DC_TOP_RIGHT || InpCorner == DC_BOTTOM_RIGHT);
   bool lower = (InpCorner == DC_BOTTOM_RIGHT || InpCorner == DC_BOTTOM_LEFT);
   int y = lower ? y0 + (11 - r) * lh : y0 + r * lh;
   string names[2]; names[0] = nk; names[1] = nv;
   string texts[2]; texts[0] = k;  texts[1] = v;
   for(int j = 0; j < 2; j++)
     {
      if(ObjectFind(0, names[j]) < 0) ObjectCreate(0, names[j], OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, names[j], OBJPROP_CORNER, cr);
      ObjectSetInteger(0, names[j], OBJPROP_ANCHOR, right ? ANCHOR_RIGHT_UPPER : ANCHOR_LEFT_UPPER);
      // right corner: values at the edge, keys further in; left corner: keys at the edge
      int xx = right ? (j == 1 ? x : x + 110) : (j == 0 ? x : x + 110);
      ObjectSetInteger(0, names[j], OBJPROP_XDISTANCE, xx);
      ObjectSetInteger(0, names[j], OBJPROP_YDISTANCE, y);
      ObjectSetString(0, names[j], OBJPROP_TEXT, texts[j]);
      ObjectSetString(0, names[j], OBJPROP_FONT, j == 0 ? "Arial" : "Arial Bold");
      ObjectSetInteger(0, names[j], OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, names[j], OBJPROP_COLOR, j == 0 ? C'178,181,190' : vc);
      ObjectSetInteger(0, names[j], OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, names[j], OBJPROP_HIDDEN, true);
     }
  }

void DrawDashboard(const int i, const double px)
  {
   const color up = C'38,166,154', dn = C'239,83,80', wh = clrWhite;
   int conf = (int)confB[i];
   double age = (flipBarB[i] >= 0) ? i - flipBarB[i] : 0;
   double avgEr = (age > 0) ? erSumB[i] / (age + 1) : erB[i];
   double conv = MathMin(age / 50.0, 1.0) * 0.5 + avgEr * 0.5;                     // [ASSUMED]
   string eff = (erB[i] > InpErTrend) ? "Trending" : (erB[i] < InpErChop ? "Choppy" : "Mixed");
   string vol = (vrB[i] > InpVrHigh) ? "Elevated" : (vrB[i] < InpVrLow ? "Compressed" : "Normal");
   double lq = lastQB[i];
   string lg = (lq == EMPTY_VALUE) ? "-" : (lq >= 70 ? "A" : (lq >= 50 ? "B" : "C"));
   double line = lineB[i];
   string dist = (line == EMPTY_VALUE || px == 0) ? "-" : DoubleToString((px - line) / px * 100.0, 2) + "%";
   int x = 12, y0 = 20, lh = 15;
   DashRow(0, "SuperTrend", "F " + DoubleToString(facB[i], 2) + "  C " + IntegerToString((int)confNB[i]), wh, x, y0, lh);
   DashRow(1, "Direction", conf == 1 ? "LONG" : "SHORT", conf == 1 ? up : dn, x, y0, lh);
   DashRow(2, "Trend age", IntegerToString((int)age) + " bars", wh, x, y0, lh);
   DashRow(3, "Conviction", IntegerToString((int)MathRound(conv * 100)) + "%", wh, x, y0, lh);
   DashRow(4, "Efficiency", eff + " (" + DoubleToString(erB[i], 2) + ")", wh, x, y0, lh);
   DashRow(5, "Volatility", vol, wh, x, y0, lh);
   DashRow(6, "Adaptive factor", DoubleToString(facB[i], 2), wh, x, y0, lh);
   DashRow(7, "Last flip", lq == EMPTY_VALUE ? "-" : IntegerToString((int)MathRound(lq)) + "  " + lg,
           lg == "A" ? up : (lg == "C" ? dn : clrOrange), x, y0, lh);
   DashRow(8, "Distance", dist, wh, x, y0, lh);
   DashRow(9, "Long flips", IntegerToString((int)nLongB[i]), up, x, y0, lh);
   DashRow(10, "Short flips", IntegerToString((int)nShortB[i]), dn, x, y0, lh);
  }
//+------------------------------------------------------------------+
