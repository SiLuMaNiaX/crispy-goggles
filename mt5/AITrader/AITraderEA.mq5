//+------------------------------------------------------------------+
//|                                                  AITraderEA.mq5  |
//|  Full AI-driven pipeline for MT5, using WebRequest to call an    |
//|  OpenAI-compatible API (DeepSeek or OpenRouter):                 |
//|                                                                  |
//|   1. SCAN    - AI ranks a watchlist and picks candidate setups    |
//|   2. ENTRY   - AI decides direction, risk %, SL and TP per pick   |
//|   3. MANAGE  - AI decides HOLD / CLOSE / PARTIAL / MODIFY for     |
//|                every open position                               |
//|   4. CLOSE   - AI closes, plus hard closes from the guardrails    |
//|                                                                  |
//|  The AI proposes, the EA disposes: every AI output is validated  |
//|  against hard limits in the inputs before anything is sent.      |
//+------------------------------------------------------------------+
#property copyright "AITraderEA"
#property version   "2.00"

#include <Trade/Trade.mqh>
#include "AITraderKeys.mqh"   // optional compiled-in API keys (never printed in logs)

//+==================================================================+
//| CHART VISUALS (chart symbol only)                                 |
//|  key levels + Asian box + session lines, volume profile          |
//|  histogram, news windows, AI decision markers, closed trades      |
//+==================================================================+
#define VIZ_PREFIX "AITraderViz_"
#define VZ_PDHL    C'80,150,255'
#define VZ_WEEK    C'170,110,255'
#define VZ_OPEN    C'130,130,130'
#define VZ_LDN     C'0,190,170'
#define VZ_NY      C'255,150,60'
#define VZ_ROUND   C'75,75,75'
#define VZ_ASIA    C'20,28,46'
#define VZ_POC     C'255,200,60'
#define VZ_VA      C'60,100,160'
#define VZ_VPOUT   C'40,48,66'
#define VZ_NEWS    C'255,90,60'
#define VZ_NEWSBG  C'45,18,18'

datetime g_vizLast = 0;
string   g_vizMarkers[];
int      g_vizSeq = 0;


// Dashboard panel
#define PANEL_PREFIX "AITraderPanel_"
#define CLR_PANEL_BG     C'16,20,28'
#define CLR_PANEL_BORDER C'60,72,96'
#define CLR_TITLE        C'0,190,255'
#define CLR_HEAD         C'130,140,160'
#define CLR_TEXT         C'225,228,235'
#define CLR_GOOD         C'60,200,120'
#define CLR_BAD          C'240,80,80'
#define CLR_WARN         C'255,190,60'

enum ENUM_REVIEW_MODE
  {
   REVIEW_OFF    = 0, // Off - entry model decides alone
   REVIEW_SHADOW = 1, // Shadow - 2nd model's verdict is logged, never blocks
   REVIEW_VETO   = 2  // Veto - 2nd model must agree
  };

enum ENUM_TRADE_MODE
  {
   MODE_SUPERSCALP = 0, // Superscalping (M1, minutes)
   MODE_SCALP      = 1, // Scalping (M5, < 3 h)
   MODE_INTRADAY   = 2, // Intraday (M15, same day)
   MODE_SWING      = 3, // Swing (H4, days)
   MODE_CUSTOM     = 4  // Custom (use the "Custom mode" inputs)
  };

enum ENUM_SESSION_BIAS
  {
   SESSION_NONE         = 0, // No session bias (server-hour window)
   SESSION_ASIAN        = 1, // Asian (Tokyo 09-17)
   SESSION_LONDON       = 2, // London (London 08-17, DST-aware)
   SESSION_NY           = 3, // New York (New York 08-17, DST-aware)
   SESSION_LONDON_NY    = 4, // London open -> NY close
   SESSION_ASIAN_LONDON = 5, // Tokyo open -> London close
   SESSION_NY_ASIAN     = 6  // NY open -> Tokyo close (overnight)
  };

enum ENUM_RISK_PROFILE
  {
   PROFILE_CONSERVATIVE = 0, // Conservative (capital first)
   PROFILE_BALANCED     = 1, // Balanced (inputs as set)
   PROFILE_AGGRESSIVE   = 2  // Aggressive (more trades, more risk)
  };

//=== Inputs ==========================================================
input group "STRATEGY PROFILE"
input ENUM_TRADE_MODE   InpTradeMode      = MODE_INTRADAY;           // Trading mode
input ENUM_SESSION_BIAS InpSession        = SESSION_NONE;            // Session bias
input ENUM_RISK_PROFILE InpRiskProfile    = PROFILE_CONSERVATIVE;    // Risk profile
input bool              InpCloseAtSessionEnd = true;                 // Non-swing modes: close positions when the session ends

// Each job (entry, scan, manage, review) has its own ordered provider list; the next one is tried when one fails.
// A provider that fails is skipped for InpFailoverCooldownMin minutes.
input group "AI provider 1 - PRIMARY (asAi, OpenAI-compatible)"
input bool             InpP1Enabled       = true;                    // Enabled
input string           InpP1Name          = "asAi";                  // Name (for logs)
input string           InpP1Url           = "https://serveras.click/v1/chat/completions"; // Chat completions URL
input string           InpP1Key           = "";                      // API key - LEAVE EMPTY (inputs are printed in logs)
input string           InpP1KeyFile       = "aitrader_key_asai.txt"; // Key file in <Common>\Files
input string           InpP1Model         = "asai/gpt-6.2-astra";    // Model id (copy from asAi > Models)
input string           InpModelEntry      = "";                      // Primary model for ENTRY (empty = Model id)
input string           InpModelManage     = "";                      // Primary model for MANAGE (empty = Model id)

input group "AI provider 2 - DeepSeek (shadow reviewer, backup, manager)"
input bool             InpP2Enabled       = true;                    // Enabled
input string           InpP2Key           = "";                      // API key - LEAVE EMPTY (inputs are printed in logs)
input string           InpP2KeyFile       = "aitrader_key_deepseek.txt"; // Key file in <Common>\Files
input string           InpP2Model         = "deepseek-chat";         // Model

input group "AI provider 3 - OpenRouter (optional extra backup)"
input bool             InpP3Enabled       = true;                    // Enabled
input string           InpP3Key           = "";                      // API key - LEAVE EMPTY (inputs are printed in logs)
input string           InpP3KeyFile       = "aitrader_key_openrouter.txt"; // Key file in <Common>\Files
input string           InpP3Model         = "";                      // Model slug (empty = off)

input group "Who does what (provider names, tried in order)"
input string           InpChainEntry      = "asAi,DeepSeek";         // ENTRY decision (trades)
input string           InpChainManage     = "DeepSeek,asAi";         // MANAGE open positions
input ENUM_REVIEW_MODE InpReviewMode      = REVIEW_SHADOW;           // 2nd-opinion mode
input string           InpChainReview     = "DeepSeek,OpenRouter";   // 2nd-opinion reviewer (never the entry provider)

input group "AI request settings"
input int              InpFailoverCooldownMin = 10;                  // Skip a failed provider for N minutes
input double           InpTemperature     = 0.2;                     // Temperature
input int              InpMaxTokens       = 600;                     // Max response tokens
input bool             InpJsonMode        = true;                    // Request JSON response_format
input int              InpTimeoutMs       = 45000;                   // HTTP timeout per provider (ms)
input int              InpMaxAICallsDay   = 0;                       // Max AI calls per day (0 = mode default)

input group "Symbols"
input string           InpSymbols         = "XAUUSD";                // Watchlist (comma separated; broker suffix added automatically)
input ENUM_TIMEFRAMES  InpTimeframe       = PERIOD_H1;               // [Custom] Scan/entry timeframe
input int              InpBarsForAI       = 40;                      // [Custom] Bars sent per symbol
input int              InpStartHour       = 1;                       // [No session bias] Entries from (server hour)
input int              InpEndHour         = 21;                      // [No session bias] Entries until (server hour)

input group "Position management"
input ENUM_TIMEFRAMES  InpManageTF        = PERIOD_M15;              // [Custom] Manage timeframe
input double           InpMinManageConf   = 0.6;                     // [Balanced] Min AI confidence for management
input double           InpBreakevenR      = 0.0;                     // Mechanical breakeven at R (0 = leave to AI)
input bool             InpTrailEnabled    = true;                    // Trailing stop (mechanical, ATR-based)
input double           InpTrailStartR     = 1.0;                     //    Start trailing once profit reaches N x initial risk (R)
input double           InpTrailAtr        = 1.0;                     //    Keep the stop N x ATR behind price
input double           InpTrailStepAtr    = 0.1;                     //    Move only when it improves by N x ATR
input int              InpMaxHoldHours    = 48;                      // [Custom] Hard close after N hours (0 = off)
input int              InpFridayCloseHour = 20;                      // Friday: close all & stop from this hour (0 = off)
input bool             InpSwingHoldWeekend= true;                    // Swing mode: allow holding over the weekend

input group "Hard risk limits (AI cannot override)"
input bool             InpDryRun          = true;                    // Dry run: log only, send NO orders
input double           InpMaxRiskPct      = 1.0;                     // [Balanced] Risk per trade (% equity)
input double           InpRiskCeilingPct  = 2.0;                     // Absolute ceiling per trade, any profile (%)
input double           InpMaxTotalRiskPct = 3.0;                     // Max total open risk (% equity)
input double           InpMinConfidence   = 0.65;                    // [Balanced] Min AI confidence to enter
input double           InpMinRR           = 1.5;                     // [Custom] Min reward:risk at entry
input double           InpMinSlAtr        = 0.5;                     // [Custom] Min SL distance (x ATR)
input double           InpMaxSlAtr        = 3.0;                     // [Custom] Max SL distance (x ATR)
input int              InpMaxPositions    = 3;                       // [Balanced] Max open positions
input int              InpMaxPerSymbol    = 3;                       // Max trades per symbol (open positions + pending orders)
input bool             InpNoAveragingDown = true;                    // Same-direction add only if existing trades are in profit
input bool             InpAllowOpposite   = false;                   // Allow a trade opposite to an open position (hedge)
input bool             InpStructureFilter = true;                    // Block trades against the decision-timeframe swing structure
input int              InpMaxTradesDay    = 6;                       // [Custom] Max new trades per day
input double           InpMaxDailyLossPct = 3.0;                     // Daily equity drawdown limit (%)
input bool             InpCloseOnDailyLoss= true;                    // Close all positions when daily limit hit
input double           InpMaxSpreadAtr    = 0.15;                    // [Custom] Max spread as fraction of ATR

input group "Misc"
input ulong            InpMagic           = 26112501;                // Magic number
input int              InpSlippagePts     = 30;                      // Max slippage (points)
input int              InpTimerSec        = 0;                       // Timer interval seconds (0 = mode default)
input string           InpLogFile         = "AITraderEA_log.csv";    // Log file in MQL5\Files

input group "Pending orders"
input bool             InpAllowPending    = true;                    // AI may use LIMIT / STOP orders (e.g. "sell the retest at X")
input double           InpPendingMaxAtr   = 1.5;                     // Max distance of a pending entry from price (x ATR)
input int              InpPendingExpiryMin= 0;                       // Max pending lifetime in minutes (0 = mode default)

input group "Market context & news (fed to the AI)"
input bool             InpNewsFilter      = true;                    // 1. Block entries around economic news
input string           InpNewsCurrencies  = "USD";                   //    News currencies (comma separated)
input int              InpNewsMinImportance = 3;                     //    Min importance (3 = high, 2 = moderate+)
input int              InpNewsBeforeMin   = 30;                      //    Block entries N min before an event
input int              InpNewsAfterMin    = 15;                      //    ...and N min after
input bool             InpNewsClosePositions = false;                //    Also close open positions in the news window
input bool             InpKeyLevels       = true;                    // 3. Key levels (prev day/week, Asian range, session opens, round numbers)
input bool             InpHTFContext      = true;                    // 4. Higher-timeframe trend & structure
input bool             InpVolumeProfile   = true;                    // 5. Volume profile POC / value area (tick volume)
input bool             InpTickFlow        = true;                    // 6. Tick-flow proxy (quote up/down ticks)
input bool             InpSelfReview      = true;                    // 7. Show the AI its own recent trades
input int              InpSelfReviewTrades= 10;                      //    How many recent trades to show
input datetime         InpStatsFrom       = 0;                       // 2. Performance stats from (0 = all history)

input group "Chart visuals (chart symbol)"
input bool             InpVizLevels       = true;                    // Key levels (PDH/PDL, week, session opens, round numbers)
input bool             InpVizAsianBox     = true;                    // Asian range box
input bool             InpVizProfile      = true;                    // Today's volume profile histogram (right side)
input bool             InpVizNews         = true;                    // News lines + no-entry windows
input bool             InpVizDecisions    = true;                    // AI decision markers (hover for the reason)
input bool             InpVizTrades       = true;                    // Closed trades (entry -> exit, P/L)
input int              InpVizMaxMarkers   = 150;                     // Max decision markers kept on the chart

input group "Dashboard panel"
input bool             InpShowPanel       = true;                    // Show dashboard panel
input int              InpPanelX          = 8;                       // Panel X offset (px from left)
input int              InpPanelY          = 100;                     // Panel Y offset (px from top; clears one-click trading)
input int              InpPanelFontSize   = 9;                       // Panel font size
input int              InpPanelWrapChars  = 63;                      // Wrap long lines after N characters (MT5 max 63)

//=== Types ===========================================================
struct EntryDecision
  {
   string            action;     // BUY / SELL / HOLD
   string            order;      // MARKET / LIMIT / STOP
   double            entry;      // pending entry price
   int               expiryMin;  // pending lifetime
   string            shadow;     // reviewer verdict: A agree, D disagree, N n/a, "" not reviewed
   double            confidence;
   double            risk_pct;
   double            sl;
   double            tp;
   string            reason;
  };

struct ManageDecision
  {
   string            action;     // HOLD / CLOSE / PARTIAL / MODIFY
   double            confidence;
   double            new_sl;
   double            new_tp;
   double            close_fraction;
   string            reason;
  };

struct AIProvider
  {
   string            name;
   string            url;
   string            key;
   string            model;
   bool              openrouter;
   datetime          downUntil;  // skipped until this time after a failure
  };

struct RuntimeConfig
  {
   ENUM_TRADE_MODE   mode;
   ENUM_TIMEFRAMES   scanTF;
   ENUM_TIMEFRAMES   manageTF;
   int               bars;
   int               maxHoldMin;
   int               maxTradesDay;
   int               maxPositions;
   int               timerSec;
   int               maxCalls;
   double            slMin;
   double            slMax;
   double            minRR;
   double            maxSpreadAtr;
   double            riskPct;
   double            minConf;
   double            minManageConf;
   int               pendingExpiryMin;
   bool              fridayClose;
   string            styleText;
   string            profileText;
   string            sessionText;
  };

struct NewsItem
  {
   datetime          t;
   string            name;
   string            cur;
   int               imp;
  };

struct ClosedTrade
  {
   ulong             posId;
   string            sym;
   int               dir;
   datetime          openTime;
   datetime          closeTime;
   double            openPrice;
   double            closePrice;
   double            volume;
   double            net;
   double            sl;
   double            rMult;
   string            exitReason;
   string            shadow;      // A / D / N / "" from the entry comment
  };

//=== Globals =========================================================
RuntimeConfig g_cfg;
string        g_sizingText = "";
int           g_sizingState = -1;   // -1 unknown, 0 cannot trade, 1 partial, 2 ok
datetime      g_sizingAt = 0;
NewsItem      g_news[];
datetime      g_newsLoaded = 0;
bool          g_newsWarned = false;
ClosedTrade   g_trades[];
datetime      g_tradesLoaded = 0;
bool          g_tradesDirty = true;

CTrade   g_trade;
AIProvider g_prov[];
string   g_lastProvider = "-";
string   g_scanSkipped = "";
string   g_syms[];
int      g_hATR[], g_hRSI[], g_hE20[], g_hE50[], g_hE200[];
datetime g_lastScanBar = 0, g_lastManageBar = 0, g_day = 0;
int      g_calls = 0;
bool     g_haltedToday = false;
string   g_lastScan = "-", g_lastEvent = "-";

//+------------------------------------------------------------------+
int OnInit()
  {
   // Globals survive an input change / timeframe switch (OnDeinit+OnInit without unloading),
   // so reset everything that OnInit appends to or caches.
   ArrayResize(g_prov, 0);
   ArrayResize(g_syms, 0);
   g_lastProvider = "-"; g_lastScan = "-"; g_lastEvent = "-"; g_scanSkipped = "";
   g_newsLoaded = 0; g_tradesDirty = true; ArrayResize(g_news, 0); ArrayResize(g_trades, 0);
   g_vizLast = 0; ArrayResize(g_vizMarkers, 0);
   g_sizingText = ""; g_sizingState = -1; g_sizingAt = 0;
   AddProvider(InpP1Enabled, InpP1Name, InpP1Url, InpP1Key, AITRADER_KEY_ASAI, InpP1KeyFile, InpP1Model, false);
   AddProvider(InpP2Enabled, "DeepSeek", "https://api.deepseek.com/chat/completions", InpP2Key, AITRADER_KEY_DEEPSEEK, InpP2KeyFile, InpP2Model, false);
   AddProvider(InpP3Enabled && InpP3Model != "", "OpenRouter", "https://openrouter.ai/api/v1/chat/completions", InpP3Key, AITRADER_KEY_OPENROUTER, InpP3KeyFile, InpP3Model, true);
   if(ArraySize(g_prov) == 0)
     {
      Print("AITrader: no usable AI provider (enable one and give it a key or key file)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!BuildConfig())
      return INIT_PARAMETERS_INCORRECT;
   if(!LoadSymbols())
      return INIT_FAILED;

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePts);

   if(MQLInfoInteger(MQL_TESTER))
      Print("AITrader: WebRequest is unavailable in the Strategy Tester; the EA will idle there.");

   g_lastScanBar   = iTime(_Symbol, g_cfg.scanTF, 0); // first scan on the next bar
   g_lastManageBar = iTime(_Symbol, g_cfg.manageTF, 0);
   EventSetTimer(g_cfg.timerSec);
   SetupChartForVisuals();
   PrintFormat("AITrader started: %s | %s session | %s | %d symbols | scan %s manage %s | risk %.2f%% | providers %s | dry run %s",
               ModeName(), SessionName(), ProfileName(), ArraySize(g_syms), TfName(g_cfg.scanTF), TfName(g_cfg.manageTF),
               g_cfg.riskPct, ProviderChain(), InpDryRun ? "ON" : "OFF");
   UpdateDashboard();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      IndicatorRelease(g_hATR[i]); IndicatorRelease(g_hRSI[i]);
      IndicatorRelease(g_hE20[i]); IndicatorRelease(g_hE50[i]); IndicatorRelease(g_hE200[i]);
     }
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ObjectsDeleteAll(0, VIZ_PREFIX);
   Comment("");
  }

void OnTick()
  {
   if(!AlgoTradingOn()) return;
   if(InpBreakevenR > 0) MechanicalBreakeven();
   if(InpTrailEnabled) TrailingStops();
  }

//+------------------------------------------------------------------+
//| Main loop                                                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(MQLInfoInteger(MQL_TESTER)) return;
   RollDay();

   // Algo Trading off (toolbar button, EA checkbox, or this copy was moved to the MQL5 VPS):
   // stay idle so a second copy does not spend API calls.
   LoadNews();
   bool tradesChanged = g_tradesDirty;
   LoadTrades();
   DrawVisuals(tradesChanged);
   if(g_sizingAt == 0 || TimeCurrent() - g_sizingAt >= 3600) RunSizingCheck();
   if(!AlgoTradingOn()) { UpdateDashboard(); return; }

   // 1. Hard rules first (no AI needed)
   EnforceHardRules();
   if(InpTrailEnabled) TrailingStops();

   // 2. AI position management on each new manage bar
   datetime mBar = iTime(_Symbol, g_cfg.manageTF, 0);
   if(mBar != 0 && mBar != g_lastManageBar)
     {
      g_lastManageBar = mBar;
      ManagePositions();
     }

   // 3. AI entry check on each new decision bar
   datetime sBar = iTime(_Symbol, g_cfg.scanTF, 0);
   if(sBar != 0 && sBar != g_lastScanBar)
     {
      g_lastScanBar = sBar;
      ScanAndEnter();
     }
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| STRATEGY PROFILE: mode x session x risk profile -> g_cfg          |
//+------------------------------------------------------------------+
bool BuildConfig()
  {
   if(InpMaxRiskPct <= 0 || InpRiskCeilingPct <= 0 || InpRiskCeilingPct > 5 || InpMaxTotalRiskPct <= 0)
     {
      Print("AITrader: risk inputs invalid (risk > 0, 0 < ceiling <= 5, total risk > 0)");
      return false;
     }
   g_cfg.mode = InpTradeMode;

   //--- trading mode presets ---------------------------------------
   //                 scanTF      manageTF    bars slMin slMax  RR  holdMin spread trades timer calls
   switch(InpTradeMode)
     {
      case MODE_SUPERSCALP:
         SetMode(PERIOD_M1,  PERIOD_M1,  60, 0.5, 1.5, 1.0,    30, 0.30, 30,  3, 1500,
                 "SUPERSCALPING: trades last 1-30 minutes on M1. Only take immediate momentum or micro-pullback "
                 "entries with tight stops; spread and fees matter a lot. Exit fast: never let a winner turn into a "
                 "loser, close stalled trades within a few bars.");
         break;
      case MODE_SCALP:
         SetMode(PERIOD_M5,  PERIOD_M1,  60, 0.6, 2.0, 1.2,   180, 0.20, 15,  5,  600,
                 "SCALPING: trades last minutes to ~3 hours on M5. Trade with the short-term momentum and M5/M15 "
                 "structure, quick partial profits, move SL to breakeven early, close if momentum fades.");
         break;
      case MODE_SWING:
         SetMode(PERIOD_H4,  PERIOD_H1,  60, 1.0, 3.5, 2.0, 14400, 0.10,  3, 30,   80,
                 "SWING: trades last days to two weeks on H4. Trade with the daily/H4 trend at key levels, wide "
                 "structural stops, big targets; ignore intraday noise and manage only on H4 structure changes.");
         break;
      case MODE_CUSTOM:
         SetMode(InpTimeframe, InpManageTF, InpBarsForAI, InpMinSlAtr, InpMaxSlAtr, InpMinRR, InpMaxHoldHours * 60,
                 InpMaxSpreadAtr, InpMaxTradesDay, 15, 150,
                 StringFormat("CUSTOM: decisions on %s, management on %s.", TfName(InpTimeframe), TfName(InpManageTF)));
         break;
      default: // MODE_INTRADAY
         SetMode(PERIOD_M15, PERIOD_M5,  48, 0.7, 2.5, 1.5,   720, 0.15,  6, 10,  300,
                 "INTRADAY: trades open and close within the same day on M15, using H1 trend and the day's key "
                 "levels (previous day high/low, session highs/lows). Flat by the end of the session.");
         break;
     }
   g_cfg.fridayClose = !(InpTradeMode == MODE_SWING && InpSwingHoldWeekend);
   int expDefault[] = {15, 45, 240, 1440, 120};          // superscalp, scalp, intraday, swing, custom
   g_cfg.pendingExpiryMin = InpPendingExpiryMin > 0 ? InpPendingExpiryMin : expDefault[(int)InpTradeMode];
   if(InpTimerSec > 0)      g_cfg.timerSec = (int)MathMax(2, InpTimerSec);
   if(InpMaxAICallsDay > 0) g_cfg.maxCalls = InpMaxAICallsDay;

   //--- risk profile (Balanced = inputs as set) -----------------------
   double riskMult = 1.0, tradesMult = 1.0;
   g_cfg.minConf         = InpMinConfidence;
   g_cfg.minManageConf   = InpMinManageConf;
   g_cfg.maxPositions    = InpMaxPositions;
   switch(InpRiskProfile)
     {
      case PROFILE_CONSERVATIVE:
         riskMult = 0.75; tradesMult = 0.6;
         g_cfg.minConf = MathMax(g_cfg.minConf, 0.72);       g_cfg.minRR += 0.3;
         g_cfg.minManageConf = MathMax(g_cfg.minManageConf, 0.70);
         g_cfg.maxPositions = (int)MathMin(g_cfg.maxPositions, 2);
         g_cfg.profileText = "CONSERVATIVE: capital preservation first. Only trend-aligned, high-probability setups; "
                             "lower risk when uncertain; take partial profits and move SL to breakeven early.";
         break;
      case PROFILE_AGGRESSIVE:
         riskMult = 1.5; tradesMult = 1.5;
         g_cfg.minConf = MathMin(g_cfg.minConf, 0.60);       g_cfg.minRR = MathMax(1.0, g_cfg.minRR - 0.3);
         g_cfg.maxPositions += 2;
         g_cfg.profileText = "AGGRESSIVE: take more opportunities including momentum breakouts and well-defined "
                             "counter-trend fades; use the upper part of the risk range on strong setups; let "
                             "winners run with trailing stops. Never average down.";
         break;
      default:
         g_cfg.profileText = "BALANCED: take clear setups with good reward:risk; size risk to setup quality.";
         break;
     }
   g_cfg.riskPct      = MathMin(InpMaxRiskPct * riskMult, InpRiskCeilingPct);
   g_cfg.riskPct      = MathMin(g_cfg.riskPct, InpMaxTotalRiskPct);
   g_cfg.maxTradesDay = (int)MathMax(1, MathRound(g_cfg.maxTradesDay * tradesMult));

   //--- session bias (windows are computed live in SessionWindow, DST-aware) ---
   switch(InpSession)
     {
      case SESSION_ASIAN:        g_cfg.sessionText = "ASIAN (Tokyo 09:00-17:00): usually range-bound and thinner. Favour JPY, AUD, NZD and XAU; fade range extremes, distrust breakouts."; break;
      case SESSION_LONDON:       g_cfg.sessionText = "LONDON (08:00-17:00 London time): highest FX volume. Favour EUR, GBP, CHF and XAU; breakouts of the Asian range at the London open are common."; break;
      case SESSION_NY:           g_cfg.sessionText = "NEW YORK (08:00-17:00 New York time): favour USD pairs, XAU and US indices. US data at 08:30-10:00 New York time causes spikes; momentum often fades after midday New York."; break;
      case SESSION_LONDON_NY:    g_cfg.sessionText = "LONDON + NEW YORK (London open to New York close): the most liquid hours. The London-NY overlap gives the strongest moves; favour EUR, GBP, USD pairs and XAU."; break;
      case SESSION_ASIAN_LONDON: g_cfg.sessionText = "ASIAN + LONDON (Tokyo open to London close): the Asian range forms first, then London often breaks it. Favour JPY/AUD in Asia, EUR/GBP/XAU from the London open."; break;
      case SESSION_NY_ASIAN:     g_cfg.sessionText = "NEW YORK + ASIAN (New York open to Tokyo close, overnight): NY momentum then quieter Asian trade. Avoid the daily rollover (17:00 New York) when spreads widen."; break;
      default:                   g_cfg.sessionText = "No session bias: trade any liquid hour in the allowed window."; break;
     }
   return true;
  }

void SetMode(ENUM_TIMEFRAMES scan, ENUM_TIMEFRAMES manage, int bars, double slMin, double slMax, double rr,
             int holdMin, double spreadAtr, int trades, int timer, int calls, string text)
  {
   g_cfg.scanTF = scan;        g_cfg.manageTF = manage;   g_cfg.bars = bars;
   g_cfg.slMin = slMin;        g_cfg.slMax = slMax;       g_cfg.minRR = rr;
   g_cfg.maxHoldMin = holdMin; g_cfg.maxSpreadAtr = spreadAtr;
   g_cfg.maxTradesDay = trades; g_cfg.timerSec = timer;   g_cfg.maxCalls = calls;
   g_cfg.styleText = text;
  }

//+------------------------------------------------------------------+
//| Sessions in each centre's LOCAL time, converted to GMT each day:  |
//|   Tokyo    09:00-17:00 JST (UTC+9, no DST)       -> 00:00-08:00   |
//|   London   08:00-17:00 GMT/BST (UK DST rules)    -> 08-17 / 07-16 |
//|   New York 08:00-17:00 EST/EDT (US DST rules)    -> 13-22 / 12-21 |
//| UK DST: last Sunday Mar 01:00 UTC -> last Sunday Oct 01:00 UTC.   |
//| US DST: 2nd Sunday Mar 07:00 UTC -> 1st Sunday Nov 06:00 UTC.     |
//| During the 2-3 weeks a year when the US and UK are out of step,   |
//| each session still follows its own city.                          |
//+------------------------------------------------------------------+
datetime UtcDate(int y, int m, int d, int h)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = y; t.mon = m; t.day = d; t.hour = h;
   return StructToTime(t);
  }

int DayOfWeek(int y, int m, int d)
  {
   MqlDateTime t;
   TimeToStruct(UtcDate(y, m, d, 0), t);
   return t.day_of_week; // 0 = Sunday
  }

datetime NthSunday(int y, int m, int n, int hourUtc)
  {
   int first = 1 + (7 - DayOfWeek(y, m, 1)) % 7;
   return UtcDate(y, m, first + 7 * (n - 1), hourUtc);
  }

datetime LastSunday(int y, int m, int hourUtc) // March and October have 31 days
  {
   return UtcDate(y, m, 31 - DayOfWeek(y, m, 31), hourUtc);
  }

bool UkDst(datetime utc)
  {
   MqlDateTime t; TimeToStruct(utc, t);
   return utc >= LastSunday(t.year, 3, 1) && utc < LastSunday(t.year, 10, 1);
  }

bool UsDst(datetime utc)
  {
   MqlDateTime t; TimeToStruct(utc, t);
   return utc >= NthSunday(t.year, 3, 2, 7) && utc < NthSunday(t.year, 11, 1, 6);
  }

int LondonOffsetMin(datetime utc) { return UkDst(utc) ? 60 : 0; }
int NewYorkOffsetMin(datetime utc) { return UsDst(utc) ? -240 : -300; }

// Window in minutes of the day; GMT for sessions, server time for "no session bias".
void SessionWindow(int &startMin, int &endMin)
  {
   datetime now = TimeGMT();
   int tkO = 0,                                   tkC = 8 * 60;                          // Tokyo 09-17 JST
   int lnO = 8 * 60 - LondonOffsetMin(now),       lnC = 17 * 60 - LondonOffsetMin(now);  // London 08-17 local
   int nyO = 8 * 60 - NewYorkOffsetMin(now),      nyC = 17 * 60 - NewYorkOffsetMin(now); // New York 08-17 local
   switch(InpSession)
     {
      case SESSION_ASIAN:        startMin = tkO; endMin = tkC; break;
      case SESSION_LONDON:       startMin = lnO; endMin = lnC; break;
      case SESSION_NY:           startMin = nyO; endMin = nyC; break;
      case SESSION_LONDON_NY:    startMin = lnO; endMin = nyC; break;
      case SESSION_ASIAN_LONDON: startMin = tkO; endMin = lnC; break;
      case SESSION_NY_ASIAN:     startMin = nyO; endMin = tkC; break; // wraps midnight
      default:                   startMin = InpStartHour * 60; endMin = InpEndHour * 60; break;
     }
   startMin = ((startMin % 1440) + 1440) % 1440;
   endMin   = ((endMin % 1440) + 1440) % 1440;
  }

bool InSession()
  {
   int s, e;
   SessionWindow(s, e);
   MqlDateTime t;
   TimeToStruct(InpSession == SESSION_NONE ? TimeCurrent() : TimeGMT(), t);
   int m = t.hour * 60 + t.min;
   if(s == e) return true;
   return s < e ? (m >= s && m < e) : (m >= s || m < e); // window may wrap midnight
  }

string HhMm(int minutes) { return StringFormat("%02d:%02d", minutes / 60, minutes % 60); }

string SessionWindowText()
  {
   int s, e;
   SessionWindow(s, e);
   return HhMm(s) + "-" + HhMm(e) + (InpSession == SESSION_NONE ? " server" : " GMT");
  }

string LocalClocks()
  {
   datetime now = TimeGMT();
   MqlDateTime g, l, n, k;
   TimeToStruct(now, g);
   TimeToStruct(now + LondonOffsetMin(now) * 60, l);
   TimeToStruct(now + NewYorkOffsetMin(now) * 60, n);
   TimeToStruct(now + 9 * 3600, k);
   return StringFormat("%02d:%02d GMT | London %02d:%02d %s | New York %02d:%02d %s | Tokyo %02d:%02d JST",
                       g.hour, g.min, l.hour, l.min, UkDst(now) ? "BST" : "GMT",
                       n.hour, n.min, UsDst(now) ? "EDT" : "EST", k.hour, k.min);
  }

string ModeName()
  {
   string n[] = {"Superscalping", "Scalping", "Intraday", "Swing", "Custom"};
   return n[(int)InpTradeMode];
  }
string SessionName()
  {
   string n[] = {"Any", "Asian", "London", "New York", "London-NY", "Asian-London", "NY-Asian"};
   return n[(int)InpSession];
  }
string ProfileName()
  {
   string n[] = {"Conservative", "Balanced", "Aggressive"};
   return n[(int)InpRiskProfile];
  }

// Prepended to every AI system prompt so all stages share the same style.
string ProfileBrief()
  {
   return StringFormat("TRADING STYLE - %s RISK PROFILE - %s SESSION - %s Today's window: %s. Time now: %s. "
                       "Risk per trade is capped at %.2f%% of equity; minimum reward:risk %.1f.",
                       g_cfg.styleText, g_cfg.profileText, g_cfg.sessionText, SessionWindowText(), LocalClocks(),
                       g_cfg.riskPct, g_cfg.minRR);
  }

//+------------------------------------------------------------------+
//| HARD RULES                                                        |
//+------------------------------------------------------------------+
void EnforceHardRules()
  {
   double dayEq = DayStartEquity(), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = dayEq > 0 ? (dayEq - eq) / dayEq * 100.0 : 0.0;
   if(ddPct >= InpMaxDailyLossPct && !g_haltedToday)
     {
      g_haltedToday = true;
      Notify(StringFormat("DAILY LOSS LIMIT %.2f%% hit - entries halted", ddPct));
      if(InpCloseOnDailyLoss) CloseAll("daily loss limit");
     }

   ExpirePendings();
   if((g_haltedToday || IsFridayClose()) && CountPendings() > 0) CancelPendings(g_haltedToday ? "daily loss limit" : "Friday close");
   string newsP;
   if(CountPendings() > 0 && NewsBlocked(newsP)) CancelPendings("news window: " + newsP);
   if(InpCloseAtSessionEnd && g_cfg.mode != MODE_SWING && !InSession() && CountPendings() > 0)
      CancelPendings(SessionName() + " session ended");

   if(IsFridayClose() && CountPositions() > 0)
      CloseAll("Friday close");

   string newsNow;
   if(InpNewsClosePositions && CountPositions() > 0 && NewsBlocked(newsNow))
      CloseAll("news window: " + newsNow);

   if(InpCloseAtSessionEnd && g_cfg.mode != MODE_SWING && !InSession() && CountPositions() > 0)
      CloseAll(SessionName() + " session ended");

   if(g_cfg.maxHoldMin > 0)
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(!IsOurs(t)) continue;
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         if(TimeCurrent() - opened >= (long)g_cfg.maxHoldMin * 60)
            ClosePosition(t, "max hold time");
        }
  }

bool IsFridayClose()
  {
   if(InpFridayCloseHour <= 0 || !g_cfg.fridayClose) return false;
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   return t.day_of_week == 5 && t.hour >= InpFridayCloseHour;
  }

//+------------------------------------------------------------------+
//| ENTRY CHECK: every tradeable symbol goes straight to the entry AI |
//+------------------------------------------------------------------+
void ScanAndEnter()
  {
   string why = "";
   if(!EntryAllowed(why))
     { g_lastScan = "skipped: " + why; Print("AITrader: entry check ", g_lastScan); return; }

   g_scanSkipped = "";
   int tradeable = 0;
   g_lastScan = "checked: ";
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      if(ScanRow(i) == "") continue;              // no data, market closed, or spread too wide vs ATR
      tradeable++;
      if(SymbolExposure(g_syms[i]) >= MathMax(1, InpMaxPerSymbol)) continue;
      if(!EntryAllowed(why)) { Print("AITrader: stop entries - ", why); break; }
      g_lastScan += g_syms[i] + " ";
      PrintFormat("AITrader: entry check %s", g_syms[i]);
      EvaluateEntry(i, "ANY", 0, "");
     }
   if(g_scanSkipped != "")
      PrintFormat("AITrader: spread > %.2f ATR, not checked: %s", g_cfg.maxSpreadAtr, g_scanSkipped);
   if(tradeable == 0) g_lastScan = "nothing tradeable (spread too wide, market closed or no data)";
  }

bool EntryAllowed(string &why)
  {
   if(g_haltedToday)                                  { why = "daily loss limit"; return false; }
   string news;
   if(NewsBlocked(news))                              { why = "news window: " + news; return false; }
   if(IsFridayClose())                                { why = "Friday close window"; return false; }
   if(!InSession())                                   { why = "outside " + SessionName() + " session"; return false; }
   if(CountPositions() + CountPendings() >= g_cfg.maxPositions) { why = "max positions (incl. pending orders)"; return false; }
   if(CountTodayEntries() >= g_cfg.maxTradesDay)         { why = "max trades today"; return false; }
   if(OpenRiskPct() >= InpMaxTotalRiskPct - 0.01)     { why = "total open risk cap"; return false; }
   if(g_calls >= g_cfg.maxCalls)                    { why = "AI call budget"; return false; }
   if(!InpDryRun && (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)))
                                                      { why = "algo trading disabled in terminal/EA"; return false; }
   return true;
  }

string ScanRow(int i)
  {
   string sym = g_syms[i];
   if(!SymbolTradable(sym)) return "";
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(sym, g_cfg.scanTF, 1, 50, r) < 50) return "";
   double atr = Buf(g_hATR[i]), rsi = Buf(g_hRSI[i]);
   double e20 = Buf(g_hE20[i]), e50 = Buf(g_hE50[i]), e200 = Buf(g_hE200[i]);
   if(atr <= 0) return "";
   double px = SymbolInfoDouble(sym, SYMBOL_BID);
   double hi = r[0].high, lo = r[0].low;
   for(int k = 1; k < 50; k++) { hi = MathMax(hi, r[k].high); lo = MathMin(lo, r[k].low); }
   double chg = (r[23].close > 0) ? (r[0].close - r[23].close) / r[23].close * 100.0 : 0.0;
   string trend = (e20 > e50 && e50 > e200) ? "UP" : (e20 < e50 && e50 < e200) ? "DOWN" : "MIXED";
   double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - px;
   if(!HasPosition(sym) && spread / atr > g_cfg.maxSpreadAtr)
     {
      g_scanSkipped += StringFormat("%s(%.2f) ", sym, spread / atr);
      return "";                      // untradeable now: keep it out of the AI's choices
     }
   int dg = SymDigits(sym);
   return StringFormat("%s,%s,%.2f,%.3f,%.1f,%s,%.0f,%.3f,%s", sym, DoubleToString(px, dg), chg,
                       atr / px * 100.0, rsi, trend, hi > lo ? (px - lo) / (hi - lo) * 100.0 : 50.0,
                       spread / atr, HasPosition(sym) ? "yes" : "no");
  }

void EvaluateEntry(int idx, string bias, double score, string note)
  {
   string sym = g_syms[idx];
   double atr = Buf(g_hATR[idx]);
   double spread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   if(atr <= 0 || spread / atr > g_cfg.maxSpreadAtr)
     { Print("AITrader: ", sym, " spread too wide vs ATR"); return; }

   double remaining = MathMin(g_cfg.riskPct, InpMaxTotalRiskPct - OpenRiskPct());
   string intro = (bias == "ANY")
      ? StringFormat("You are a disciplined trader and risk manager watching %s. Judge the data yourself and consider "
                     "BUY and SELL equally. ", sym)
      : StringFormat("You are a disciplined trader and risk manager. The scanner flagged %s with a %s bias "
                     "(score %.2f: %s). Confirm or reject using the data. ", sym, bias, score, note);
   string system = intro + StringFormat(
      "Decide whether to place ONE trade and how much to risk. "
      "Reply ONLY with JSON: {\"action\":\"BUY\"|\"SELL\"|\"HOLD\",\"order\":\"MARKET\"|\"LIMIT\"|\"STOP\","
      "\"entry\":price,\"expiry_min\":minutes,\"confidence\":0.0-1.0,"
      "\"risk_percent\":0.0-%.2f,\"sl\":price,\"tp\":price,\"reason\":\"max 30 words\"}. "
      "%s"
      "risk_percent is %% of equity lost if SL is hit: lower it for high volatility, weak confluence, nearby "
      "major levels, or exposure correlated with open positions. BUY fills at ask, SELL at bid. SL beyond a "
      "logical swing level, %.1f-%.1f ATR from entry. TP at least %.1f x SL distance at a realistic target; when "
      "the higher timeframes and momentum favour a break, the target may be the next level BEYOND a nearby one. "
      "Prices with %d decimals. HOLD with risk_percent 0 when the edge is unclear. "
      "Use all context provided. MARKET STRUCTURE on the decision timeframe decides direction: never SELL while it "
      "makes higher highs and higher lows above a rising EMA20, never BUY while it makes lower highs and lower lows "
      "below a falling EMA20 - wait for the structure to break (or use a STOP order beyond the last swing). HIGHER "
      "TIMEFRAMES are context: prefer trades that agree with them, but their EMAs lag, so a fresh M5 reversal can "
      "override them. Anchor "
      "SL/TP to KEY LEVELS and VOLUME PROFILE value-area edges/POC; treat the TICK-FLOW PROXY as weak confirmation "
      "only; avoid entries shortly before high-impact news in the ECONOMIC CALENDAR; and review YOUR RECENT TRADES - "
      "do not repeat setups that recently failed in similar conditions, but do not overreact to a single loss. "
      "If this EA already has trades on this symbol (see Open positions / Pending orders), a new trade must be a "
      "separate, high-quality setup - never add to a losing position, and do not duplicate an existing order.",
      remaining, PendingRules(idx), g_cfg.slMin, g_cfg.slMax, g_cfg.minRR, SymDigits(sym));
   string user = SymbolContext(idx) + SizingHint(idx) + SelfReviewContext() + PendingSummary() + "Open positions:\n" + PositionsSummary() +
                 StringFormat("Remaining risk budget: %.2f%% of equity\n", remaining);

   string content, used;
   if(!CallAI(InpChainEntry, InpModelEntry, system, user, content, used, "")) return;

   EntryDecision d;
   if(!ParseEntry(content, d))
     { LogRow("ENTRY", sym, "PARSE_ERROR", 0, 0, 0, 0, 0, used, StringSubstr(content, 0, 200)); return; }
   d.reason = used + ": " + d.reason;

   // Second opinion from a DIFFERENT provider: shadow (logged only) or veto
   if(InpReviewMode != REVIEW_OFF && (d.action == "BUY" || d.action == "SELL") && d.confidence >= g_cfg.minConf)
     {
      string system2 = system + " You are the independent second reviewer: judge the data yourself; do not assume "
                       "the first model is right. Reject marginal setups.";
      string content2, used2;
      if(!CallAI(InpChainReview, "", system2, user, content2, used2, used))
        {
         d.shadow = "N";
         Notify(sym + ": reviewer unavailable - entry model decides alone");
        }
      else
        {
         EntryDecision d2;
         bool parsed = ParseEntry(content2, d2);
         bool agrees = parsed && d2.action == d.action;
         string verdict = StringFormat("%s %s (%s, conf %.2f)", used2, agrees ? "AGREES" : "DISAGREES",
                                       parsed ? d2.action : "unparseable", d2.confidence);
         if(InpReviewMode == REVIEW_VETO && !agrees)
           {
            Notify(sym + " vetoed: " + verdict);
            LogRow("ENTRY", sym, d.action, d.confidence, d.risk_pct, d.sl, d.tp, 0, "REJECTED: veto - " + verdict,
                   d.reason + " | " + used2 + ": " + d2.reason);
            return;
           }
         if(InpReviewMode == REVIEW_VETO)
           {
            d.confidence = MathMin(d.confidence, d2.confidence);
            d.risk_pct   = MathMin(d.risk_pct, d2.risk_pct);
           }
         d.shadow = agrees ? "A" : "D";
         Notify(StringFormat("%s %s: review %s", sym, d.action, verdict));
         d.reason = d.reason + " | review " + verdict + ": " + d2.reason;
        }
     }
   ExecuteEntry(idx, d, remaining);
  }

void ExecuteEntry(int idx, EntryDecision &d, double riskBudget)
  {
   string sym = g_syms[idx];
   if(d.action != "BUY" && d.action != "SELL")
     {
      Notify(StringFormat("%s HOLD (conf %.2f): %s", sym, d.confidence, d.reason));
      LogRow("ENTRY", sym, "HOLD", d.confidence, d.risk_pct, d.sl, d.tp, 0, "HOLD", d.reason);
      return;
     }

   string err = "";
   bool isBuy = (d.action == "BUY");
   string ord = (InpAllowPending && (d.order == "LIMIT" || d.order == "STOP")) ? d.order : "MARKET";
   string label = d.action + (ord == "MARKET" ? "" : " " + ord);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK), bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double now = isBuy ? ask : bid;
   double entry = ord == "MARKET" ? now : NormPrice(sym, d.entry);
   double sl = NormPrice(sym, d.sl), tp = NormPrice(sym, d.tp);
   double atr = Buf(g_hATR[idx]);
   double slDist = MathAbs(entry - sl), tpDist = MathAbs(tp - entry);
   double minStop = StopLevel(sym);
   double riskPct = MathMin(d.risk_pct, riskBudget);
   int    expiryMin = d.expiryMin > 0 ? (int)MathMin(d.expiryMin, g_cfg.pendingExpiryMin) : g_cfg.pendingExpiryMin;

   if(d.confidence < g_cfg.minConf)                     err = StringFormat("confidence %.2f < %.2f", d.confidence, g_cfg.minConf);
   else if(riskPct <= 0)                                err = "risk_percent <= 0 or no budget";
   else if(atr <= 0)                                    err = "ATR unavailable";
   else if(ord != "MARKET" && entry <= 0)               err = ord + " order without an entry price";
   else if(ord == "LIMIT" && isBuy  && !(entry < ask - minStop)) err = "BUY LIMIT must be below ask";
   else if(ord == "LIMIT" && !isBuy && !(entry > bid + minStop)) err = "SELL LIMIT must be above bid";
   else if(ord == "STOP"  && isBuy  && !(entry > ask + minStop)) err = "BUY STOP must be above ask";
   else if(ord == "STOP"  && !isBuy && !(entry < bid - minStop)) err = "SELL STOP must be below bid";
   else if(ord != "MARKET" && MathAbs(entry - now) > InpPendingMaxAtr * atr)
                                                        err = StringFormat("pending entry %.2f ATR away (max %.2f)", MathAbs(entry - now) / atr, InpPendingMaxAtr);
   else if(isBuy && !(sl < entry && tp > entry))        err = "BUY needs sl < entry < tp";
   else if(!isBuy && !(sl > entry && tp < entry))       err = "SELL needs tp < entry < sl";
   else if(ord == "MARKET" && isBuy && !(sl < bid))     err = "BUY sl must be below bid";
   else if(ord == "MARKET" && !isBuy && !(sl > ask))    err = "SELL sl must be above ask";
   else if(slDist < g_cfg.slMin * atr || slDist > g_cfg.slMax * atr)
                                                        err = StringFormat("SL %.2f ATR outside [%.2f, %.2f]", slDist / atr, g_cfg.slMin, g_cfg.slMax);
   else if(slDist <= minStop || tpDist <= minStop)      err = "SL/TP inside broker stop level";
   else if(tpDist / slDist < g_cfg.minRR)               err = StringFormat("R:R %.2f < %.2f", tpDist / slDist, g_cfg.minRR);
   else if(SymbolExposure(sym) >= MathMax(1, InpMaxPerSymbol)) err = StringFormat("max %d trades on %s", InpMaxPerSymbol, sym);
   else                                                 err = StackingRule(sym, isBuy);
   if(err == "") err = StructureRule(idx, isBuy, ord, entry);

   double lots = 0;
   if(err == "")
     {
      lots = LotsForRisk(sym, isBuy, entry, sl, riskPct);
      if(lots <= 0) err = "risk too small for min lot, or insufficient margin";
     }
   if(err != "")
     {
      Notify(sym + " " + label + " rejected: " + err);
      LogRow("ENTRY", sym, label, d.confidence, d.risk_pct, sl, tp, 0, "REJECTED: " + err, d.reason);
      return;
     }

   string where = ord == "MARKET" ? "" : StringFormat(" @ %s (expires %d min)", Px(sym, entry), expiryMin);
   if(InpDryRun)
     {
      Notify(StringFormat("[DRY] %s %s %.2f lots%s risk %.2f%%", label, sym, lots, where, riskPct));
      LogRow("ENTRY", sym, label, d.confidence, riskPct, sl, tp, lots, "DRY_RUN" + where, d.reason);
      return;
     }

   g_trade.SetTypeFillingBySymbol(sym);
   string cmt = StringFormat("AI c%.0f r%.2f x%d%s", d.confidence * 100, riskPct, expiryMin,
                             d.shadow == "" ? "" : " s" + d.shadow);   // s = shadow review verdict
   bool ok;
   if(ord == "MARKET")
      ok = isBuy ? g_trade.Buy(lots, sym, ask, sl, tp, cmt) : g_trade.Sell(lots, sym, bid, sl, tp, cmt);
   else
     {
      // broker-side expiry when supported; ExpirePendings() also cancels it from the EA side
      bool canExpire = (SymbolInfoInteger(sym, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) != 0;
      ENUM_ORDER_TYPE_TIME tt = canExpire ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;
      datetime exp = canExpire ? TimeTradeServer() + expiryMin * 60 : 0;
      if(ord == "LIMIT") ok = isBuy ? g_trade.BuyLimit(lots, entry, sym, sl, tp, tt, exp, cmt)
                                    : g_trade.SellLimit(lots, entry, sym, sl, tp, tt, exp, cmt);
      else               ok = isBuy ? g_trade.BuyStop(lots, entry, sym, sl, tp, tt, exp, cmt)
                                    : g_trade.SellStop(lots, entry, sym, sl, tp, tt, exp, cmt);
     }
   uint rc = g_trade.ResultRetcode();
   string status = (ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED)) ? "PLACED" + where :
                   "FAILED_" + IntegerToString(rc) + " " + g_trade.ResultRetcodeDescription();
   Notify(StringFormat("%s %s %.2f lots%s: %s", label, sym, lots, where, status));
   LogRow("ENTRY", sym, label, d.confidence, riskPct, sl, tp, lots, status, d.reason);
  }

//+------------------------------------------------------------------+
//| STAGE 3+4: MANAGE and CLOSE                                       |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   ulong tickets[];
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(IsOurs(t)) { int n = ArraySize(tickets); ArrayResize(tickets, n + 1); tickets[n] = t; }
     }
   for(int k = 0; k < ArraySize(tickets); k++)
     {
      if(g_calls >= g_cfg.maxCalls) { Print("AITrader: AI budget used, skipping management"); return; }
      if(!PositionSelectByTicket(tickets[k])) continue;
      ManageOne(tickets[k]);
     }
  }

void ManageOne(ulong ticket)
  {
   string sym  = PositionGetString(POSITION_SYMBOL);
   int    idx  = SymbolIndex(sym);
   if(idx < 0) return;
   bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double open = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double cur  = PositionGetDouble(POSITION_PRICE_CURRENT);
   double pnl  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
   string cmt  = PositionGetString(POSITION_COMMENT);
   int dg = SymDigits(sym);

   double riskDist = sl > 0 ? MathAbs(open - sl) : 0;
   double rMult = riskDist > 0 ? (isBuy ? cur - open : open - cur) / riskDist : 0;

   string system = StringFormat(
      "You manage an open %s position on %s. Choose ONE action: HOLD, CLOSE (exit now), PARTIAL (close part, "
      "give close_fraction 0.1-0.9), or MODIFY (new_sl and/or new_tp; use 0 to keep). The stop-loss may only be "
      "moved in the trade's favour (tightened), never widened. Lock profits on strength, cut the trade when the "
      "setup is invalidated, and avoid over-managing: HOLD is the normal answer while the thesis is intact. %s"
      "Reply ONLY with JSON: {\"action\":\"HOLD\"|\"CLOSE\"|\"PARTIAL\"|\"MODIFY\",\"confidence\":0.0-1.0,"
      "\"new_sl\":price,\"new_tp\":price,\"close_fraction\":0.0,\"reason\":\"max 25 words\"}. Prices with %d decimals.",
      isBuy ? "BUY" : "SELL", sym,
      InpTrailEnabled ? StringFormat("The EA runs a mechanical trailing stop (starts at %.1fR, %.1f ATR behind price); "
                                     "only MODIFY the stop for a clear structural reason. ", InpTrailStartR, InpTrailAtr) : "",
      dg);
   string user = StringFormat(
      "Position #%I64u %s %s %.2f lots, opened %s (%.1f h ago) at %s. Current %s. SL %s TP %s. "
      "Floating P/L %.2f %s (%.2fR). Entry note: %s\n",
      ticket, isBuy ? "BUY" : "SELL", sym, vol, TimeToString(opened, TIME_DATE | TIME_MINUTES),
      (TimeCurrent() - opened) / 3600.0, DoubleToString(open, dg), DoubleToString(cur, dg),
      DoubleToString(sl, dg), DoubleToString(tp, dg), pnl, AccountInfoString(ACCOUNT_CURRENCY), rMult, cmt);
   user += SymbolContext(idx);

   string content;
   string used;
   if(!CallAI(InpChainManage, InpModelManage, system, user, content, used, "")) return;

   ManageDecision m;
   if(!ParseManage(content, m))
     { LogRow("MANAGE", sym, "PARSE_ERROR", 0, 0, 0, 0, vol, "", StringSubstr(content, 0, 200)); return; }

   if(m.action == "HOLD")
     { LogRow("MANAGE", sym, "HOLD", m.confidence, 0, sl, tp, vol, "HOLD", m.reason); return; }
   if(m.confidence < g_cfg.minManageConf)
     { LogRow("MANAGE", sym, m.action, m.confidence, 0, m.new_sl, m.new_tp, vol, "IGNORED: low confidence", m.reason); return; }
   if(!PositionSelectByTicket(ticket)) return; // closed meanwhile (SL/TP)

   if(m.action == "CLOSE")
     {
      ClosePosition(ticket, "AI: " + m.reason);
      return;
     }
   if(m.action == "PARTIAL")
     {
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double frac = MathMax(0.0, MathMin(1.0, m.close_fraction));
      double part = MathFloor(vol * frac / step) * step;
      if(frac >= 0.99) { ClosePosition(ticket, "AI partial>=99%: " + m.reason); return; }
      if(part < vmin || vol - part < vmin)
        { LogRow("MANAGE", sym, "PARTIAL", m.confidence, 0, 0, 0, part, "REJECTED: volume too small to split", m.reason); return; }
      part = NormalizeDouble(part, VolDigits(step));
      if(InpDryRun) { LogRow("MANAGE", sym, "PARTIAL", m.confidence, 0, 0, 0, part, "DRY_RUN", m.reason); return; }
      bool ok = g_trade.PositionClosePartial(ticket, part);
      Notify(StringFormat("partial close %s %.2f: %s", sym, part, ok ? "OK" : g_trade.ResultRetcodeDescription()));
      LogRow("MANAGE", sym, "PARTIAL", m.confidence, 0, 0, 0, part, ok ? "DONE" : "FAILED", m.reason);
      return;
     }
   if(m.action == "MODIFY")
     {
      double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double stop = StopLevel(sym);
      double nsl = sl, ntp = tp;
      string notes = "";
      if(m.new_sl > 0)
        {
         double c = NormPrice(sym, m.new_sl);
         bool tighter = isBuy ? (sl == 0 || c > sl) : (sl == 0 || c < sl);
         bool valid   = isBuy ? (c < bid - stop) : (c > ask + stop);
         if(tighter && valid) nsl = c; else notes += "sl rejected (widening or too close); ";
        }
      if(m.new_tp > 0)
        {
         double c = NormPrice(sym, m.new_tp);
         bool valid = isBuy ? (c > ask + stop) : (c < bid - stop);
         if(valid) ntp = c; else notes += "tp rejected (wrong side/too close); ";
        }
      if(nsl == sl && ntp == tp)
        { LogRow("MANAGE", sym, "MODIFY", m.confidence, 0, m.new_sl, m.new_tp, vol, "REJECTED: " + notes, m.reason); return; }
      if(InpDryRun) { LogRow("MANAGE", sym, "MODIFY", m.confidence, 0, nsl, ntp, vol, "DRY_RUN " + notes, m.reason); return; }
      bool ok = g_trade.PositionModify(ticket, nsl, ntp);
      Notify(StringFormat("modify %s sl %s tp %s: %s", sym, DoubleToString(nsl, dg), DoubleToString(ntp, dg),
                         ok ? "OK" : g_trade.ResultRetcodeDescription()));
      LogRow("MANAGE", sym, "MODIFY", m.confidence, 0, nsl, ntp, vol, (ok ? "DONE " : "FAILED ") + notes, m.reason);
     }
  }

void ClosePosition(ulong ticket, string why)
  {
   if(!PositionSelectByTicket(ticket)) return;
   string sym = PositionGetString(POSITION_SYMBOL);
   double vol = PositionGetDouble(POSITION_VOLUME);
   if(InpDryRun)
     {
      Notify("[DRY] close " + sym + ": " + why);
      LogRow("CLOSE", sym, "CLOSE", 0, 0, 0, 0, vol, "DRY_RUN", why);
      return;
     }
   bool ok = g_trade.PositionClose(ticket);
   Notify(StringFormat("close %s: %s (%s)", sym, ok ? "OK" : g_trade.ResultRetcodeDescription(), why));
   LogRow("CLOSE", sym, "CLOSE", 0, 0, 0, 0, vol, ok ? "DONE" : "FAILED", why);
  }

void CloseAll(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(IsOurs(t)) ClosePosition(t, why);
     }
  }

void MechanicalBreakeven()
  {
   if(InpDryRun) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!IsOurs(t)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP), cur = PositionGetDouble(POSITION_PRICE_CURRENT);
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double risk = isBuy ? open - sl : sl - open;
      if(sl == 0 || risk <= 0) continue;
      if((isBuy ? cur - open : open - cur) >= InpBreakevenR * risk)
        {
         double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
         if(g_trade.PositionModify(t, NormPrice(sym, isBuy ? open + 2 * pt : open - 2 * pt), tp))
            Notify(sym + " moved to breakeven");
        }
     }
  }

//+------------------------------------------------------------------+
//| Context builders                                                  |
//+------------------------------------------------------------------+
string SymbolContext(int idx)
  {
   string sym = g_syms[idx];
   int dg = SymDigits(sym);
   string s = StringFormat("Symbol %s | %s | server time %s\n", sym, TfName(g_cfg.scanTF),
                           TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES));
   s += StringFormat("Bid %s Ask %s | ATR14 %s RSI14 %.1f EMA20 %s EMA50 %s EMA200 %s\n",
                     DoubleToString(SymbolInfoDouble(sym, SYMBOL_BID), dg), DoubleToString(SymbolInfoDouble(sym, SYMBOL_ASK), dg),
                     DoubleToString(Buf(g_hATR[idx]), dg), Buf(g_hRSI[idx]), DoubleToString(Buf(g_hE20[idx]), dg),
                     DoubleToString(Buf(g_hE50[idx]), dg), DoubleToString(Buf(g_hE200[idx]), dg));

   MqlRates d[]; ArraySetAsSeries(d, true);
   int nd = CopyRates(sym, PERIOD_D1, 0, 6, d);
   if(nd > 0)
     {
      s += StringFormat("Today O %s H %s L %s\nDaily bars (date,o,h,l,c):\n", DoubleToString(d[0].open, dg),
                        DoubleToString(d[0].high, dg), DoubleToString(d[0].low, dg));
      for(int i = nd - 1; i >= 1; i--)
         s += StringFormat("%s,%s,%s,%s,%s\n", TimeToString(d[i].time, TIME_DATE), DoubleToString(d[i].open, dg),
                           DoubleToString(d[i].high, dg), DoubleToString(d[i].low, dg), DoubleToString(d[i].close, dg));
     }

   MqlRates r[]; ArraySetAsSeries(r, true);
   int n = CopyRates(sym, g_cfg.scanTF, 1, g_cfg.bars, r);
   s += StringFormat("Last %d closed %s bars, oldest first (time,o,h,l,c,vol):\n", MathMax(n, 0), TfName(g_cfg.scanTF));
   for(int i = n - 1; i >= 0; i--)
      s += StringFormat("%s,%s,%s,%s,%s,%I64d\n", TimeToString(r[i].time, TIME_DATE | TIME_MINUTES),
                        DoubleToString(r[i].open, dg), DoubleToString(r[i].high, dg),
                        DoubleToString(r[i].low, dg), DoubleToString(r[i].close, dg), r[i].tick_volume);

   double dayEq = DayStartEquity(), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   s += StringFormat("Account equity %.2f %s, today P/L %.2f%%, open risk %.2f%%, trades today %d/%d\n",
                     eq, AccountInfoString(ACCOUNT_CURRENCY), dayEq > 0 ? (eq - dayEq) / dayEq * 100 : 0.0,
                     OpenRiskPct(), CountTodayEntries(), g_cfg.maxTradesDay);
   s += StructureContext(idx) + HtfContext(sym) + KeyLevelsContext(sym) + VolumeProfileContext(sym) + TickFlowContext(sym) + NewsContext();
   return s;
  }

string PositionsSummary()
  {
   string s = "";
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!IsOurs(t)) continue;
      s += StringFormat("%s %s %.2f lots, P/L %.2f\n", PositionGetString(POSITION_SYMBOL),
                        PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL",
                        PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PROFIT));
     }
   return s == "" ? "none\n" : s;
  }

//+------------------------------------------------------------------+
//| Risk / sizing                                                     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Money lost (account currency, positive) if 'vol' lots move from   |
//| 'from' to 'to' against the position. Uses OrderCalcProfit, and    |
//| falls back to tick value when it fails (e.g. cent-account         |
//| currency conversion). Returns 0 if neither works.                 |
//+------------------------------------------------------------------+
double LossBetween(string sym, bool isBuy, double vol, double from, double to)
  {
   double pnl = 0;
   ResetLastError();
   if(OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, sym, vol, from, to, pnl) && pnl < 0)
      return -pnl;
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickLoss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickLoss <= 0) tickLoss = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double dist = isBuy ? from - to : to - from;
   if(tickSize <= 0 || tickLoss <= 0 || dist <= 0) return 0;
   return dist / tickSize * tickLoss * vol;
  }

double LotsForRisk(string sym, bool isBuy, double entry, double sl, double riskPct)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double pnl = 0;
   pnl = -LossBetween(sym, isBuy, 1.0, entry, sl);
   if(pnl >= 0) return 0;
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double lots = MathFloor(riskMoney / -pnl / step) * step;
   if(lots < vmin) return 0;
   lots = MathMin(lots, vmax);
   double margin = 0, free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   while(lots >= vmin && OrderCalcMargin(type, sym, lots, entry, margin) && margin > free * 0.8)
      lots -= step;
   if(lots < vmin) return 0;
   return NormalizeDouble(lots, VolDigits(step));
  }

// Money lost if every open position hit its SL from the current price, as % of equity.
// Positions without SL count as a full max-risk slot.
double OpenRiskPct()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0) return 100;
   double pct = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!IsOurs(t)) continue;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl == 0) { pct += g_cfg.riskPct; continue; }
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double loss = LossBetween(PositionGetString(POSITION_SYMBOL), isBuy, PositionGetDouble(POSITION_VOLUME),
                                PositionGetDouble(POSITION_PRICE_CURRENT), sl);
      if(loss > 0) pct += loss / eq * 100.0;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(!IsOurPending(t)) continue;
      double sl = OrderGetDouble(ORDER_SL);
      if(sl == 0) { pct += g_cfg.riskPct; continue; }
      long type = OrderGetInteger(ORDER_TYPE);
      bool isBuy = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
      double loss = LossBetween(OrderGetString(ORDER_SYMBOL), isBuy, OrderGetDouble(ORDER_VOLUME_CURRENT),
                                OrderGetDouble(ORDER_PRICE_OPEN), sl);
      if(loss > 0) pct += loss / eq * 100.0;
     }
   return pct;
  }

//+------------------------------------------------------------------+
//| AI HTTP client (OpenAI-compatible chat completions)               |
//+------------------------------------------------------------------+
// Key sources, first non-empty wins:
//   1. the EA input      - WARNING: MT5 prints every input in the log, keys included
//   2. AITraderKeys.mqh  - compiled into the .ex5, so it reaches the VPS and is never logged
//   3. <Common>\Files    - PC only, not migrated to the MQL5 VPS
void AddProvider(bool enabled, string name, string url, string key, string compiledKey, string keyFile,
                 string model, bool openrouter)
  {
   if(!enabled) return;
   if(key != "") PrintFormat("AITrader: %s key comes from the EA input - it is visible in the terminal log; prefer AITraderKeys.mqh", name);
   if(key == "" && compiledKey != "") { key = compiledKey; PrintFormat("AITrader: %s key loaded from AITraderKeys.mqh", name); }
   if(key == "") key = ReadKeyFile(keyFile);
   if(key == "") { PrintFormat("AITrader: %s skipped - no key (input, AITraderKeys.mqh and <Common>\\Files\\%s all empty)", name, keyFile); return; }
   int n = ArraySize(g_prov);
   ArrayResize(g_prov, n + 1);
   g_prov[n].name = name; g_prov[n].url = url; g_prov[n].key = key;
   g_prov[n].model = model; g_prov[n].openrouter = openrouter; g_prov[n].downUntil = 0;
  }

string ProviderChain()
  {
   string s = "";
   for(int i = 0; i < ArraySize(g_prov); i++)
      s += (i > 0 ? " > " : "") + g_prov[i].name + (g_prov[i].downUntil > TimeCurrent() ? "(down)" : "");
   return s;
  }

bool AlgoTradingOn()
  {
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
  }

string HostOf(string url)
  {
   int p = StringFind(url, "://");
   int q = StringFind(url, "/", p < 0 ? 0 : p + 3);
   return q > 0 ? StringSubstr(url, 0, q) : url;
  }

// Tries the providers named in 'chain' (comma separated, in order), skipping 'exclude'.
// The per-stage model override applies only when the primary (asAi) answers.
bool CallAI(string chain, string stageModel, string system, string user, string &content,
            string &used, string exclude)
  {
   content = ""; used = "";
   system = ProfileBrief() + " " + system;
   int n = ArraySize(g_prov);
   int order[];
   ArrayResize(order, 0);
   string names[];
   int nn = StringSplit(chain, ',', names);
   for(int c = 0; c < nn; c++)
     {
      string want = names[c];
      StringTrimLeft(want); StringTrimRight(want); StringToLower(want);
      for(int i = 0; i < n; i++)
        {
         string have = g_prov[i].name;
         StringToLower(have);
         if(have != want) continue;
         bool dup = false;
         for(int k = 0; k < ArraySize(order); k++) if(order[k] == i) dup = true;
         if(!dup) { int k = ArraySize(order); ArrayResize(order, k + 1); order[k] = i; }
        }
     }
   if(ArraySize(order) == 0) // nothing in the chain is configured: fall back to every provider
     { ArrayResize(order, n); for(int i = 0; i < n; i++) order[i] = i; }

   bool anyUp = false; // if every candidate is cooling down, try them all rather than go blind
   for(int k = 0; k < ArraySize(order); k++)
      if(g_prov[order[k]].name != exclude && g_prov[order[k]].downUntil <= TimeCurrent()) anyUp = true;

   for(int k = 0; k < ArraySize(order); k++)
     {
      int i = order[k];
      if(g_prov[i].name == exclude) continue;
      if(anyUp && g_prov[i].downUntil > TimeCurrent()) continue;
      if(g_calls >= g_cfg.maxCalls) { Print("AITrader: daily AI call budget reached"); return false; }
      string model = (g_prov[i].name == InpP1Name && stageModel != "") ? stageModel : g_prov[i].model;
      string err = "";
      if(CallProvider(g_prov[i], model, system, user, content, err))
        {
         g_prov[i].downUntil = 0;
         used = g_prov[i].name;
         g_lastProvider = g_prov[i].name + "/" + model;
         return true;
        }
      g_prov[i].downUntil = TimeCurrent() + InpFailoverCooldownMin * 60;
      Notify(StringFormat("%s failed (%s)%s", g_prov[i].name, err, k + 1 < ArraySize(order) ? " - failing over" : ""));
     }
   return false;
  }

bool CallProvider(AIProvider &p, string model, string system, string user, string &content, string &err)
  {
   g_calls++;
   string body = "{\"model\":\"" + JsonEscape(model) + "\",";
   body += "\"temperature\":" + DoubleToString(InpTemperature, 2) + ",";
   body += "\"max_tokens\":" + IntegerToString(InpMaxTokens) + ",";
   if(InpJsonMode) body += "\"response_format\":{\"type\":\"json_object\"},";
   body += "\"messages\":[{\"role\":\"system\",\"content\":\"" + JsonEscape(system) + "\"},";
   body += "{\"role\":\"user\",\"content\":\"" + JsonEscape(user) + "\"}]}";

   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + p.key + "\r\n";
   if(p.openrouter) headers += "X-Title: AITraderEA\r\n";

   char data[], result[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0) ArrayResize(data, len - 1);
   string resHeaders;

   ResetLastError();
   uint t0 = GetTickCount();
   int code = WebRequest("POST", p.url, headers, InpTimeoutMs, data, result, resHeaders);
   if(code == -1)
     {
      int e = GetLastError();
      err = (e == 4014) ? "URL not allowed: add " + HostOf(p.url) + " in Tools > Options > Expert Advisors"
                        : StringFormat("WebRequest error %d (timeout or network)", e);
      return false;
     }
   string resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   if(code != 200)
     {
      err = StringFormat("HTTP %d", code);
      Print("AITrader: ", p.name, " response: ", StringSubstr(resp, 0, 400));
      return false;
     }
   int pos = JsonValueStart(resp, "content", StringFind(resp, "\"choices\""));
   if(pos < 0 || !JsonReadString(resp, pos, content) || StringFind(content, "{") < 0)
     {
      err = "no JSON content in reply";
      Print("AITrader: ", p.name, " response: ", StringSubstr(resp, 0, 400));
      return false;
     }
   PrintFormat("AITrader: %s/%s replied in %.1fs", p.name, model, (GetTickCount() - t0) / 1000.0);
   return true;
  }

bool ParseEntry(string content, EntryDecision &d)
  {
   d.action = ""; d.order = "MARKET"; d.entry = 0; d.expiryMin = 0; d.shadow = "";
   d.confidence = 0; d.risk_pct = 0; d.sl = 0; d.tp = 0; d.reason = "";
   string o = ExtractJsonObject(content);
   if(o == "") return false;
   d.action = UpperTrim(JsonGetString(o, "action"));
   if(d.action != "BUY" && d.action != "SELL" && d.action != "HOLD") return false;
   d.confidence = NormConf(JsonGetNumber(o, "confidence"));
   d.risk_pct   = JsonGetNumber(o, "risk_percent");
   string ord   = UpperTrim(JsonGetString(o, "order"));
   if(ord == "LIMIT" || ord == "STOP") d.order = ord;
   d.entry      = JsonGetNumber(o, "entry");
   d.expiryMin  = (int)JsonGetNumber(o, "expiry_min");
   d.sl         = JsonGetNumber(o, "sl");
   d.tp         = JsonGetNumber(o, "tp");
   d.reason     = JsonGetString(o, "reason");
   return true;
  }

bool ParseManage(string content, ManageDecision &m)
  {
   m.action = ""; m.confidence = 0; m.new_sl = 0; m.new_tp = 0; m.close_fraction = 0; m.reason = "";
   string o = ExtractJsonObject(content);
   if(o == "") return false;
   m.action = UpperTrim(JsonGetString(o, "action"));
   if(m.action != "HOLD" && m.action != "CLOSE" && m.action != "PARTIAL" && m.action != "MODIFY") return false;
   m.confidence     = NormConf(JsonGetNumber(o, "confidence"));
   m.new_sl         = JsonGetNumber(o, "new_sl");
   m.new_tp         = JsonGetNumber(o, "new_tp");
   m.close_fraction = JsonGetNumber(o, "close_fraction");
   if(m.close_fraction > 1.0 && m.close_fraction <= 100.0) m.close_fraction /= 100.0;
   m.reason         = JsonGetString(o, "reason");
   return true;
  }

double NormConf(double c) { return (c > 1.0 && c <= 100.0) ? c / 100.0 : c; }
string UpperTrim(string s) { StringToUpper(s); StringTrimLeft(s); StringTrimRight(s); return s; }

//+------------------------------------------------------------------+
//| Minimal JSON helpers                                              |
//+------------------------------------------------------------------+
string JsonEscape(const string s)
  {
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '"')       out += "\\\"";
      else if(c == '\\') out += "\\\\";
      else if(c == '\n') out += "\\n";
      else if(c == '\r') out += "\\r";
      else if(c == '\t') out += "\\t";
      else if(c < 0x20)  out += StringFormat("\\u%04x", c);
      else               out += ShortToString(c);
     }
   return out;
  }

bool IsWs(ushort c) { return c == ' ' || c == '\n' || c == '\r' || c == '\t'; }

int JsonValueStart(const string s, const string key, int from = 0)
  {
   if(from < 0) from = 0;
   string pat = "\"" + key + "\"";
   int n = StringLen(s), idx = StringFind(s, pat, from);
   while(idx >= 0)
     {
      bool escaped = (idx > 0 && StringGetCharacter(s, idx - 1) == '\\');
      int p = idx + StringLen(pat);
      while(p < n && IsWs(StringGetCharacter(s, p))) p++;
      if(!escaped && p < n && StringGetCharacter(s, p) == ':')
        {
         p++;
         while(p < n && IsWs(StringGetCharacter(s, p))) p++;
         return p < n ? p : -1;
        }
      idx = StringFind(s, pat, idx + 1);
     }
   return -1;
  }

int HexVal(ushort c)
  {
   if(c >= '0' && c <= '9') return c - '0';
   if(c >= 'a' && c <= 'f') return c - 'a' + 10;
   if(c >= 'A' && c <= 'F') return c - 'A' + 10;
   return -1;
  }

bool JsonReadString(const string s, int p, string &out)
  {
   out = "";
   int n = StringLen(s);
   if(p >= n || StringGetCharacter(s, p) != '"') return false;
   for(int i = p + 1; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(c == '"') return true;
      if(c != '\\') { out += ShortToString(c); continue; }
      if(++i >= n) return false;
      ushort e = StringGetCharacter(s, i);
      if(e == 'n')      out += "\n";
      else if(e == 't') out += "\t";
      else if(e == 'r') out += "\r";
      else if(e == 'b' || e == 'f') { }
      else if(e == 'u' && i + 4 < n)
        {
         int v = 0;
         for(int k = 1; k <= 4; k++)
           {
            int h = HexVal(StringGetCharacter(s, i + k));
            if(h < 0) return false;
            v = v * 16 + h;
           }
         out += ShortToString((ushort)v);
         i += 4;
        }
      else out += ShortToString(e);
     }
   return false;
  }

// Index of the brace/bracket closing the one at 'start', skipping strings.
int MatchClose(const string s, int start)
  {
   ushort open = StringGetCharacter(s, start);
   ushort close = (open == '{') ? '}' : ']';
   int depth = 0, n = StringLen(s);
   bool inStr = false;
   for(int i = start; i < n; i++)
     {
      ushort c = StringGetCharacter(s, i);
      if(inStr)
        {
         if(c == '\\') { i++; continue; }
         if(c == '"') inStr = false;
         continue;
        }
      if(c == '"') inStr = true;
      else if(c == open) depth++;
      else if(c == close) { depth--; if(depth == 0) return i; }
     }
   return -1;
  }

string ExtractJsonObject(string content)
  {
   int think = StringFind(content, "</think>");
   if(think >= 0) content = StringSubstr(content, think + 8);
   int a = StringFind(content, "{");
   if(a < 0) return "";
   int b = MatchClose(content, a);
   return b > a ? StringSubstr(content, a, b - a + 1) : "";
  }

int JsonArrayObjects(const string s, const string key, string &objs[])
  {
   ArrayResize(objs, 0);
   int p = JsonValueStart(s, key);
   if(p < 0 || StringGetCharacter(s, p) != '[') return 0;
   int end = MatchClose(s, p);
   if(end < 0) return 0;
   int i = p + 1;
   while(i < end)
     {
      if(StringGetCharacter(s, i) == '{')
        {
         int e = MatchClose(s, i);
         if(e < 0 || e > end) break;
         int n = ArraySize(objs);
         ArrayResize(objs, n + 1);
         objs[n] = StringSubstr(s, i, e - i + 1);
         i = e + 1;
        }
      else i++;
     }
   return ArraySize(objs);
  }

string JsonGetString(const string obj, const string key)
  {
   int p = JsonValueStart(obj, key);
   string v = "";
   if(p >= 0 && StringGetCharacter(obj, p) == '"') JsonReadString(obj, p, v);
   return v;
  }

double JsonGetNumber(const string obj, const string key)
  {
   int p = JsonValueStart(obj, key);
   if(p < 0) return 0.0;
   if(StringGetCharacter(obj, p) == '"')
     {
      string v; JsonReadString(obj, p, v);
      return StringToDouble(v);
     }
   int n = StringLen(obj), q = p;
   while(q < n)
     {
      ushort c = StringGetCharacter(obj, q);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E') q++;
      else break;
     }
   return q > p ? StringToDouble(StringSubstr(obj, p, q - p)) : 0.0;
  }

//+------------------------------------------------------------------+
//| Symbols, positions, history                                       |
//+------------------------------------------------------------------+
// Maps a plain name (XAUUSD) to the broker's name (XAUUSDc, XAUUSD.m, mXAUUSD, ...).
// 1) exact name  2) base + the chart symbol's suffix  3) any broker symbol containing the base.
string ResolveSymbol(string base)
  {
   bool custom = false;
   if(SymbolExist(base, custom) && SymbolSelect(base, true)) return base;

   string suffix = StringLen(_Symbol) > 6 ? StringSubstr(_Symbol, 6) : "";
   if(suffix != "" && SymbolExist(base + suffix, custom) && SymbolSelect(base + suffix, true)) return base + suffix;

   string best = "";
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      if(StringFind(name, base) < 0 || StringLen(name) > StringLen(base) + 4) continue;
      long mode = SymbolInfoInteger(name, SYMBOL_TRADE_MODE);
      if(mode == SYMBOL_TRADE_MODE_DISABLED) continue;
      if(best == "" || StringLen(name) < StringLen(best)) best = name; // prefer the shortest variant
     }
   if(best != "" && SymbolSelect(best, true)) return best;
   return "";
  }

bool LoadSymbols()
  {
   string parts[];
   int n = StringSplit(InpSymbols, ',', parts);
   ArrayResize(g_syms, 0);
   for(int i = 0; i < n; i++)
     {
      string s = parts[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(s == "") continue;
      string resolved = ResolveSymbol(s);
      if(resolved == "") { Print("AITrader: symbol not found at broker, skipped: ", s); continue; }
      if(resolved != s) PrintFormat("AITrader: %s -> broker symbol %s", s, resolved);
      if(SymbolIndex(resolved) >= 0 && g_syms[SymbolIndex(resolved)] == resolved) continue; // duplicate
      s = resolved;
      int k = ArraySize(g_syms);
      ArrayResize(g_syms, k + 1);   ArrayResize(g_hATR, k + 1); ArrayResize(g_hRSI, k + 1);
      ArrayResize(g_hE20, k + 1);   ArrayResize(g_hE50, k + 1); ArrayResize(g_hE200, k + 1);
      g_syms[k]  = s;
      g_hATR[k]  = iATR(s, g_cfg.scanTF, 14);
      g_hRSI[k]  = iRSI(s, g_cfg.scanTF, 14, PRICE_CLOSE);
      g_hE20[k]  = iMA(s, g_cfg.scanTF, 20, 0, MODE_EMA, PRICE_CLOSE);
      g_hE50[k]  = iMA(s, g_cfg.scanTF, 50, 0, MODE_EMA, PRICE_CLOSE);
      g_hE200[k] = iMA(s, g_cfg.scanTF, 200, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hATR[k] == INVALID_HANDLE || g_hRSI[k] == INVALID_HANDLE || g_hE20[k] == INVALID_HANDLE ||
         g_hE50[k] == INVALID_HANDLE || g_hE200[k] == INVALID_HANDLE)
        {
         Print("AITrader: indicator handles failed for ", s);
         return false;
        }
     }
   if(ArraySize(g_syms) == 0) { Print("AITrader: watchlist is empty"); return false; }
   return true;
  }

int SymbolIndex(string sym)
  {
   StringTrimLeft(sym); StringTrimRight(sym);
   for(int i = 0; i < ArraySize(g_syms); i++)
      if(g_syms[i] == sym) return i;
   for(int i = 0; i < ArraySize(g_syms); i++) // tolerate AI dropping a broker suffix (XAUUSD vs XAUUSDm)
      if(StringFind(g_syms[i], sym) == 0) return i;
   return -1;
  }

bool SymbolTradable(string sym)
  {
   long mode = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;
   MqlTick tk;
   if(!SymbolInfoTick(sym, tk)) return false;
   return TimeCurrent() - tk.time < 600; // no tick for 10 min = market closed
  }

bool IsOurs(ulong ticket)
  {
   return ticket != 0 && PositionSelectByTicket(ticket) && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic;
  }

bool HasPosition(string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(IsOurs(t) && PositionGetString(POSITION_SYMBOL) == sym) return true;
     }
   return false;
  }

int CountPositions()
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(IsOurs(PositionGetTicket(i))) c++;
   return c;
  }

datetime DayStart() { long t = (long)TimeCurrent(); return (datetime)(t - t % 86400); }

void RollDay()
  {
   datetime d = DayStart();
   if(d != g_day) { g_day = d; g_calls = 0; g_haltedToday = false; DayStartEquity(); }
  }

double DayStartEquity()
  {
   string base = "AITrader_" + IntegerToString((long)InpMagic);
   double day = (double)DayStart();
   if(!GlobalVariableCheck(base + "_day") || GlobalVariableGet(base + "_day") != day)
     {
      GlobalVariableSet(base + "_day", day);
      GlobalVariableSet(base + "_eq", AccountInfoDouble(ACCOUNT_EQUITY));
     }
   return GlobalVariableGet(base + "_eq");
  }

// New entries today: opening market orders + pending orders (filled, expired or still waiting), each once.
int CountTodayEntries()
  {
   int c = 0;
   if(HistorySelect(DayStart(), TimeCurrent() + 60))
      for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0 || (ulong)HistoryOrderGetInteger(t, ORDER_MAGIC) != InpMagic) continue;
         if(IsPendingType(HistoryOrderGetInteger(t, ORDER_TYPE)) ||
            (ulong)HistoryOrderGetInteger(t, ORDER_POSITION_ID) == t)   // opening market order (not a close)
            c++;
        }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t != 0 && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= DayStart())
         c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//| PENDING ORDERS                                                    |
//+------------------------------------------------------------------+
bool IsPendingType(long type)
  {
   return type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||
          type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_SELL_STOP;
  }

bool IsOurPending(ulong ticket)
  {
   return ticket != 0 && OrderSelect(ticket) && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic &&
          IsPendingType(OrderGetInteger(ORDER_TYPE));
  }

int CountPendings()
  {
   int c = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--) if(IsOurPending(OrderGetTicket(i))) c++;
   return c;
  }

bool HasPending(string sym)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(IsOurPending(OrderGetTicket(i)) && OrderGetString(ORDER_SYMBOL) == sym) return true;
   return false;
  }

void CancelPendings(string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(!IsOurPending(t)) continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      bool ok = InpDryRun ? true : g_trade.OrderDelete(t);
      Notify(StringFormat("pending #%I64u %s cancelled (%s)%s", t, sym, why, ok ? "" : " FAILED"));
      LogRow("CLOSE", sym, "CANCEL PENDING", 0, 0, 0, 0, OrderGetDouble(ORDER_VOLUME_CURRENT), ok ? "DONE" : "FAILED", why);
     }
  }

// EA-side expiry (also covers brokers without ORDER_TIME_SPECIFIED). Lifetime is stored as " xNN" in the comment.
void ExpirePendings()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(!IsOurPending(t)) continue;
      string cmt = OrderGetString(ORDER_COMMENT);
      int p = StringFind(cmt, " x");
      int life = p >= 0 ? (int)StringToInteger(StringSubstr(cmt, p + 2)) : g_cfg.pendingExpiryMin;
      if(life <= 0) life = g_cfg.pendingExpiryMin;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if(TimeCurrent() - setup >= (long)life * 60 && !InpDryRun)
        {
         string sym = OrderGetString(ORDER_SYMBOL);
         if(g_trade.OrderDelete(t)) Notify(StringFormat("pending #%I64u %s expired after %d min", t, sym, life));
        }
     }
  }

string PendingSummary()
  {
   string s = "";
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(!IsOurPending(t)) continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      s += StringFormat("  %s %s @ %s sl %s tp %s\n", sym, EnumToString((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE)),
                        Px(sym, OrderGetDouble(ORDER_PRICE_OPEN)), Px(sym, OrderGetDouble(ORDER_SL)), Px(sym, OrderGetDouble(ORDER_TP)));
     }
   return s == "" ? "" : "Pending orders of this EA:\n" + s;
  }

// Order-type rules for the entry prompt.
string PendingRules(int idx)
  {
   if(!InpAllowPending)
      return "Only MARKET orders are allowed: BUY fills at ask, SELL at bid. ";
   string sym = g_syms[idx];
   double atr = Buf(g_hATR[idx]);
   return StringFormat(
      "order: MARKET fills now (BUY at ask, SELL at bid) - use it only when the setup is valid right now. "
      "If your plan is to WAIT for a pullback, retest or rejection at a level, do NOT answer HOLD: place a LIMIT "
      "order at that level (BUY LIMIT below price, SELL LIMIT above price). To trade a confirmed break, place a STOP "
      "order just beyond the level (BUY STOP above price, SELL STOP below price). entry is the pending price, at "
      "most %.1f ATR (%s) from current price; expiry_min is how long the idea stays valid (max %d). For a pending "
      "order, SL, TP and reward:risk are measured from entry, so a better entry improves reward:risk. HOLD only when "
      "there is no clear plan at all. ",
      InpPendingMaxAtr, Px(sym, InpPendingMaxAtr * atr), g_cfg.pendingExpiryMin);
  }

//+------------------------------------------------------------------+
//| Small utilities                                                   |
//+------------------------------------------------------------------+
double Buf(int handle, int shift = 1)
  {
   double b[];
   return CopyBuffer(handle, 0, shift, 1, b) == 1 ? b[0] : 0.0;
  }

int    SymDigits(string sym)    { return (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); }
double StopLevel(string sym) { return (double)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(sym, SYMBOL_POINT); }
string TfName(ENUM_TIMEFRAMES tf) { string s = EnumToString(tf); StringReplace(s, "PERIOD_", ""); return s; }

double NormPrice(string sym, double p)
  {
   double tick = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   int dg = SymDigits(sym);
   return tick > 0 ? NormalizeDouble(MathRound(p / tick) * tick, dg) : NormalizeDouble(p, dg);
  }

int VolDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step - MathRound(step)) > 1e-9) { step *= 10; d++; }
   return d;
  }

string ReadKeyFile(const string name)
  {
   int h = FileOpen(name, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return "";
   string raw = FileReadString(h);
   FileClose(h);
   // Keep printable ASCII only: drops a Notepad UTF-8 BOM, spaces, tabs and line breaks.
   string key = "";
   for(int i = 0; i < StringLen(raw); i++)
     {
      ushort c = StringGetCharacter(raw, i);
      if(c > 32 && c < 127) key += ShortToString(c);
     }
   if(key != "")
      PrintFormat("AITrader: key loaded from %s (%s...%s)", name, StringSubstr(key, 0, 4), StringSubstr(key, StringLen(key) - 4));
   return key;
  }

void Notify(string msg)
  {
   g_lastEvent = TimeToString(TimeCurrent(), TIME_MINUTES) + " " + msg;
   Print("AITrader: ", msg);
  }

void LogRow(string stage, string sym, string action, double conf, double risk, double sl, double tp,
         double lots, string status, string reason)
  {
   if(sym == _Symbol && (stage == "ENTRY" || stage == "MANAGE" || stage == "CLOSE")) DrawDecision(stage, action, status, conf, reason);
   int h = FileOpen(InpLogFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
      FileWrite(h, "time", "stage", "symbol", "action", "confidence", "risk_pct", "sl", "tp", "lots", "status", "reason");
   FileSeek(h, 0, SEEK_END);
   StringReplace(reason, ",", ";"); StringReplace(reason, "\n", " ");
   StringReplace(status, ",", ";");
   int dg = sym == "" ? 5 : SymDigits(sym);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), stage, sym, action,
             DoubleToString(conf, 2), DoubleToString(risk, 2), DoubleToString(sl, dg), DoubleToString(tp, dg),
             DoubleToString(lots, 2), status, reason);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Dashboard panel: dark rectangle + one label per line              |
//+------------------------------------------------------------------+

string g_pTxt[];
color  g_pClr[];

void PanelAdd(string text, color c)
  {
   int n = ArraySize(g_pTxt);
   ArrayResize(g_pTxt, n + 1); ArrayResize(g_pClr, n + 1);
   g_pTxt[n] = StringSubstr(text, 0, 63); g_pClr[n] = c; // OBJ_LABEL limit
  }

// Adds 'text' under a short heading, wrapping long text onto indented lines.
void PanelAddWrapped(string head, string text, color c)
  {
   string pad = "            ";
   string prefix = StringSubstr(head + pad, 0, 11) + " ";
   int width = MathMax(30, MathMin(InpPanelWrapChars, 63) - 12); // OBJ_LABEL text is cut at 63 chars
   while(StringLen(text) > width)
     {
      int cut = width;
      for(int i = width; i > width / 2; i--)
         if(StringGetCharacter(text, i) == ' ') { cut = i; break; }
      PanelAdd(prefix + StringSubstr(text, 0, cut), c);
      text = StringSubstr(text, cut);
      StringTrimLeft(text);
      prefix = StringSubstr(pad, 0, 12);
     }
   PanelAdd(prefix + text, c);
  }

void UpdateDashboard()
  {
   if(!InpShowPanel) { ObjectsDeleteAll(0, PANEL_PREFIX); return; }
   ArrayResize(g_pTxt, 0); ArrayResize(g_pClr, 0);

   double dayEq = DayStartEquity(), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPct = dayEq > 0 ? (eq - dayEq) / dayEq * 100 : 0.0;
   string pausedWhy = !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)
                      ? "PAUSED - toolbar Algo Trading is off (or EA moved to VPS)"
                      : "PAUSED - tick Allow Algo Trading in the EA's Common tab";
   string status = !AlgoTradingOn() ? pausedWhy :
                   g_haltedToday ? "HALTED - daily loss limit" : (InpDryRun ? "DRY RUN - no orders sent" : "LIVE TRADING");
   color  stClr  = !AlgoTradingOn() ? CLR_HEAD : g_haltedToday ? CLR_BAD : (InpDryRun ? CLR_WARN : CLR_BAD);

   PanelAdd("AI TRADER EA", CLR_TITLE);
   PanelAdd(status, stClr);
   PanelAdd("", CLR_TEXT);
   PanelAddWrapped("STRATEGY", StringFormat("%s | %s | %s", ModeName(), ProfileName(),
                   StringFormat("%s session %s", SessionName(), SessionWindowText())), CLR_TEXT);
   PanelAddWrapped("SESSION", InSession() ? "OPEN - entries allowed" : "CLOSED - no new entries",
                   InSession() ? CLR_GOOD : CLR_WARN);
   PanelAddWrapped("CLOCKS", LocalClocks(), CLR_HEAD);
   PanelAddWrapped("AI", StringFormat("%s | last: %s | calls %d/%d", ProviderChain(), g_lastProvider,
                   g_calls, g_cfg.maxCalls), g_calls >= g_cfg.maxCalls ? CLR_BAD : CLR_TEXT);
   PanelAddWrapped("TIMEFRAMES", StringFormat("scan %s, manage %s | %d symbols", TfName(g_cfg.scanTF),
                   TfName(g_cfg.manageTF), ArraySize(g_syms)), CLR_TEXT);
   PanelAddWrapped("LIMITS", StringFormat("risk/trade %.2f%% | min conf %.2f | min R:R %.1f | daily loss %.1f%%",
                   g_cfg.riskPct, g_cfg.minConf, g_cfg.minRR, InpMaxDailyLossPct), CLR_TEXT);
   PanelAddWrapped("DAY P/L", StringFormat("%+.2f%%", dayPct), dayPct > 0 ? CLR_GOOD : (dayPct < 0 ? CLR_BAD : CLR_TEXT));
   double openRisk = OpenRiskPct();
   if(g_sizingText != "")
      PanelAddWrapped("SIZING", g_sizingText, g_sizingState == 2 ? CLR_GOOD : (g_sizingState == 1 ? CLR_WARN : CLR_BAD));
   PanelAddWrapped("EXPOSURE", StringFormat("open risk %.2f%% / %.2f%% | positions %d/%d | trades today %d/%d",
                   openRisk, InpMaxTotalRiskPct, CountPositions(), g_cfg.maxPositions,
                   CountTodayEntries(), g_cfg.maxTradesDay),
                   openRisk >= InpMaxTotalRiskPct - 0.01 ? CLR_WARN : CLR_TEXT);
   if(InpNewsFilter)
     {
      string nw;
      bool blk = NewsBlocked(nw);
      PanelAddWrapped("NEWS", blk ? "BLOCKED - " + nw : NextNewsText(), blk ? CLR_BAD : CLR_TEXT);
     }
   int sn, sw; double snet, spf, sdd, sddp, sR;
   CalcStats(0, sn, sw, snet, spf, sdd, sddp, sR);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   if(sn == 0)
      PanelAddWrapped("RESULTS", "no closed trades yet", CLR_HEAD);
   else
     {
      PanelAddWrapped("RESULTS", StringFormat("%d trades | win %.0f%% | net %+.2f %s | PF %.2f", sn, sw * 100.0 / sn, snet, cur, spf),
                      snet > 0 ? CLR_GOOD : (snet < 0 ? CLR_BAD : CLR_TEXT));
      PanelAddWrapped("", StringFormat("max DD %.2f %s (%.1f%%) | avg %+.2fR", sdd, cur, sddp, sR), CLR_TEXT);
     }
   if(InpReviewMode == REVIEW_SHADOW && sn > 0)
      PanelAddWrapped("SHADOW", ShadowSplitText(), CLR_HEAD);
   bool proven = sn >= 30 && snet > 0 && spf > 1.2;
   PanelAddWrapped("PROOF", proven ? "criteria met: 30+ trades, net > 0, PF > 1.2"
                   : StringFormat("%d/30 trades | needs net > 0 and PF > 1.2", sn), proven ? CLR_GOOD : CLR_WARN);
   PanelAdd("", CLR_TEXT);
   PanelAddWrapped("LAST CHECK", g_lastScan, CLR_TEXT);
   PanelAddWrapped("LAST EVENT", g_lastEvent, CLR_HEAD);
   DrawPanel();
  }

void DrawPanel()
  {
   int n = ArraySize(g_pTxt);
   // Size from the screen DPI so Windows display scaling (125%, 150%, ...) does not clip text.
   // Consolas is monospaced: character width ~0.55 em, line height ~1.35 em.
   double dpi   = (double)MathMax(96, (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI));
   double emPx  = InpPanelFontSize * dpi / 72.0;
   int    pad   = (int)MathRound(emPx * 0.6);
   int    lineH = (int)MathCeil(emPx * 1.35);
   int    maxChars = 1;
   for(int i = 0; i < n; i++) maxChars = MathMax(maxChars, StringLen(g_pTxt[i]));
   int    maxW  = (int)MathCeil(maxChars * emPx * 0.56);
   int    panelH = n * lineH + 2 * pad;

   // keep the whole panel inside the chart window
   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS, 0);
   int x = (int)MathRound(InpPanelX * dpi / 96.0);
   int y = (int)MathRound(InpPanelY * dpi / 96.0);
   if(chartH > 0 && y + panelH > chartH) y = MathMax(0, chartH - panelH - 4);

   string bg = PANEL_PREFIX + "bg";
   if(ObjectFind(0, bg) < 0)
     {
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, maxW + 2 * pad);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, panelH);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, CLR_PANEL_BG);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, CLR_PANEL_BORDER);

   for(int i = 0; i < n; i++)
     {
      string name = PANEL_PREFIX + "L" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
        }
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFontSize);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x + pad);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y + pad + i * lineH);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_pClr[i]);
      ObjectSetString(0, name, OBJPROP_TEXT, g_pTxt[i] == "" ? " " : g_pTxt[i]);
     }
   // remove labels left over from a longer previous frame
   for(int i = n; ObjectFind(0, PANEL_PREFIX + "L" + IntegerToString(i)) >= 0; i++)
      ObjectDelete(0, PANEL_PREFIX + "L" + IntegerToString(i));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+

//+==================================================================+
//| MARKET CONTEXT & PERFORMANCE                                     |
//|  1 news filter   2 performance stats   3 key levels              |
//|  4 higher TFs    5 volume profile      6 tick-flow proxy         |
//|  7 self-review (recent trades fed back to the entry model)       |
//+==================================================================+

//--- small helpers --------------------------------------------------
string Px(string sym, double v) { return DoubleToString(v, SymDigits(sym)); }

string RelMin(long minutes)
  {
   long a = minutes < 0 ? -minutes : minutes;
   string t = a >= 60 ? StringFormat("%dh%02d", (int)(a / 60), (int)(a % 60)) : StringFormat("%d min", (int)a);
   return minutes >= 0 ? "in " + t : t + " ago";
  }

// Server-time equivalent of a GMT time (broker server offset, rounded to 30 min).
datetime GmtToServer(datetime gmt)
  {
   long off = (long)TimeTradeServer() - (long)TimeGMT();
   off = (long)MathRound(off / 1800.0) * 1800;
   return (datetime)((long)gmt + off);
  }

//+------------------------------------------------------------------+
//| 1. NEWS FILTER - MT5 built-in economic calendar (server time)     |
//+------------------------------------------------------------------+
void LoadNews()
  {
   if(!InpNewsFilter) return;
   if(g_newsLoaded != 0 && TimeCurrent() - g_newsLoaded < 600) return; // refresh every 10 min
   g_newsLoaded = TimeCurrent();
   ArrayResize(g_news, 0);

   string curs[];
   int nc = StringSplit(InpNewsCurrencies, ',', curs);
   datetime from = TimeTradeServer() - 3 * 3600, to = TimeTradeServer() + 36 * 3600;
   for(int c = 0; c < nc; c++)
     {
      string cur = curs[c];
      StringTrimLeft(cur); StringTrimRight(cur); StringToUpper(cur);
      if(cur == "") continue;
      MqlCalendarValue vals[];
      ResetLastError();
      int n = CalendarValueHistory(vals, from, to, NULL, cur);
      if(n <= 0)
        {
         if(!g_newsWarned && GetLastError() != 0)
           { PrintFormat("AITrader: economic calendar unavailable for %s (error %d) - news filter inactive", cur, GetLastError()); g_newsWarned = true; }
         continue;
        }
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev)) continue;
         int imp = (int)ev.importance; // 0 none, 1 low, 2 moderate, 3 high
         if(imp < InpNewsMinImportance) continue;
         int k = ArraySize(g_news);
         ArrayResize(g_news, k + 1);
         g_news[k].t = vals[i].time; g_news[k].name = ev.name; g_news[k].cur = cur; g_news[k].imp = imp;
        }
     }
   // sort by time
   for(int i = 1; i < ArraySize(g_news); i++)
      for(int j = i; j > 0 && g_news[j].t < g_news[j - 1].t; j--)
        { NewsItem tmp = g_news[j]; g_news[j] = g_news[j - 1]; g_news[j - 1] = tmp; }
  }

// True while inside [event - before, event + after]; 'what' describes the event.
bool NewsBlocked(string &what)
  {
   if(!InpNewsFilter) return false;
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_news); i++)
     {
      if(now >= g_news[i].t - InpNewsBeforeMin * 60 && now <= g_news[i].t + InpNewsAfterMin * 60)
        {
         what = StringFormat("%s %s %s", g_news[i].cur, g_news[i].name, RelMin(((long)g_news[i].t - (long)now) / 60));
         return true;
        }
     }
   return false;
  }

string NextNewsText()
  {
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_news); i++)
      if(g_news[i].t >= now)
         return StringFormat("next %s %s %s", g_news[i].cur, g_news[i].name, RelMin(((long)g_news[i].t - (long)now) / 60));
   return "no high-impact news in the next 36h";
  }

string NewsContext()
  {
   if(!InpNewsFilter) return "";
   datetime now = TimeTradeServer();
   string s = StringFormat("ECONOMIC CALENDAR (%s, importance >= %s, server time):\n", InpNewsCurrencies,
                           InpNewsMinImportance >= 3 ? "high" : (InpNewsMinImportance == 2 ? "moderate" : "low"));
   int shown = 0;
   for(int i = 0; i < ArraySize(g_news) && shown < 8; i++)
     {
      long rel = ((long)g_news[i].t - (long)now) / 60;
      if(rel < -120 || rel > 12 * 60) continue;
      s += StringFormat("  %s %s %s (%s)\n", TimeToString(g_news[i].t, TIME_MINUTES), g_news[i].cur, g_news[i].name, RelMin(rel));
      shown++;
     }
   if(shown == 0) s += "  none from 2h ago to 12h ahead\n";
   string what;
   if(NewsBlocked(what)) s += "  NEWS WINDOW ACTIVE: new entries are blocked by the EA (" + what + ")\n";
   return s;
  }

//+------------------------------------------------------------------+
//| 2 + 7. CLOSED-TRADE HISTORY (this EA's magic only)                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) g_tradesDirty = true;
  }

string DealReasonText(long r)
  {
   if(r == DEAL_REASON_SL)     return "SL";
   if(r == DEAL_REASON_TP)     return "TP";
   if(r == DEAL_REASON_EXPERT) return "EA/AI";
   if(r == DEAL_REASON_SO)     return "stop-out";
   return "manual";
  }

void LoadTrades()
  {
   if(!g_tradesDirty && g_tradesLoaded != 0 && TimeCurrent() - g_tradesLoaded < 300) return;
   g_tradesDirty = false;
   g_tradesLoaded = TimeCurrent();
   ArrayResize(g_trades, 0);
   if(!HistorySelect(InpStatsFrom, TimeCurrent() + 3600)) return;
   int total = HistoryDealsTotal();

   // pass 1: positions opened by this EA
   ulong ids[];
   for(int i = 0; i < total; i++)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0 || (ulong)HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      ulong id = (ulong)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      bool seen = false;
      for(int k = 0; k < ArraySize(ids); k++) if(ids[k] == id) { seen = true; break; }
      if(!seen) { int k = ArraySize(ids); ArrayResize(ids, k + 1); ids[k] = id; }
     }

   // pass 2: aggregate every deal of those positions (entry, partials, SL/TP closes)
   for(int k = 0; k < ArraySize(ids); k++)
     {
      ClosedTrade c;
      c.posId = ids[k]; c.sym = ""; c.dir = 0; c.openTime = 0; c.closeTime = 0;
      c.openPrice = 0; c.closePrice = 0; c.volume = 0; c.net = 0; c.sl = 0; c.rMult = 0; c.exitReason = ""; c.shadow = "";
      double inVol = 0, outVol = 0, outValue = 0;
      ulong entryOrder = 0;
      for(int i = 0; i < total; i++)
        {
         ulong t = HistoryDealGetTicket(i);
         if(t == 0 || (ulong)HistoryDealGetInteger(t, DEAL_POSITION_ID) != ids[k]) continue;
         double v = HistoryDealGetDouble(t, DEAL_VOLUME), p = HistoryDealGetDouble(t, DEAL_PRICE);
         c.net += HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_COMMISSION) +
                  HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_FEE);
         long entry = HistoryDealGetInteger(t, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN)
           {
            if(inVol == 0)
              {
               c.openTime   = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
               c.openPrice  = p;
               c.sym        = HistoryDealGetString(t, DEAL_SYMBOL);
               c.dir        = HistoryDealGetInteger(t, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1;
               entryOrder   = (ulong)HistoryDealGetInteger(t, DEAL_ORDER);
               string cm    = HistoryDealGetString(t, DEAL_COMMENT);
               int sp       = StringFind(cm, " s");
               if(sp >= 0) c.shadow = StringSubstr(cm, sp + 2, 1);
              }
            inVol += v;
           }
         else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            outVol += v; outValue += v * p;
            c.closeTime  = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
            c.exitReason = DealReasonText(HistoryDealGetInteger(t, DEAL_REASON));
           }
        }
      if(inVol <= 0 || outVol < inVol - 1e-8) continue; // still open
      c.volume = inVol;
      c.closePrice = outValue / outVol;
      if(entryOrder != 0) c.sl = HistoryOrderGetDouble(entryOrder, ORDER_SL);
      double riskMoney = c.sl > 0 ? LossBetween(c.sym, c.dir > 0, inVol, c.openPrice, c.sl) : 0;
      if(riskMoney > 0) c.rMult = c.net / riskMoney;
      int n = ArraySize(g_trades);
      ArrayResize(g_trades, n + 1);
      g_trades[n] = c;
     }
   // sort by close time
   for(int i = 1; i < ArraySize(g_trades); i++)
      for(int j = i; j > 0 && g_trades[j].closeTime < g_trades[j - 1].closeTime; j--)
        { ClosedTrade tmp = g_trades[j]; g_trades[j] = g_trades[j - 1]; g_trades[j - 1] = tmp; }
  }

// Stats over the most recent 'lastN' trades (0 = all).
void CalcStats(int lastN, int &n, int &wins, double &net, double &pf, double &maxDD, double &maxDDPct, double &avgR)
  {
   int total = ArraySize(g_trades);
   int start = (lastN > 0 && total > lastN) ? total - lastN : 0;
   n = 0; wins = 0; net = 0; pf = 0; maxDD = 0; maxDDPct = 0; avgR = 0;
   double gp = 0, gl = 0, cum = 0, peak = 0, sumR = 0;
   int nR = 0;
   double startBal = AccountInfoDouble(ACCOUNT_BALANCE);
   for(int i = start; i < total; i++) startBal -= g_trades[i].net; // approx (ignores deposits)
   for(int i = start; i < total; i++)
     {
      double x = g_trades[i].net;
      n++; net += x; cum += x;
      if(x > 0) { wins++; gp += x; } else gl -= x;
      if(cum > peak) peak = cum;
      if(peak - cum > maxDD) { maxDD = peak - cum; maxDDPct = (startBal + peak) > 0 ? maxDD / (startBal + peak) * 100 : 0; }
      if(g_trades[i].rMult != 0) { sumR += g_trades[i].rMult; nR++; }
     }
   pf = gl > 0 ? gp / gl : (gp > 0 ? 99.0 : 0.0);
   avgR = nR > 0 ? sumR / nR : 0;
  }

string SelfReviewContext()
  {
   if(!InpSelfReview) return "";
   LoadTrades();
   int total = ArraySize(g_trades);
   if(total == 0) return "YOUR RECENT TRADES: none closed yet.\n";
   int n, wins; double net, pf, dd, ddp, avgR;
   CalcStats(20, n, wins, net, pf, dd, ddp, avgR);
   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string s = StringFormat("YOUR RECENT TRADES (this EA; last %d: %d wins, net %.2f %s, profit factor %.2f, avg %.2fR). Newest first:\n",
                           n, wins, net, cur, pf, avgR);
   int shown = 0;
   for(int i = total - 1; i >= 0 && shown < InpSelfReviewTrades; i--, shown++)
     {
      ClosedTrade c = g_trades[i];
      s += StringFormat("  %s %s %s in %s out %s via %s | %+.2f %s (%+.2fR) | held %d min\n",
                        TimeToString(c.openTime, TIME_DATE | TIME_MINUTES), c.dir > 0 ? "BUY" : "SELL", c.sym,
                        Px(c.sym, c.openPrice), Px(c.sym, c.closePrice), c.exitReason, c.net, cur, c.rMult,
                        (int)(((long)c.closeTime - (long)c.openTime) / 60));
     }
   return s;
  }

//+------------------------------------------------------------------+
//| 3. KEY LEVELS                                                     |
//+------------------------------------------------------------------+
string KeyLevelsContext(string sym)
  {
   if(!InpKeyLevels) return "";
   string s = "KEY LEVELS:\n";
   MqlRates d[]; ArraySetAsSeries(d, true);
   if(CopyRates(sym, PERIOD_D1, 0, 2, d) == 2)
      s += StringFormat("  previous day H %s L %s C %s | today O %s H %s L %s\n", Px(sym, d[1].high), Px(sym, d[1].low),
                        Px(sym, d[1].close), Px(sym, d[0].open), Px(sym, d[0].high), Px(sym, d[0].low));
   MqlRates w[]; ArraySetAsSeries(w, true);
   if(CopyRates(sym, PERIOD_W1, 0, 2, w) == 2)
      s += StringFormat("  week open %s | previous week H %s L %s\n", Px(sym, w[0].open), Px(sym, w[1].high), Px(sym, w[1].low));

   datetime gmt = TimeGMT(), nowSrv = TimeTradeServer();
   datetime gmtMidnight = (datetime)((long)gmt - (long)gmt % 86400);
   // Asian range: Tokyo 09-17 = 00-08 GMT
   datetime aFrom = GmtToServer(gmtMidnight), aTo = GmtToServer(gmtMidnight + 8 * 3600);
   if(nowSrv > aFrom)
     {
      MqlRates a[];
      int n = CopyRates(sym, PERIOD_M5, aFrom, nowSrv < aTo ? nowSrv : aTo, a);
      if(n > 0)
        {
         double hi = a[0].high, lo = a[0].low;
         for(int i = 1; i < n; i++) { hi = MathMax(hi, a[i].high); lo = MathMin(lo, a[i].low); }
         s += StringFormat("  Asian range today H %s L %s%s\n", Px(sym, hi), Px(sym, lo), nowSrv < aTo ? " (still forming)" : "");
        }
     }
   // session opens (08:00 local London / New York, DST-aware)
   datetime lon = GmtToServer(gmtMidnight + (8 * 60 - LondonOffsetMin(gmt)) * 60);
   datetime ny  = GmtToServer(gmtMidnight + (8 * 60 - NewYorkOffsetMin(gmt)) * 60);
   if(nowSrv > lon) s += "  London open price " + Px(sym, iOpen(sym, PERIOD_M5, iBarShift(sym, PERIOD_M5, lon))) + "\n";
   if(nowSrv > ny)  s += "  New York open price " + Px(sym, iOpen(sym, PERIOD_M5, iBarShift(sym, PERIOD_M5, ny))) + "\n";

   // round numbers
   double px = SymbolInfoDouble(sym, SYMBOL_BID);
   if(px > 0)
     {
      double minor = MathPow(10, MathFloor(MathLog10(px)) - 2), major = minor * 5;
      double below = MathFloor(px / major) * major, above = below + major;
      s += StringFormat("  round numbers: %s / %s (major), nearest %s step: %s / %s\n", Px(sym, below), Px(sym, above),
                        Px(sym, minor), Px(sym, MathFloor(px / minor) * minor), Px(sym, MathFloor(px / minor) * minor + minor));
     }
   return s;
  }

//+------------------------------------------------------------------+
//| 4. HIGHER-TIMEFRAME CONTEXT                                       |
//+------------------------------------------------------------------+
void HigherTFs(ENUM_TIMEFRAMES base, ENUM_TIMEFRAMES &a, ENUM_TIMEFRAMES &b)
  {
   if(base == PERIOD_M1)       { a = PERIOD_M5;  b = PERIOD_M15; }
   else if(base == PERIOD_M5)  { a = PERIOD_M15; b = PERIOD_H1; }
   else if(base <= PERIOD_M30) { a = PERIOD_H1;  b = PERIOD_H4; }
   else if(base <= PERIOD_H1)  { a = PERIOD_H4;  b = PERIOD_D1; }
   else                        { a = PERIOD_D1;  b = PERIOD_W1; }
  }

double EmaOf(const double &c[], int period)
  {
   int n = ArraySize(c);
   if(n < period) return 0;
   double e = 0;
   for(int i = 0; i < period; i++) e += c[i];
   e /= period;
   double k = 2.0 / (period + 1);
   for(int i = period; i < n; i++) e = c[i] * k + e * (1 - k);
   return e;
  }

double RsiOf(const double &c[], int period)
  {
   int n = ArraySize(c);
   if(n <= period) return 50;
   double g = 0, l = 0;
   for(int i = 1; i <= period; i++) { double d = c[i] - c[i - 1]; if(d > 0) g += d; else l -= d; }
   g /= period; l /= period;
   for(int i = period + 1; i < n; i++)
     {
      double d = c[i] - c[i - 1];
      g = (g * (period - 1) + (d > 0 ? d : 0)) / period;
      l = (l * (period - 1) + (d < 0 ? -d : 0)) / period;
     }
   return l == 0 ? 100 : 100 - 100 / (1 + g / l);
  }

string OneTfSummary(string sym, ENUM_TIMEFRAMES tf)
  {
   double c[];
   ArraySetAsSeries(c, false);
   int n = CopyClose(sym, tf, 1, 150, c); // oldest first, closed bars
   if(n < 60) return "";
   double e20 = EmaOf(c, 20), e50 = EmaOf(c, 50), rsi = RsiOf(c, 14), last = c[n - 1];
   string trend = (last > e20 && e20 > e50) ? "UP" : (last < e20 && e20 < e50) ? "DOWN" : "MIXED";
   MqlRates r[]; ArraySetAsSeries(r, true);
   int m = CopyRates(sym, tf, 1, 20, r);
   double hi = 0, lo = 0;
   if(m > 0) { hi = r[0].high; lo = r[0].low; for(int i = 1; i < m; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); } }
   string s = StringFormat("  %s: trend %s | close %s EMA20 %s EMA50 %s RSI14 %.1f | 20-bar high %s low %s\n    last 6 bars (o,h,l,c):",
                           TfName(tf), trend, Px(sym, last), Px(sym, e20), Px(sym, e50), rsi, Px(sym, hi), Px(sym, lo));
   for(int i = (int)MathMin(5, m - 1); i >= 0; i--)
      s += StringFormat(" [%s,%s,%s,%s]", Px(sym, r[i].open), Px(sym, r[i].high), Px(sym, r[i].low), Px(sym, r[i].close));
   return s + "\n";
  }

string HtfContext(string sym)
  {
   if(!InpHTFContext) return "";
   ENUM_TIMEFRAMES a, b;
   HigherTFs(g_cfg.scanTF, a, b);
   return "HIGHER TIMEFRAMES:\n" + OneTfSummary(sym, a) + OneTfSummary(sym, b);
  }

//+------------------------------------------------------------------+
//| 5. VOLUME PROFILE (from M1 tick volume)                           |
//+------------------------------------------------------------------+
bool VolumeProfile(string sym, datetime from, datetime to, double &poc, double &vah, double &val)
  {
   MqlRates r[];
   int n = CopyRates(sym, PERIOD_M1, from, to, r);
   if(n < 30) return false;
   double lo = r[0].low, hi = r[0].high;
   for(int i = 1; i < n; i++) { lo = MathMin(lo, r[i].low); hi = MathMax(hi, r[i].high); }
   double bin = MathMax(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), r[n - 1].close * 0.0002);
   if(bin <= 0) return false;
   int nb = (int)((hi - lo) / bin) + 1;
   while(nb > 1500) { bin *= 2; nb = (int)((hi - lo) / bin) + 1; }
   double v[];
   ArrayResize(v, nb);
   ArrayInitialize(v, 0);
   double total = 0;
   for(int i = 0; i < n; i++)
     {
      int a = (int)((r[i].low - lo) / bin), b = (int)((r[i].high - lo) / bin);
      a = (int)MathMax(0, MathMin(nb - 1, a)); b = (int)MathMax(a, MathMin(nb - 1, b));
      double per = (double)r[i].tick_volume / (b - a + 1);
      for(int k = a; k <= b; k++) v[k] += per;
      total += (double)r[i].tick_volume;
     }
   if(total <= 0) return false;
   int p = 0;
   for(int k = 1; k < nb; k++) if(v[k] > v[p]) p = k;
   int lo_i = p, hi_i = p;
   double acc = v[p];
   while(acc < 0.7 * total)
     {
      double up = hi_i + 1 < nb ? v[hi_i + 1] : -1, dn = lo_i - 1 >= 0 ? v[lo_i - 1] : -1;
      if(up < 0 && dn < 0) break;
      if(up >= dn) { hi_i++; acc += up; } else { lo_i--; acc += dn; }
     }
   poc = lo + (p + 0.5) * bin;
   vah = lo + (hi_i + 1) * bin;
   val = lo + lo_i * bin;
   return true;
  }

string VolumeProfileContext(string sym)
  {
   if(!InpVolumeProfile) return "";
   MqlRates d[]; ArraySetAsSeries(d, true);
   if(CopyRates(sym, PERIOD_D1, 0, 2, d) != 2) return "";
   string s = "VOLUME PROFILE (from broker tick volume, 70% value area):\n";
   double poc, vah, val;
   if(VolumeProfile(sym, d[1].time, d[0].time - 1, poc, vah, val))
      s += StringFormat("  previous day: POC %s, value area %s - %s\n", Px(sym, poc), Px(sym, val), Px(sym, vah));
   if(VolumeProfile(sym, d[0].time, TimeTradeServer(), poc, vah, val))
      s += StringFormat("  today so far: POC %s, value area %s - %s\n", Px(sym, poc), Px(sym, val), Px(sym, vah));
   return s;
  }

//+------------------------------------------------------------------+
//| 6. TICK-FLOW PROXY (quote up-ticks vs down-ticks)                 |
//+------------------------------------------------------------------+
string TickFlowContext(string sym)
  {
   if(!InpTickFlow) return "";
   MqlTick last;
   if(!SymbolInfoTick(sym, last)) return "";
   ulong to = (ulong)last.time_msc, from = to - 3600000;
   MqlTick t[];
   int n = CopyTicksRange(sym, t, COPY_TICKS_INFO, from, to);
   if(n < 50) return "";

   int    wins[] = {5, 15, 60};
   string s = "TICK-FLOW PROXY (counts of quote up-ticks vs down-ticks; NOT real exchange volume - weight lightly):\n";
   for(int w = 0; w < 3; w++)
     {
      long start = (long)to - (long)wins[w] * 60000;
      int up = 0, dn = 0;
      double firstMid = 0, lastMid = 0, prev = 0;
      for(int i = 0; i < n; i++)
        {
         if(t[i].time_msc < start) { prev = (t[i].bid + t[i].ask) / 2; continue; }
         double mid = (t[i].bid + t[i].ask) / 2;
         if(firstMid == 0) firstMid = mid;
         if(prev > 0) { if(mid > prev) up++; else if(mid < prev) dn++; }
         prev = mid; lastMid = mid;
        }
      int tot = up + dn;
      double chg = lastMid - firstMid;
      s += StringFormat("  last %d min: up %d / down %d (delta %+d, %+.0f%%), price change %s%s\n", wins[w], up, dn, up - dn,
                        tot > 0 ? (up - dn) * 100.0 / tot : 0.0, chg >= 0 ? "+" : "", DoubleToString(chg, SymDigits(sym)));
     }
   // cumulative delta path in 10-minute steps over the last hour
   string path = "  60-min cumulative delta, 10-min steps:";
   int cum = 0, j = 0;
   double prevMid = 0;
   for(int step = 1; step <= 6; step++)
     {
      long edge = (long)from + (long)step * 600000;
      for(; j < n && t[j].time_msc <= edge; j++)
        {
         double mid = (t[j].bid + t[j].ask) / 2;
         if(prevMid > 0) { if(mid > prevMid) cum++; else if(mid < prevMid) cum--; }
         prevMid = mid;
        }
      path += StringFormat(" %+d", cum);
     }
   return s + path + "\n";
  }

//+==================================================================+
//| CHART VISUALS (chart symbol only)                                 |
//|  key levels + Asian box + session lines, volume profile          |
//|  histogram, news windows, AI decision markers, closed trades      |
//+==================================================================+
void VzBase(string name)
  {
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

void VzTrend(string id, datetime t1, double p1, datetime t2, double p2, color c, ENUM_LINE_STYLE st, int w, string tip)
  {
   string n = VIZ_PREFIX + id;
   if(ObjectFind(0, n) < 0) { ObjectCreate(0, n, OBJ_TREND, 0, t1, p1, t2, p2); VzBase(n); }
   ObjectMove(0, n, 0, t1, p1); ObjectMove(0, n, 1, t2, p2);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, w);
   ObjectSetInteger(0, n, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, tip);
  }

void VzText(string id, datetime t, double p, string txt, color c, ENUM_ANCHOR_POINT anchor, int size, string tip = "")
  {
   string n = VIZ_PREFIX + id;
   if(ObjectFind(0, n) < 0) { ObjectCreate(0, n, OBJ_TEXT, 0, t, p); VzBase(n); }
   ObjectMove(0, n, 0, t, p);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, anchor);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, tip == "" ? txt : tip);
  }

void VzRect(string id, datetime t1, double p1, datetime t2, double p2, color c, bool back, string tip)
  {
   string n = VIZ_PREFIX + id;
   if(ObjectFind(0, n) < 0) { ObjectCreate(0, n, OBJ_RECTANGLE, 0, t1, p1, t2, p2); VzBase(n); }
   ObjectMove(0, n, 0, t1, p1); ObjectMove(0, n, 1, t2, p2);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FILL, true);
   ObjectSetInteger(0, n, OBJPROP_BACK, back);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, tip);
  }

void VzVLine(string id, datetime t, color c, string txt)
  {
   string n = VIZ_PREFIX + id;
   if(ObjectFind(0, n) < 0) { ObjectCreate(0, n, OBJ_VLINE, 0, t, 0); VzBase(n); }
   ObjectMove(0, n, 0, t, 0);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, n, OBJPROP_BACK, true);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, txt);
  }

// A labelled horizontal level from t1 to just right of the last bar.
void VzLevel(string id, datetime t1, double p, color c, ENUM_LINE_STYLE st, string label)
  {
   if(p <= 0) return;
   datetime t2 = TimeCurrent() + PeriodSeconds();
   string tip = label + " " + Px(_Symbol, p);
   VzTrend("L_" + id, t1, p, t2, p, c, st, 1, tip);
   VzText("LT_" + id, t2, p, (label == "" ? "" : label + " ") + Px(_Symbol, p), c, ANCHOR_RIGHT_LOWER, 7, tip);
  }

void DrawLevels()
  {
   string sym = _Symbol;
   MqlRates d[]; ArraySetAsSeries(d, true);
   if(CopyRates(sym, PERIOD_D1, 0, 2, d) != 2) return;
   datetime today = d[0].time;
   VzLevel("PDH", today, d[1].high, VZ_PDHL, STYLE_SOLID, "PDH");
   VzLevel("PDL", today, d[1].low,  VZ_PDHL, STYLE_SOLID, "PDL");
   VzLevel("PDC", today, d[1].close, VZ_OPEN, STYLE_DOT, "PDC");
   VzLevel("DO",  today, d[0].open, VZ_OPEN, STYLE_DASH, "Day open");

   MqlRates w[]; ArraySetAsSeries(w, true);
   if(CopyRates(sym, PERIOD_W1, 0, 2, w) == 2)
     {
      VzLevel("PWH", w[0].time, w[1].high, VZ_WEEK, STYLE_DASH, "PWH");
      VzLevel("PWL", w[0].time, w[1].low,  VZ_WEEK, STYLE_DASH, "PWL");
      VzLevel("WO",  w[0].time, w[0].open, VZ_WEEK, STYLE_DOT,  "Week open");
     }

   // Asian range box + session opens (DST-aware)
   datetime gmt = TimeGMT(), now = TimeTradeServer();
   datetime gm0 = (datetime)((long)gmt - (long)gmt % 86400);
   datetime aFrom = GmtToServer(gm0), aTo = GmtToServer(gm0 + 8 * 3600);
   if(InpVizAsianBox && now > aFrom)
     {
      MqlRates a[];
      int n = CopyRates(sym, PERIOD_M5, aFrom, now < aTo ? now : aTo, a);
      if(n > 0)
        {
         double hi = a[0].high, lo = a[0].low;
         for(int i = 1; i < n; i++) { hi = MathMax(hi, a[i].high); lo = MathMin(lo, a[i].low); }
         string tip = StringFormat("Asian range %s - %s", Px(sym, lo), Px(sym, hi));
         VzRect("ASIA", aFrom, hi, now < aTo ? now : aTo, lo, VZ_ASIA, true, tip + (now < aTo ? " (forming)" : ""));
         VzText("ASIAT", aFrom, hi, "Asian range", C'90,110,150', ANCHOR_LEFT_LOWER, 7, tip);
        }
     }
   datetime lon = GmtToServer(gm0 + (8 * 60 - LondonOffsetMin(gmt)) * 60);
   datetime ny  = GmtToServer(gm0 + (8 * 60 - NewYorkOffsetMin(gmt)) * 60);
   VzVLine("V_LDN", lon, VZ_LDN, "London open 08:00 local");
   VzVLine("V_NY",  ny,  VZ_NY,  "New York open 08:00 local");
   if(now > lon) VzLevel("LDNO", lon, iOpen(sym, PERIOD_M5, iBarShift(sym, PERIOD_M5, lon)), VZ_LDN, STYLE_DASH, "LDN open");
   if(now > ny)  VzLevel("NYO",  ny,  iOpen(sym, PERIOD_M5, iBarShift(sym, PERIOD_M5, ny)),  VZ_NY,  STYLE_DASH, "NY open");

   // nearest major round numbers
   double px = SymbolInfoDouble(sym, SYMBOL_BID);
   if(px > 0)
     {
      double major = MathPow(10, MathFloor(MathLog10(px)) - 2) * 5;
      double below = MathFloor(px / major) * major;
      VzLevel("RN1", today, below, VZ_ROUND, STYLE_DOT, "");
      VzLevel("RN2", today, below + major, VZ_ROUND, STYLE_DOT, "");
     }
  }

// Today's volume profile as a histogram in the empty space right of price.
void DrawProfile()
  {
   ObjectsDeleteAll(0, VIZ_PREFIX + "VP");
   string sym = _Symbol;
   MqlRates d[]; ArraySetAsSeries(d, true);
   if(CopyRates(sym, PERIOD_D1, 0, 1, d) != 1) return;
   MqlRates r[];
   int n = CopyRates(sym, PERIOD_M1, d[0].time, TimeTradeServer(), r);
   if(n < 30) return;
   double lo = r[0].low, hi = r[0].high;
   for(int i = 1; i < n; i++) { lo = MathMin(lo, r[i].low); hi = MathMax(hi, r[i].high); }
   int rows = 48;
   double bin = (hi - lo) / rows;
   if(bin <= 0) return;
   double v[]; ArrayResize(v, rows); ArrayInitialize(v, 0);
   double total = 0;
   for(int i = 0; i < n; i++)
     {
      int a = (int)MathMax(0, MathMin(rows - 1, (int)((r[i].low - lo) / bin)));
      int b = (int)MathMax(a, MathMin(rows - 1, (int)((r[i].high - lo) / bin)));
      double per = (double)r[i].tick_volume / (b - a + 1);
      for(int k = a; k <= b; k++) v[k] += per;
      total += (double)r[i].tick_volume;
     }
   int p = 0;
   for(int k = 1; k < rows; k++) if(v[k] > v[p]) p = k;
   int lo_i = p, hi_i = p;
   double acc = v[p];
   while(acc < 0.7 * total)
     {
      double up = hi_i + 1 < rows ? v[hi_i + 1] : -1, dn = lo_i - 1 >= 0 ? v[lo_i - 1] : -1;
      if(up < 0 && dn < 0) break;
      if(up >= dn) { hi_i++; acc += up; } else { lo_i--; acc += dn; }
     }
   datetime x0 = TimeCurrent() + PeriodSeconds() * 4;
   int maxBars = 28;
   for(int k = 0; k < rows; k++)
     {
      if(v[k] <= 0) continue;
      datetime x1 = (datetime)((long)x0 + (long)MathMax(1, (int)(v[k] / v[p] * maxBars)) * PeriodSeconds());
      color c = (k == p) ? VZ_POC : (k >= lo_i && k <= hi_i ? VZ_VA : VZ_VPOUT);
      VzRect("VP" + IntegerToString(k), x0, lo + k * bin, x1, lo + (k + 1) * bin - bin * 0.15, c, false,
             StringFormat("%s - %s  volume %.0f", Px(sym, lo + k * bin), Px(sym, lo + (k + 1) * bin), v[k]));
     }
   double poc = lo + (p + 0.5) * bin, vah = lo + (hi_i + 1) * bin, val = lo + lo_i * bin;
   datetime xl = (datetime)((long)x0 + (long)(maxBars + 1) * PeriodSeconds());
   VzText("VPT_POC", xl, poc, "POC " + Px(sym, poc), VZ_POC, ANCHOR_LEFT, 7);
   VzText("VPT_VAH", xl, vah, "VAH " + Px(sym, vah), C'110,150,210', ANCHOR_LEFT, 7);
   VzText("VPT_VAL", xl, val, "VAL " + Px(sym, val), C'110,150,210', ANCHOR_LEFT, 7);
   VzText("VPT_T", x0, hi, "Today's volume profile", C'110,120,140', ANCHOR_LEFT_LOWER, 7);
  }

void DrawNewsMarks()
  {
   ObjectsDeleteAll(0, VIZ_PREFIX + "N");
   if(!InpNewsFilter) return;
   datetime now = TimeTradeServer();
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i = 0; i < ArraySize(g_news); i++)
     {
      long rel = ((long)g_news[i].t - (long)now) / 60;
      if(rel < -6 * 60 || rel > 24 * 60) continue;
      string txt = g_news[i].cur + " " + g_news[i].name;
      VzRect("NW" + IntegerToString(i), g_news[i].t - InpNewsBeforeMin * 60, px * 3,
             g_news[i].t + InpNewsAfterMin * 60, 0, VZ_NEWSBG, true, "No new entries: " + txt);
      VzVLine("NL" + IntegerToString(i), g_news[i].t, VZ_NEWS, txt + " " + TimeToString(g_news[i].t, TIME_MINUTES));
     }
  }

void DrawTrades()
  {
   ObjectsDeleteAll(0, VIZ_PREFIX + "T");
   int total = ArraySize(g_trades), shown = 0;
   for(int i = total - 1; i >= 0 && shown < 40; i--)
     {
      ClosedTrade c = g_trades[i];
      if(c.sym != _Symbol) continue;
      shown++;
      color col = c.net >= 0 ? C'60,200,120' : C'240,80,80';
      string tip = StringFormat("%s %.2f lots | %s -> %s | %+.2f %s (%+.2fR) | %s", c.dir > 0 ? "BUY" : "SELL", c.volume,
                                Px(c.sym, c.openPrice), Px(c.sym, c.closePrice), c.net, AccountInfoString(ACCOUNT_CURRENCY),
                                c.rMult, c.exitReason);
      string id = IntegerToString((long)c.posId);
      VzTrend("TL" + id, c.openTime, c.openPrice, c.closeTime, c.closePrice, col, STYLE_DOT, 2, tip);
      VzText("TT" + id, c.closeTime, c.closePrice, StringFormat(" %+.2f", c.net), col, ANCHOR_LEFT, 8, tip);
     }
  }

// Marker for each AI decision on the chart symbol (called from LogRow).
void DrawDecision(string stage, string action, string status, double conf, string reason)
  {
   if(!InpVizDecisions) return;
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int idx = SymbolIndex(_Symbol);
   double off = idx >= 0 ? Buf(g_hATR[idx]) * 0.4 : 0;
   int code; color c; double y; ENUM_ARROW_ANCHOR anc = ANCHOR_TOP;
   bool rejected = StringFind(status, "REJECTED") == 0 || StringFind(status, "IGNORED") == 0;
   bool isB = StringFind(action, "BUY") == 0, isS = StringFind(action, "SELL") == 0;
   if(stage == "ENTRY" && isB && !rejected)       { code = 233; c = C'60,200,120'; y = px - off; anc = ANCHOR_TOP; }
   else if(stage == "ENTRY" && isS && !rejected) { code = 234; c = C'240,80,80';  y = px + off; anc = ANCHOR_BOTTOM; }
   else if(rejected)                                          { code = 251; c = C'255,190,60'; y = px + off; anc = ANCHOR_BOTTOM; }
   else if(stage == "ENTRY")                                  { code = 159; c = C'120,130,150'; y = px + off; anc = ANCHOR_BOTTOM; }
   else                                                       { code = 115; c = C'0,190,255';  y = px - off; anc = ANCHOR_TOP; }
   string n = VIZ_PREFIX + "D" + IntegerToString(++g_vizSeq) + "_" + IntegerToString((long)TimeCurrent());
   if(!ObjectCreate(0, n, OBJ_ARROW, 0, TimeCurrent(), y)) return;
   VzBase(n);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_ANCHOR, anc);
   string tip = StringFormat("%s %s %s %s conf %.2f: %s", TimeToString(TimeCurrent(), TIME_MINUTES), stage, action,
                             status, conf, reason);
   ObjectSetString(0, n, OBJPROP_TOOLTIP, StringSubstr(tip, 0, 250));
   int k = ArraySize(g_vizMarkers);
   ArrayResize(g_vizMarkers, k + 1);
   g_vizMarkers[k] = n;
   if(ArraySize(g_vizMarkers) > InpVizMaxMarkers)
     {
      ObjectDelete(0, g_vizMarkers[0]);
      ArrayRemove(g_vizMarkers, 0, 1);
     }
   ChartRedraw(0);
  }

void DrawVisuals(bool force)
  {
   if(!force && g_vizLast != 0 && TimeCurrent() - g_vizLast < 30) return;
   g_vizLast = TimeCurrent();
   if(InpVizLevels)  DrawLevels();
   if(InpVizProfile) DrawProfile();
   if(InpVizNews)    DrawNewsMarks();
   if(InpVizTrades)  DrawTrades();
   ChartRedraw(0);
  }

void SetupChartForVisuals()
  {
   if(InpVizProfile)
     {
      ChartSetInteger(0, CHART_SHIFT, true);     // room on the right for the profile histogram
      ChartSetDouble(0, CHART_SHIFT_SIZE, 25);
     }
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS, true); // SL/TP lines of open positions
  }

// Results split by the shadow reviewer's verdict: does its opinion predict outcomes?
string ShadowSplitText()
  {
   int na = 0, nd = 0; double neta = 0, netd = 0, gpa = 0, gla = 0, gpd = 0, gld = 0;
   for(int i = 0; i < ArraySize(g_trades); i++)
     {
      double x = g_trades[i].net;
      if(g_trades[i].shadow == "A") { na++; neta += x; if(x > 0) gpa += x; else gla -= x; }
      if(g_trades[i].shadow == "D") { nd++; netd += x; if(x > 0) gpd += x; else gld -= x; }
     }
   if(na + nd == 0) return "no reviewed trades yet";
   return StringFormat("agreed %d (net %+.2f, PF %.2f) | disagreed %d (net %+.2f, PF %.2f)",
                       na, neta, gla > 0 ? gpa / gla : (gpa > 0 ? 99.0 : 0.0),
                       nd, netd, gld > 0 ? gpd / gld : (gpd > 0 ? 99.0 : 0.0));
  }

//+------------------------------------------------------------------+
//| POSITION-SIZING CHECK: can the minimum lot respect the risk %?    |
//+------------------------------------------------------------------+
// Widest stop distance (price units) the minimum lot allows at the current risk %; 0 if unknown.
double MaxStopForMinLot(string sym, double &lossPerUnit, double &unit)
  {
   double bid  = SymbolInfoDouble(sym, SYMBOL_BID);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   unit = bid > 100 ? 1.0 : 0.001;               // gold: $1 move; FX: 10 pips
   if(bid <= 0) return 0;
   lossPerUnit = LossBetween(sym, true, vmin, bid, bid - unit);
   if(lossPerUnit <= 0) return 0;
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * g_cfg.riskPct / 100.0;
   return riskMoney / lossPerUnit * unit;
  }

void RunSizingCheck()
  {
   int idx = SymbolIndex(_Symbol);
   if(idx < 0 && ArraySize(g_syms) > 0) idx = 0;
   if(idx < 0) return;
   string sym = g_syms[idx];
   double atr = Buf(g_hATR[idx]);
   if(atr <= 0) return;                          // indicator not ready yet; retry next tick
   g_sizingAt = TimeCurrent();

   double lossPerUnit = 0, unit = 1;
   double maxSl = MaxStopForMinLot(sym, lossPerUnit, unit);
   if(maxSl <= 0)
     {
      g_sizingText = StringFormat("could not calculate yet (error %d) - retrying", GetLastError());
      g_sizingState = -1;
      g_sizingAt = TimeCurrent() - 3600 + 60;    // retry in about a minute
      return;
     }

   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * g_cfg.riskPct / 100.0;
   double maxAtr = maxSl / atr;
   double typical = (g_cfg.slMin + g_cfg.slMax) / 2 * atr;
   double needEquity = lossPerUnit * (typical / unit) / (g_cfg.riskPct / 100.0);
   string unitTxt = unit == 1.0 ? "$1" : "10 pips";

   if(maxAtr >= g_cfg.slMax)
     {
      g_sizingState = 2;
      g_sizingText = StringFormat("OK: %.2f lot risks %.2f %s per %s; all stops up to %.1f ATR fit",
                                  vmin, lossPerUnit, cur, unitTxt, g_cfg.slMax);
     }
   else if(maxAtr >= g_cfg.slMin)
     {
      g_sizingState = 1;
      g_sizingText = StringFormat("PARTIAL: min lot fits stops <= %s (%.2f ATR) only; wider stops are skipped",
                                  Px(sym, maxSl), maxAtr);
     }
   else
     {
      g_sizingState = 0;
      g_sizingText = StringFormat("CANNOT TRADE: min lot over-risks even at %.1f ATR; need ~%.0f %s equity or more risk %%",
                                  g_cfg.slMin, needEquity, cur);
     }
   PrintFormat("AITrader: SIZING %s | min lot %.2f loses %.2f %s per %s move (%.2f per 1 ATR = %s) | risk %.2f%% = %.2f %s "
               "-> widest stop for min lot %s (%.2f ATR) | allowed stops %.1f-%.1f ATR | equity for a typical %.1f ATR stop: %.0f %s",
               sym, vmin, lossPerUnit, cur, unitTxt, lossPerUnit * atr / unit, Px(sym, atr), g_cfg.riskPct, riskMoney, cur,
               Px(sym, maxSl), maxAtr, g_cfg.slMin, g_cfg.slMax, typical / atr, needEquity, cur);
   PrintFormat("AITrader: SIZING verdict - %s", g_sizingText);
  }

// Tells the entry model the widest stop the minimum lot allows, so it plans stops that can actually be traded.
string SizingHint(int idx)
  {
   string sym = g_syms[idx];
   double lossPerUnit = 0, unit = 1;
   double maxSl = MaxStopForMinLot(sym, lossPerUnit, unit);
   if(maxSl <= 0) return "";
   return StringFormat("POSITION SIZING: with the minimum lot (%.2f) the stop-loss can be at most %s away from entry "
                       "at the current risk cap; wider stops cannot be traded and will be rejected.\n",
                       SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), Px(sym, maxSl));
  }

//+------------------------------------------------------------------+
//| TRAILING STOP (mechanical, ATR-based, only ever tightens)         |
//+------------------------------------------------------------------+
ulong  g_trailIds[];
double g_trailRisk[];

// Initial risk distance of a position = |open - SL at entry|, read once from the opening order.
double InitialRisk(ulong posId, double open, double currentSl)
  {
   for(int i = 0; i < ArraySize(g_trailIds); i++) if(g_trailIds[i] == posId) return g_trailRisk[i];
   double risk = 0;
   if(HistorySelectByPosition(posId))
     {
      datetime first = 0;
      for(int i = 0; i < HistoryOrdersTotal(); i++)
        {
         ulong o = HistoryOrderGetTicket(i);
         datetime t = (datetime)HistoryOrderGetInteger(o, ORDER_TIME_SETUP);
         double osl = HistoryOrderGetDouble(o, ORDER_SL);
         if(osl > 0 && (first == 0 || t < first)) { first = t; risk = MathAbs(open - osl); }
        }
     }
   if(risk <= 0 && currentSl > 0) risk = MathAbs(open - currentSl); // fallback
   if(risk <= 0) return 0;
   int n = ArraySize(g_trailIds);
   ArrayResize(g_trailIds, n + 1); ArrayResize(g_trailRisk, n + 1);
   g_trailIds[n] = posId; g_trailRisk[n] = risk;
   return risk;
  }

void TrailingStops()
  {
   if(InpDryRun) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!IsOurs(t)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int idx = SymbolIndex(sym);
      if(idx < 0) continue;
      double atr = Buf(g_hATR[idx]);
      if(atr <= 0) continue;
      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN), sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP), cur = PositionGetDouble(POSITION_PRICE_CURRENT);
      double risk = InitialRisk((ulong)PositionGetInteger(POSITION_IDENTIFIER), open, sl);
      if(!PositionSelectByTicket(t)) continue;      // InitialRisk may change the selection context
      if(risk <= 0) continue;
      double profit = isBuy ? cur - open : open - cur;
      if(profit < InpTrailStartR * risk) continue;

      double newSl = NormPrice(sym, isBuy ? cur - InpTrailAtr * atr : cur + InpTrailAtr * atr);
      double step  = InpTrailStepAtr * atr;
      double stop  = StopLevel(sym);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID), ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      bool better = isBuy ? (sl == 0 || newSl >= sl + step) : (sl == 0 || newSl <= sl - step);
      bool valid  = isBuy ? (newSl < bid - stop) : (newSl > ask + stop);
      if(!better || !valid) continue;
      if(g_trade.PositionModify(t, newSl, tp))
        {
         Notify(StringFormat("trailing stop %s -> %s (profit %.2fR)", sym, Px(sym, newSl), profit / risk));
         LogRow("MANAGE", sym, "TRAIL", 0, 0, newSl, tp, PositionGetDouble(POSITION_VOLUME), "DONE",
                StringFormat("mechanical trail %.1f ATR, profit %.2fR", InpTrailAtr, profit / risk));
        }
     }
  }

//+------------------------------------------------------------------+
//| MULTIPLE TRADES PER SYMBOL                                        |
//+------------------------------------------------------------------+
// Open positions + pending orders of this EA on 'sym'.
int SymbolExposure(string sym)
  {
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(IsOurs(t) && PositionGetString(POSITION_SYMBOL) == sym) c++;
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(IsOurPending(OrderGetTicket(i)) && OrderGetString(ORDER_SYMBOL) == sym) c++;
   return c;
  }

// "" if a new trade in this direction is allowed next to the existing ones, otherwise the reason.
string StackingRule(string sym, bool isBuy)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(!IsOurs(t) || PositionGetString(POSITION_SYMBOL) != sym) continue;
      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double pnl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(posBuy != isBuy && !InpAllowOpposite)
         return StringFormat("opposite %s position #%I64u is open (hedging disabled)", posBuy ? "BUY" : "SELL", t);
      if(posBuy == isBuy && InpNoAveragingDown && pnl <= 0)
         return StringFormat("would add to losing %s #%I64u (%.2f) - no averaging down", posBuy ? "BUY" : "SELL", t, pnl);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(!IsOurPending(t) || OrderGetString(ORDER_SYMBOL) != sym) continue;
      long type = OrderGetInteger(ORDER_TYPE);
      bool ordBuy = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_BUY_STOP);
      if(ordBuy != isBuy && !InpAllowOpposite)
         return StringFormat("opposite pending order #%I64u is waiting (hedging disabled)", t);
     }
   return "";
  }

//+------------------------------------------------------------------+
//| MARKET STRUCTURE (decision timeframe, 2-bar fractal swings)       |
//+------------------------------------------------------------------+
// Returns UP / DOWN (structure + EMA20 agree), WEAK_UP / WEAK_DOWN, RANGE or UNKNOWN.
string StructureState(int idx, double &lastHigh, double &lastLow, string &detail)
  {
   string sym = g_syms[idx];
   lastHigh = 0; lastLow = 0; detail = "";
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(sym, g_cfg.scanTF, 1, 80, r);   // closed bars, newest first
   if(n < 20) return "UNKNOWN";
   double hs[2] = {0, 0}, ls[2] = {0, 0};
   int nh = 0, nl = 0;
   for(int i = 2; i < n - 2 && (nh < 2 || nl < 2); i++)
     {
      if(nh < 2 && r[i].high > r[i - 1].high && r[i].high > r[i - 2].high && r[i].high >= r[i + 1].high && r[i].high >= r[i + 2].high)
        { hs[nh] = r[i].high; nh++; }
      if(nl < 2 && r[i].low < r[i - 1].low && r[i].low < r[i - 2].low && r[i].low <= r[i + 1].low && r[i].low <= r[i + 2].low)
        { ls[nl] = r[i].low; nl++; }
     }
   if(nh < 2 || nl < 2) return "UNKNOWN";
   lastHigh = hs[0]; lastLow = ls[0];
   double e1 = Buf(g_hE20[idx], 1), e4 = Buf(g_hE20[idx], 4), c = r[0].close;
   string st = "RANGE";
   if(hs[0] > hs[1] && ls[0] > ls[1]) st = "UP";
   else if(hs[0] < hs[1] && ls[0] < ls[1]) st = "DOWN";
   detail = StringFormat("swing highs %s -> %s, swing lows %s -> %s, price %s EMA20 %s (%s)",
                         Px(sym, hs[1]), Px(sym, hs[0]), Px(sym, ls[1]), Px(sym, ls[0]),
                         c > e1 ? "above" : "below", Px(sym, e1), e1 > e4 ? "rising" : (e1 < e4 ? "falling" : "flat"));
   if(st == "UP"   && c > e1 && e1 > e4) return "UP";
   if(st == "DOWN" && c < e1 && e1 < e4) return "DOWN";
   return st == "RANGE" ? "RANGE" : "WEAK_" + st;
  }

string StructureContext(int idx)
  {
   double hi, lo; string det;
   string st = StructureState(idx, hi, lo, det);
   if(st == "UNKNOWN") return "";
   string rule = st == "UP"   ? " -> SELL entries are blocked by the EA (except a SELL STOP below the last swing low)"
               : st == "DOWN" ? " -> BUY entries are blocked by the EA (except a BUY STOP above the last swing high)" : "";
   return StringFormat("MARKET STRUCTURE (%s): %s | %s%s\n", TfName(g_cfg.scanTF), st, det, InpStructureFilter ? rule : "");
  }

// Hard rule: no trade against a confirmed decision-timeframe structure, except a STOP order that only fills if it breaks.
string StructureRule(int idx, bool isBuy, string ord, double entry)
  {
   if(!InpStructureFilter) return "";
   double hi, lo; string det;
   string st = StructureState(idx, hi, lo, det);
   if(!isBuy && st == "UP")
     {
      if(ord == "STOP" && lo > 0 && entry < lo) return "";
      return "counter-structure SELL (" + TfName(g_cfg.scanTF) + " uptrend: " + det + ")";
     }
   if(isBuy && st == "DOWN")
     {
      if(ord == "STOP" && hi > 0 && entry > hi) return "";
      return "counter-structure BUY (" + TfName(g_cfg.scanTF) + " downtrend: " + det + ")";
     }
   return "";
  }
