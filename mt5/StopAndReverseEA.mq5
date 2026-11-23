//+------------------------------------------------------------------+
//|                                            StopAndReverseEA.mq5  |
//|  Stop-and-reverse scalper reverse-engineered from a screen       |
//|  recording of manual XAUUSD M1 trading:                          |
//|    1. open a position with a tight stop-loss                     |
//|    2. park an opposite STOP order at the stop-loss level         |
//|    3. if the SL is hit, the stop order flips you the other way   |
//|    4. a take-profit (or the flip limit) ends the cycle           |
//+------------------------------------------------------------------+
#property copyright "crispy-goggles"
#property version   "1.10"
#property description "Stop-and-reverse (SAR) cycle manager: market entry + tight SL + opposite stop order parked at the SL."

#include <Trade/Trade.mqh>

//--- entry modes
enum ENUM_SAR_ENTRY
  {
   ENTRY_SPIKE_FADE = 0, // Auto: fade a spike after a pullback (as in the video)
   ENTRY_ALWAYS_BUY = 1, // Auto: always start cycles with BUY
   ENTRY_ALWAYS_SELL= 2, // Auto: always start cycles with SELL
   ENTRY_MANUAL     = 3  // Manual: you open trades, EA manages the reversals
  };

//=== Inputs =========================================================
input group "Cycle"
input ENUM_SAR_ENTRY InpEntryMode      = ENTRY_SPIKE_FADE; // How a new cycle starts
input double         InpLots           = 0.02;  // Lots of the first trade in a cycle
input double         InpLotMultiplier  = 1.0;   // Lot multiplier per flip (1.0 = flat, 2.0 = martingale)
input double         InpMaxLots        = 0.50;  // Hard cap on any single order
input int            InpMaxFlips       = 3;     // Max reversals per cycle (0 = plain SL, no reversal)
input double         InpStopDist       = 1.50;  // Stop-loss distance in price units (1.50 = $1.50 on gold)
input double         InpTakeProfitDist = 2.00;  // Take-profit distance in price units (0 = no TP)
input double         InpReverseOffset  = 0.0;   // Extra price distance beyond the SL for the reverse stop order
input bool           InpRecoverLosses  = false; // Widen TP after a flip so a win recovers the cycle's losses
input int            InpCooldownBars   = 2;     // Bars to wait after a cycle ends before a new one

input group "Spike-fade signal (ENTRY_SPIKE_FADE only)"
input ENUM_TIMEFRAMES InpSignalTF        = PERIOD_M1; // Signal timeframe
input int             InpLookback        = 20;    // Bars searched for the spike
input int             InpAtrPeriod       = 14;    // ATR period
input double          InpSpikeAtr        = 4.0;   // Spike size (high-low) in ATRs
input double          InpPullbackAtr     = 1.0;   // Pullback from extreme in ATRs to trigger
input int             InpMaxBarsSinceExt = 5;     // Extreme must be at most this many bars old
input bool            InpInvertSignal    = false; // true = follow the spike instead of fading it

input group "Filters & risk"
input double InpMaxSpread        = 0.40; // Skip new cycles if spread above this, in price units (0 = off)
input int    InpStartHour        = 0;    // Trading window start (server hour, inclusive)
input int    InpEndHour          = 24;   // Trading window end (server hour, exclusive)
input double InpMaxDailyLossPct  = 3.0;  // Stop new cycles after this % daily loss (0 = off)
input double InpMaxSlippage      = 0.30; // Max slippage on market entries, in price units
input int    InpOrphanSeconds    = 120;  // Delete a reverse order left without a position after this long

input group "Misc"
input long   InpMagic            = 26112001; // Magic number
input bool   InpShowPanel        = true;     // Show status in chart corner

//=== State ==========================================================
CTrade   trade;
int      g_atrHandle      = INVALID_HANDLE;
bool     g_cycleActive    = false;
bool     g_endCycle       = false;   // set when a close was NOT a stop-loss (TP, manual, stop-out)
double   g_cyclePL        = 0.0;     // realised P/L of the running cycle
int      g_cycleFlips     = 0;
datetime g_lastCloseTime  = 0;
datetime g_cycleEndBar    = 0;
datetime g_lastSignalBar  = 0;
int      g_dayOfYear      = -1;
double   g_dayStartBalance= 0.0;
string   g_status         = "";

const string CMT_PREFIX = "SAR#";

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpStopDist <= 0 || InpLots <= 0 || InpLotMultiplier <= 0)
     {
      Print("SAR: invalid inputs (stop, lots and multiplier must be > 0)");
      return INIT_PARAMETERS_INCORRECT;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)MathMax(1.0, MathRound(InpMaxSlippage / _Point)));
   trade.SetTypeFillingBySymbol(_Symbol);

   if(InpEntryMode == ENTRY_SPIKE_FADE)
     {
      g_atrHandle = iATR(_Symbol, InpSignalTF, InpAtrPeriod);
      if(g_atrHandle == INVALID_HANDLE)
        {
         Print("SAR: failed to create ATR handle");
         return INIT_FAILED;
        }
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("SAR: WARNING - account is not in hedging mode. The reverse stop order may net against ",
            "the open position instead of opening a new one. A hedging account is recommended.");

   // A restart loses in-memory state: if a position is open, treat the cycle as active.
   ulong t; int type; double lots, sl, open; string cmt;
   g_cycleActive = FindPosition(t, type, lots, sl, open, cmt);
   if(!g_cycleActive)
      DeletePendings(); // leftover reverse orders without a position are orphans

   ResetDay();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Track closes: why did the position close, and what did it make?  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != _Symbol)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;

   long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;

   // The closing deal of an SL/TP carries the position's magic. Manual-mode positions have magic 0.
   bool ours = (magic == InpMagic) || (InpEntryMode == ENTRY_MANUAL && magic == 0 && g_cycleActive);
   if(!ours)
      return;

   double pl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
             + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
             + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
   g_cyclePL      += pl;
   g_lastCloseTime = TimeCurrent();

   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   if(reason != DEAL_REASON_SL)
      g_endCycle = true; // TP, manual close, stop-out ... cycle is over

   PrintFormat("SAR: close deal #%I64u reason=%s P/L=%.2f cycleP/L=%.2f",
               trans.deal, EnumToString(reason), pl, g_cyclePL);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDay();

   ulong  posTicket; int posType; double posLots, posSL, posOpen; string posCmt;
   bool hasPos = FindPosition(posTicket, posType, posLots, posSL, posOpen, posCmt);

   if(hasPos)
     {
      ManagePosition(posTicket, posType, posLots, posSL, posOpen, posCmt);
     }
   else if(CountPendings() > 0)
     {
      // No position but a reverse order exists:
      //  - SL was hit and the stop order is about to fill (keep it), or
      //  - the cycle ended by TP/manual close (delete it).
      if(!g_cycleActive || g_endCycle)
         DeletePendings();
      else if(g_lastCloseTime > 0 && TimeCurrent() - g_lastCloseTime > InpOrphanSeconds)
        {
         Print("SAR: reverse order never filled, removing it");
         DeletePendings();
        }
      g_status = "Waiting for reverse order to fill";
     }
   else
     {
      if(g_cycleActive)
         EndCycle();
      TryStartCycle();
     }

   if(InpShowPanel)
      DrawPanel(hasPos, posType, posLots);
  }

//+------------------------------------------------------------------+
//| Position management: make sure SL exists and the reverse order   |
//| is parked at it.                                                 |
//+------------------------------------------------------------------+
void ManagePosition(ulong ticket, int type, double lots, double sl, double open, string cmt)
  {
   if(!g_cycleActive)
     {
      // first sight of this cycle (e.g. a manual trade being adopted)
      g_cycleActive = true;
      g_cyclePL     = 0.0;
     }
   g_endCycle = false; // a live position means the cycle continues

   int flip = ParseFlip(cmt);
   g_cycleFlips = flip;

   // 1) attach a stop-loss if missing (manual trades)
   if(sl <= 0.0)
     {
      double newSL = (type == POSITION_TYPE_BUY) ? open - InpStopDist
                                                 : open + InpStopDist;
      double tp    = PositionGetDouble(POSITION_TP);
      if(tp <= 0.0 && InpTakeProfitDist > 0)
         tp = (type == POSITION_TYPE_BUY) ? open + InpTakeProfitDist
                                          : open - InpTakeProfitDist;
      newSL = RoundPrice(newSL);
      if(!trade.PositionModify(ticket, newSL, RoundPrice(tp)))
        {
         PrintFormat("SAR: could not set SL on #%I64u: %s", ticket, trade.ResultRetcodeDescription());
         return;
        }
      sl = newSL;
     }

   // 2) remove pending orders that point the wrong way, keep one correct reverse order
   ENUM_ORDER_TYPE wanted = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
   bool haveReverse = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ot = OrderGetTicket(i);
      if(ot == 0 || !IsOurOrder())
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == wanted && !haveReverse)
         haveReverse = true;
      else
         trade.OrderDelete(ot);
     }

   // 3) place the reverse order at the SL level
   if(!haveReverse && flip < InpMaxFlips)
      PlaceReverse(type, sl, lots, flip + 1);

   g_status = StringFormat("%s %.2f  flip %d/%d", type == POSITION_TYPE_BUY ? "BUY" : "SELL",
                           lots, flip, InpMaxFlips);
  }

//+------------------------------------------------------------------+
bool PlaceReverse(int posType, double posSL, double posLots, int nextFlip)
  {
   double lots = LotsForFlip(nextFlip);
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   string cmt  = CMT_PREFIX + IntegerToString(nextFlip);

   double tpDist = TakeProfitDistForFlip(lots, posLots);

   if(posType == POSITION_TYPE_BUY)
     {
      // long stopped out below -> go short there
      double price = RoundPrice(posSL - InpReverseOffset);
      if(price >= bid - stopsLevel)
         return false; // too close to market right now; retry next tick
      double sl = RoundPrice(price + InpStopDist);
      double tp = (tpDist > 0) ? RoundPrice(price - tpDist) : 0.0;
      if(!trade.SellStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt))
        {
         PrintFormat("SAR: SellStop failed: %s", trade.ResultRetcodeDescription());
         return false;
        }
     }
   else
     {
      // short stopped out above -> go long there
      double price = RoundPrice(posSL + InpReverseOffset);
      if(price <= ask + stopsLevel)
         return false;
      double sl = RoundPrice(price - InpStopDist);
      double tp = (tpDist > 0) ? RoundPrice(price + tpDist) : 0.0;
      if(!trade.BuyStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt))
        {
         PrintFormat("SAR: BuyStop failed: %s", trade.ResultRetcodeDescription());
         return false;
        }
     }
   PrintFormat("SAR: reverse order placed, flip %d, %.2f lots, TP distance %s", nextFlip, lots, DoubleToString(tpDist, _Digits));
   return true;
  }

//+------------------------------------------------------------------+
//| TP distance for the next flip. With recovery on, the TP is       |
//| widened so a win covers the cycle's realised losses plus the     |
//| loss the current position takes when its SL is hit.              |
//+------------------------------------------------------------------+
double TakeProfitDistForFlip(double lots, double currentPosLots)
  {
   double base = InpTakeProfitDist;
   if(!InpRecoverLosses || base <= 0)
      return base;

   double vpu = ValuePerPriceUnitPerLot();
   if(vpu <= 0 || lots <= 0)
      return base;

   double pendingLoss = currentPosLots * (InpStopDist + CurrentSpread()) * vpu; // loss when current SL hits
   double toRecover   = MathMax(0.0, -g_cyclePL) + pendingLoss;
   double target      = base * lots * vpu;                                      // the normal profit target
   return (toRecover + target) / (lots * vpu);                                  // rounded later by RoundPrice
  }

//+------------------------------------------------------------------+
void TryStartCycle()
  {
   if(InpEntryMode == ENTRY_MANUAL)
     {
      g_status = "Manual mode: open a trade, EA manages reversals";
      return;
     }
   if(!CanStartCycle())
      return;

   int dir = GetSignal();
   if(dir == 0)
     {
      if(g_status == "")
         g_status = "Waiting for signal";
      return;
     }

   double lots = LotsForFlip(0);
   double tpDist = InpTakeProfitDist;
   string cmt  = CMT_PREFIX + "0";
   bool ok;

   g_cyclePL  = 0.0;
   g_endCycle = false;

   if(dir > 0)
     {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = RoundPrice(ask - InpStopDist);
      double tp  = (tpDist > 0) ? RoundPrice(ask + tpDist) : 0.0;
      ok = trade.Buy(lots, _Symbol, 0.0, sl, tp, cmt);
     }
   else
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = RoundPrice(bid + InpStopDist);
      double tp  = (tpDist > 0) ? RoundPrice(bid - tpDist) : 0.0;
      ok = trade.Sell(lots, _Symbol, 0.0, sl, tp, cmt);
     }

   if(ok)
     {
      g_cycleActive = true;
      PrintFormat("SAR: new cycle %s %.2f lots", dir > 0 ? "BUY" : "SELL", lots);
     }
   else
      PrintFormat("SAR: entry failed: %s", trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
bool CanStartCycle()
  {
   // cooldown after the previous cycle
   if(g_cycleEndBar > 0)
     {
      int barsSince = iBarShift(_Symbol, _Period, g_cycleEndBar, false);
      if(barsSince >= 0 && barsSince < InpCooldownBars)
        {
         g_status = "Cooldown";
         return false;
        }
     }

   // trading window
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
     {
      g_status = "Outside trading hours";
      return false;
     }

   // spread
   double spread = CurrentSpread();
   if(InpMaxSpread > 0 && spread > InpMaxSpread)
     {
      g_status = "Spread too wide (" + DoubleToString(spread, _Digits) + ")";
      return false;
     }

   // daily loss guard
   if(InpMaxDailyLossPct > 0 && g_dayStartBalance > 0)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity <= g_dayStartBalance * (1.0 - InpMaxDailyLossPct / 100.0))
        {
         g_status = "Daily loss limit hit - no new cycles today";
         return false;
        }
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      g_status = "Algo trading disabled";
      return false;
     }

   g_status = "";
   return true;
  }

//+------------------------------------------------------------------+
//| +1 buy, -1 sell, 0 nothing                                       |
//+------------------------------------------------------------------+
int GetSignal()
  {
   if(InpEntryMode == ENTRY_ALWAYS_BUY)
      return 1;
   if(InpEntryMode == ENTRY_ALWAYS_SELL)
      return -1;
   if(InpEntryMode != ENTRY_SPIKE_FADE)
      return 0;

   // evaluate once per closed bar
   datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(barTime == 0 || barTime == g_lastSignalBar)
      return 0;
   g_lastSignalBar = barTime;

   double atrBuf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atrBuf) != 1 || atrBuf[0] <= 0)
      return 0;
   double atr = atrBuf[0];

   int hiIdx = iHighest(_Symbol, InpSignalTF, MODE_HIGH, InpLookback, 1);
   int loIdx = iLowest(_Symbol, InpSignalTF, MODE_LOW, InpLookback, 1);
   if(hiIdx < 0 || loIdx < 0)
      return 0;

   double hi    = iHigh(_Symbol, InpSignalTF, hiIdx);
   double lo    = iLow(_Symbol, InpSignalTF, loIdx);
   double close = iClose(_Symbol, InpSignalTF, 1);
   if(hi - lo < InpSpikeAtr * atr)
      return 0;

   int dir = 0;
   // spike UP (low is older than high), now pulling back from the top -> fade = sell
   if(loIdx > hiIdx && hiIdx <= InpMaxBarsSinceExt && hi - close >= InpPullbackAtr * atr)
      dir = -1;
   // spike DOWN (high is older than low), now bouncing off the bottom -> fade = buy
   else if(hiIdx > loIdx && loIdx <= InpMaxBarsSinceExt && close - lo >= InpPullbackAtr * atr)
      dir = 1;

   if(InpInvertSignal)
      dir = -dir;
   return dir;
  }

//+------------------------------------------------------------------+
void EndCycle()
  {
   PrintFormat("SAR: cycle ended after %d flip(s), P/L %.2f", g_cycleFlips, g_cyclePL);
   g_cycleActive  = false;
   g_endCycle     = false;
   g_cycleFlips   = 0;
   g_lastCloseTime= 0;
   g_cycleEndBar  = iTime(_Symbol, _Period, 0);
  }

//=== Helpers ========================================================

// Finds the position this EA manages on this symbol (ours, or a manual one in manual mode).
bool FindPosition(ulong &ticket, int &type, double &lots, double &sl, double &open, string &cmt)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagic && !(InpEntryMode == ENTRY_MANUAL && magic == 0))
         continue;
      ticket = t;
      type   = (int)PositionGetInteger(POSITION_TYPE);
      lots   = PositionGetDouble(POSITION_VOLUME);
      sl     = PositionGetDouble(POSITION_SL);
      open   = PositionGetDouble(POSITION_PRICE_OPEN);
      cmt    = PositionGetString(POSITION_COMMENT);
      return true;
     }
   return false;
  }

bool IsOurOrder()
  {
   return OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagic;
  }

int CountPendings()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) > 0 && IsOurOrder())
         n++;
   return n;
  }

void DeletePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && IsOurOrder())
         trade.OrderDelete(t);
     }
  }

// Flip number carried in the order/position comment ("SAR#2"). Manual trades -> 0.
int ParseFlip(string cmt)
  {
   int p = StringFind(cmt, CMT_PREFIX);
   if(p < 0)
      return 0;
   return (int)StringToInteger(StringSubstr(cmt, p + StringLen(CMT_PREFIX)));
  }

double LotsForFlip(int flip)
  {
   return NormalizeLots(InpLots * MathPow(InpLotMultiplier, flip));
  }

double NormalizeLots(double lots)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMin(lots, InpMaxLots);
   if(step > 0)
      lots = MathFloor(lots / step + 1e-9) * step;
   lots = MathMax(vmin, MathMin(vmax, lots));
   int digits = (step > 0) ? (int)MathMax(0.0, MathCeil(-MathLog10(step) - 1e-9)) : 2;
   return NormalizeDouble(lots, digits);
  }

double RoundPrice(double price)
  {
   if(price <= 0)
      return 0.0;
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts > 0)
      price = MathRound(price / ts) * ts;
   return NormalizeDouble(price, _Digits);
  }

// Account-currency value of a 1.0 price move for 1.0 lot.
double ValuePerPriceUnitPerLot()
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      return 0.0;
   return tv / ts;
  }

// Current spread in price units.
double CurrentSpread()
  {
   return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
  }

void ResetDay()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayOfYear)
     {
      g_dayOfYear       = dt.day_of_year;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
     }
  }

void DrawPanel(bool hasPos, int posType, double posLots)
  {
   string s = "Stop-and-Reverse EA\n";
   s += StringFormat("Mode: %s\n", EnumToString(InpEntryMode));
   s += StringFormat("Status: %s\n", g_status);
   s += StringFormat("Cycle active: %s   flips: %d/%d\n", g_cycleActive ? "yes" : "no", g_cycleFlips, InpMaxFlips);
   s += StringFormat("Cycle P/L (realised): %.2f\n", g_cyclePL);
   s += "Spread: " + DoubleToString(CurrentSpread(), _Digits)
      + "   SL " + DoubleToString(InpStopDist, _Digits)
      + " / TP " + DoubleToString(InpTakeProfitDist, _Digits) + " (price units)";
   Comment(s);
  }
//+------------------------------------------------------------------+
