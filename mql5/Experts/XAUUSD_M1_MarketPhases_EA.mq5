//+------------------------------------------------------------------+
//|                                  XAUUSD_M1_MarketPhases_EA.mq5   |
//|  Trades the signals of the XAUUSD_M1_MarketPhases indicator       |
//|  (MT5 port of the Pine v6 "Economics + Structure + Market Phases" |
//|  indicator). All signal logic lives in the indicator; this EA     |
//|  reads its buffers with iCustom and only manages orders.          |
//|                                                                  |
//|  Requires: MQL5/Indicators/XAUUSD_M1_MarketPhases.ex5             |
//+------------------------------------------------------------------+
#property copyright "Port of Pine indicator - use at your own risk"
#property version   "2.00"
#property tester_indicator "XAUUSD_M1_MarketPhases.ex5"

#include <Trade\Trade.mqh>

#define IND_NAME "XAUUSD_M1_MarketPhases"
#define IND_SHORTNAME "MarketPhases"

// Indicator buffer indices (must match the indicator)
#define B_BUY        0
#define B_SELL       1
#define B_EARLY_BULL 2
#define B_EARLY_BEAR 3
#define B_BULL_SB    4
#define B_BEAR_SB    5
#define B_FAIL_BULL  6
#define B_FAIL_BEAR  7
#define B_PHASE      8
#define B_BIAS       9
#define B_SIGTYPE   10
#define B_ATR       11

#define SIG_CONT   1
#define SIG_REV    2
#define SIG_RANGE  4

//=====================================================================
// INDICATOR INPUTS - passed to iCustom in this exact order
//=====================================================================
input group "1. Market Structure"
input int    InpPivotLen            = 3;     // Pivot Confirmation Length
input bool   InpShowSwingBreaks     = true;  // Show Structural Breaks

input group "2. Trading Range"
input int    InpRangeLookback       = 30;    // Range Lookback
input int    InpAtrLen              = 7;     // ATR Length
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
input int    InpMaxBars             = 5000;  // Bars of history the indicator calculates
input bool   InpShowIndicatorOnChart= true;  // Attach the indicator to the chart (live)

//=====================================================================
// TRADING INPUTS
//=====================================================================
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
CTrade   g_trade;
int      g_handle      = INVALID_HANDLE;
datetime g_lastBar     = 0;
bool     g_addedToChart = false;

struct BarSignals
{
   bool   buy, sell;
   int    buyType, sellType;   // SIG_* bitmasks
   bool   failBull, failBear;
   double atr;
};

//+------------------------------------------------------------------+
//| Read one buffer value at a shift; false if not available yet      |
//+------------------------------------------------------------------+
bool ReadBuf(int buffer, int shift, double &value)
{
   double tmp[];
   if(CopyBuffer(g_handle, buffer, shift, 1, tmp) != 1) return false;
   value = tmp[0];
   return true;
}

bool ReadSignals(int shift, BarSignals &sg)
{
   ZeroMemory(sg);
   if(BarsCalculated(g_handle) <= 0) return false;

   double phase, buy, sell, fb, fs, sig, atr;
   if(!ReadBuf(B_PHASE, shift, phase) || phase == EMPTY_VALUE) return false; // bar not processed yet
   if(!ReadBuf(B_BUY, shift, buy))       return false;
   if(!ReadBuf(B_SELL, shift, sell))     return false;
   if(!ReadBuf(B_FAIL_BULL, shift, fb))  return false;
   if(!ReadBuf(B_FAIL_BEAR, shift, fs))  return false;
   if(!ReadBuf(B_SIGTYPE, shift, sig))   return false;
   if(!ReadBuf(B_ATR, shift, atr) || atr == EMPTY_VALUE) return false;

   int st = (int)MathRound(sig);
   sg.buy      = buy  != EMPTY_VALUE;
   sg.sell     = sell != EMPTY_VALUE;
   sg.buyType  = st > 0 ? st  : 0;
   sg.sellType = st < 0 ? -st : 0;
   sg.failBull = fb != EMPTY_VALUE;
   sg.failBear = fs != EMPTY_VALUE;
   sg.atr      = atr;
   return true;
}

//=====================================================================
// TRADING LAYER
//=====================================================================
int CurrentPositionDir()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
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
         PrintFormat("Close failed #%I64u: %u %s", tk, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
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
   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double lossPerLot = slDistance / tickSize * tickVal;
   if(lossPerLot <= 0) return NormalizeLots(InpFixedLots);
   return NormalizeLots(riskMoney / lossPerLot);
}

bool EntryFiltersOK()
{
   if(InpMaxSpreadPoints > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpreadPoints)
      {
         PrintFormat("Entry skipped: spread %I64d > %d", spread, InpMaxSpreadPoints);
         return false;
      }
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
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopsLvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   double slDist = MathMax(atr * InpSL_ATR, stopsLvl + 2 * _Point);
   double price  = dir == 1 ? ask : bid;
   double sl     = NormalizeDouble(dir == 1 ? price - slDist : price + slDist, digits);
   double tp     = 0;
   if(InpTP_R > 0)
      tp = NormalizeDouble(dir == 1 ? price + slDist * InpTP_R : price - slDist * InpTP_R, digits);

   double lots = CalcLots(slDist);
   bool ok = dir == 1 ? g_trade.Buy(lots, _Symbol, 0, sl, tp, "MP " + why)
                      : g_trade.Sell(lots, _Symbol, 0, sl, tp, "MP " + why);
   if(!ok)
      PrintFormat("Order failed: %u %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

bool TypeAllowed(int mask)
{
   return (InpTradeContinuation  && (mask & SIG_CONT)  != 0) ||
          (InpTradeReversal      && (mask & SIG_REV)   != 0) ||
          (InpTradeRangeBreakout && (mask & SIG_RANGE) != 0);
}

string TypeName(int mask)
{
   if((mask & SIG_REV) != 0)   return "REV";
   if((mask & SIG_RANGE) != 0) return "RANGE";
   return "CONT";
}

void HandleTrading(const BarSignals &sg)
{
   if(!InpEnableTrading) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) return;

   int pos = CurrentPositionDir();

   // Exit on a failed breakout against the open position
   if(InpCloseOnFailedBO && ((pos == 1 && sg.failBull) || (pos == -1 && sg.failBear)))
   {
      CloseAll();
      pos = CurrentPositionDir();
   }

   bool buyOK  = sg.buy  && TypeAllowed(sg.buyType);
   bool sellOK = sg.sell && TypeAllowed(sg.sellType);

   // Opposite confirmed signal (any type) closes the position
   if(InpCloseOnOpposite && pos == 1 && sg.sell)
   {
      CloseAll(); pos = CurrentPositionDir();
      if(!InpReverseOnOpposite) sellOK = false;
   }
   if(InpCloseOnOpposite && pos == -1 && sg.buy)
   {
      CloseAll(); pos = CurrentPositionDir();
      if(!InpReverseOnOpposite) buyOK = false;
   }

   if(pos != 0) return; // one position at a time

   if(buyOK)       OpenTrade( 1, sg.atr, TypeName(sg.buyType));
   else if(sellOK) OpenTrade(-1, sg.atr, TypeName(sg.sellType));
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_handle = iCustom(_Symbol, _Period, IND_NAME,
                      InpPivotLen, InpShowSwingBreaks,
                      InpRangeLookback, InpAtrLen, InpRangeAtrMult, InpMaxEfficiency,
                      InpBreakoutBufferATR, InpEnableRangeBreakouts,
                      InpMinBodyRatio, InpUsePressureFilter,
                      InpShowEarlyWarnings, InpShowConfirmedSignals, InpShowFailedBreakouts,
                      InpShowDashboard, InpShowPhaseBackground, InpAlerts, InpMaxBars);
   if(g_handle == INVALID_HANDLE)
   {
      PrintFormat("Cannot load indicator %s (error %d). Compile it into MQL5/Indicators first.", IND_NAME, GetLastError());
      return INIT_FAILED;
   }

   // Live chart: attach the indicator so its arrows and dashboard are visible.
   // (The Strategy Tester shows indicators created by the EA automatically.)
   if(InpShowIndicatorOnChart && !MQLInfoInteger(MQL_TESTER))
      g_addedToChart = ChartIndicatorAdd(0, 0, g_handle);

   if(_Period != PERIOD_M1 || StringFind(_Symbol, "XAU") < 0)
      Print("Note: logic was designed for XAUUSD M1; running on ", _Symbol, " ", EnumToString(_Period));

   g_lastBar = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_addedToChart)
      ChartIndicatorDelete(0, 0, IND_SHORTNAME);
   if(g_handle != INVALID_HANDLE)
      IndicatorRelease(g_handle);
}

//+------------------------------------------------------------------+
//| Tick: act once per newly closed candle                           |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime closedTime = iTime(_Symbol, _Period, 1);
   if(closedTime == 0 || closedTime == g_lastBar) return;

   BarSignals sg;
   if(!ReadSignals(1, sg)) return;   // indicator not ready for this bar yet; retry next tick

   if(g_lastBar == 0)
   {
      // First bar after start: sync only, never trade a candle that closed before the EA started
      g_lastBar = closedTime;
      return;
   }
   g_lastBar = closedTime;
   HandleTrading(sg);
}
//+------------------------------------------------------------------+
