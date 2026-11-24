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

enum ENUM_AI_ROUTE
  {
   ROUTE_PRIMARY    = 0, // Primary (asAi) first
   ROUTE_DEEPSEEK   = 1, // DeepSeek first
   ROUTE_OPENROUTER = 2  // OpenRouter first
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

// Providers are tried in order: Primary (asAi) -> Backup 1 (DeepSeek) -> Backup 2 (OpenRouter).
// A provider that fails is skipped for InpFailoverCooldownMin minutes.
input group "AI provider 1 - PRIMARY (asAi, OpenAI-compatible)"
input bool             InpP1Enabled       = true;                    // Enabled
input string           InpP1Name          = "asAi";                  // Name (for logs)
input string           InpP1Url           = "https://serveras.click/v1/chat/completions"; // Chat completions URL
input string           InpP1Key           = "";                      // API key (empty = read key file)
input string           InpP1KeyFile       = "aitrader_key_asai.txt"; // Key file in <Common>\Files
input string           InpP1Model         = "asai/gpt-6.2-astra";    // Model id (copy from asAi > Models)
input string           InpModelScan       = "";                      // Primary model for SCAN (empty = Model id)
input string           InpModelEntry      = "";                      // Primary model for ENTRY (empty = Model id)
input string           InpModelManage     = "";                      // Primary model for MANAGE (empty = Model id)

input group "AI provider 2 - BACKUP (DeepSeek)"
input bool             InpP2Enabled       = true;                    // Enabled
input string           InpP2Key           = "";                      // API key (empty = read key file)
input string           InpP2KeyFile       = "aitrader_key_deepseek.txt"; // Key file in <Common>\Files
input string           InpP2Model         = "deepseek-chat";         // Model

input group "AI provider 3 - BACKUP (OpenRouter)"
input bool             InpP3Enabled       = true;                    // Enabled
input string           InpP3Key           = "";                      // API key (empty = read key file)
input string           InpP3KeyFile       = "aitrader_key_openrouter.txt"; // Key file in <Common>\Files
input string           InpP3Model         = "google/gemini-4-carbon"; // Model slug

input group "Multi-model routing"
input ENUM_AI_ROUTE    InpRouteScan       = ROUTE_DEEPSEEK;          // SCAN runs on (others = failover)
input ENUM_AI_ROUTE    InpRouteEntry      = ROUTE_PRIMARY;           // ENTRY runs on (others = failover)
input ENUM_AI_ROUTE    InpRouteManage     = ROUTE_DEEPSEEK;          // MANAGE runs on (others = failover)
input ENUM_AI_ROUTE    InpRouteReview     = ROUTE_OPENROUTER;        // ENTRY 2nd opinion runs on (must differ from 1st)
input bool             InpEntryConsensus  = true;                    // [Balanced/Aggressive] ENTRY needs a 2nd model to agree
input bool             InpConsensusStrict = false;                   // If no 2nd provider is available: true = skip trade

input group "AI request settings"
input int              InpFailoverCooldownMin = 10;                  // Skip a failed provider for N minutes
input double           InpTemperature     = 0.2;                     // Temperature
input int              InpMaxTokens       = 600;                     // Max response tokens
input bool             InpJsonMode        = true;                    // Request JSON response_format
input int              InpTimeoutMs       = 45000;                   // HTTP timeout per provider (ms)
input int              InpMaxAICallsDay   = 0;                       // Max AI calls per day (0 = mode default)

input group "Scanner"
input string           InpSymbols         = "XAUUSD,EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,XAGUSD"; // Watchlist (broker names, comma separated)
input ENUM_TIMEFRAMES  InpTimeframe       = PERIOD_H1;               // [Custom] Scan/entry timeframe
input int              InpMaxCandidates   = 2;                       // [Balanced] Max candidates per scan
input double           InpMinScanScore    = 0.6;                     // [Balanced] Min scan score
input int              InpBarsForAI       = 40;                      // [Custom] Bars sent per symbol
input int              InpStartHour       = 1;                       // [No session bias] Entries from (server hour)
input int              InpEndHour         = 21;                      // [No session bias] Entries until (server hour)

input group "Position management"
input ENUM_TIMEFRAMES  InpManageTF        = PERIOD_M15;              // [Custom] Manage timeframe
input double           InpMinManageConf   = 0.6;                     // [Balanced] Min AI confidence for management
input double           InpBreakevenR      = 0.0;                     // Mechanical breakeven at R (0 = leave to AI)
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
input int              InpMaxTradesDay    = 6;                       // [Custom] Max new trades per day
input double           InpMaxDailyLossPct = 3.0;                     // Daily equity drawdown limit (%)
input bool             InpCloseOnDailyLoss= true;                    // Close all positions when daily limit hit
input double           InpMaxSpreadAtr    = 0.15;                    // [Custom] Max spread as fraction of ATR

input group "Misc"
input ulong            InpMagic           = 26112402;                // Magic number
input int              InpSlippagePts     = 30;                      // Max slippage (points)
input int              InpTimerSec        = 0;                       // Timer interval seconds (0 = mode default)
input string           InpLogFile         = "AITraderEA_log.csv";    // Log file in MQL5\Files

input group "Dashboard panel"
input bool             InpShowPanel       = true;                    // Show dashboard panel
input int              InpPanelX          = 8;                       // Panel X offset (px from left)
input int              InpPanelY          = 100;                     // Panel Y offset (px from top; clears one-click trading)
input int              InpPanelFontSize   = 9;                       // Panel font size
input int              InpPanelWrapChars  = 95;                      // Wrap long lines after N characters

//=== Types ===========================================================
struct EntryDecision
  {
   string            action;     // BUY / SELL / HOLD
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
   int               maxCandidates;
   int               timerSec;
   int               maxCalls;
   double            slMin;
   double            slMax;
   double            minRR;
   double            maxSpreadAtr;
   double            riskPct;
   double            minConf;
   double            minManageConf;
   double            minScanScore;
   bool              consensus;
   bool              consensusStrict;
   bool              fridayClose;
   string            styleText;
   string            profileText;
   string            sessionText;
  };

//=== Globals =========================================================
RuntimeConfig g_cfg;

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
   AddProvider(InpP1Enabled, InpP1Name, InpP1Url, InpP1Key, InpP1KeyFile, InpP1Model, false);
   AddProvider(InpP2Enabled, "DeepSeek", "https://api.deepseek.com/chat/completions", InpP2Key, InpP2KeyFile, InpP2Model, false);
   AddProvider(InpP3Enabled, "OpenRouter", "https://openrouter.ai/api/v1/chat/completions", InpP3Key, InpP3KeyFile, InpP3Model, true);
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
   Comment("");
  }

void OnTick() { if(InpBreakevenR > 0) MechanicalBreakeven(); }

//+------------------------------------------------------------------+
//| Main loop                                                         |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(MQLInfoInteger(MQL_TESTER)) return;
   RollDay();

   // 1. Hard rules first (no AI needed)
   EnforceHardRules();

   // 2. AI position management on each new manage bar
   datetime mBar = iTime(_Symbol, g_cfg.manageTF, 0);
   if(mBar != 0 && mBar != g_lastManageBar)
     {
      g_lastManageBar = mBar;
      ManagePositions();
     }

   // 3. AI scan + entries on each new scan bar
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
   if(InpTimerSec > 0)      g_cfg.timerSec = (int)MathMax(2, InpTimerSec);
   if(InpMaxAICallsDay > 0) g_cfg.maxCalls = InpMaxAICallsDay;

   //--- risk profile (Balanced = inputs as set) -----------------------
   double riskMult = 1.0, tradesMult = 1.0;
   g_cfg.minConf         = InpMinConfidence;
   g_cfg.minManageConf   = InpMinManageConf;
   g_cfg.maxPositions    = InpMaxPositions;
   g_cfg.maxCandidates   = InpMaxCandidates;
   g_cfg.minScanScore    = InpMinScanScore;
   g_cfg.consensus       = InpEntryConsensus;
   g_cfg.consensusStrict = InpConsensusStrict;
   switch(InpRiskProfile)
     {
      case PROFILE_CONSERVATIVE:
         riskMult = 0.75; tradesMult = 0.6;
         g_cfg.minConf = MathMax(g_cfg.minConf, 0.72);       g_cfg.minRR += 0.3;
         g_cfg.minManageConf = MathMax(g_cfg.minManageConf, 0.70);
         g_cfg.maxPositions = (int)MathMin(g_cfg.maxPositions, 2);
         g_cfg.minScanScore = MathMax(g_cfg.minScanScore, 0.70);
         g_cfg.consensus = true;
         g_cfg.profileText = "CONSERVATIVE: capital preservation first. Only trend-aligned, high-probability setups; "
                             "lower risk when uncertain; take partial profits and move SL to breakeven early.";
         break;
      case PROFILE_AGGRESSIVE:
         riskMult = 1.5; tradesMult = 1.5;
         g_cfg.minConf = MathMin(g_cfg.minConf, 0.60);       g_cfg.minRR = MathMax(1.0, g_cfg.minRR - 0.3);
         g_cfg.maxPositions += 2;                            g_cfg.maxCandidates += 1;
         g_cfg.minScanScore = MathMin(g_cfg.minScanScore, 0.55);
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

   if(IsFridayClose() && CountPositions() > 0)
      CloseAll("Friday close");

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
//| STAGE 1+2: SCAN and ENTRY                                         |
//+------------------------------------------------------------------+
void ScanAndEnter()
  {
   string why = "";
   if(!EntryAllowed(why))
     { g_lastScan = "skipped: " + why; Print("AITrader: scan ", g_lastScan); return; }

   // Build the scanner table from local indicators
   string table = "symbol,price,change_pct_24bars,atr_pct,rsi14,ema_trend,range_pos_50bars_pct,spread_atr,has_open_position\n";
   int rows = 0;
   g_scanSkipped = "";
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      string row = ScanRow(i);
      if(row != "") { table += row + "\n"; rows++; }
     }
   if(g_scanSkipped != "")
      PrintFormat("AITrader: spread > %.2f ATR, not scanned: %s", g_cfg.maxSpreadAtr, g_scanSkipped);
   if(rows == 0) { g_lastScan = "no tradeable symbols (spreads too wide or no data)"; return; }

   string system = StringFormat(
      "You are a professional multi-asset market scanner. From the table, pick at most %d symbols that offer the "
      "clearest, highest-quality trade setup on the %s timeframe RIGHT NOW (trend continuation after pullback, "
      "clean breakout, or exhaustion reversal). Avoid symbols with high spread_atr, choppy mixed trends, or an "
      "existing open position. Avoid picking several highly correlated symbols in the same direction. "
      "Reply ONLY with JSON: {\"candidates\":[{\"symbol\":\"...\",\"bias\":\"BUY\"|\"SELL\",\"score\":0.0-1.0,"
      "\"note\":\"max 15 words\"}],\"market_view\":\"max 25 words\"}. An empty candidates list is a valid answer.",
      g_cfg.maxCandidates, TfName(g_cfg.scanTF));
   string user = StringFormat("Server time %s. Open positions:\n%s\nScanner table:\n%s",
                              TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), PositionsSummary(), table);

   string content;
   string used;
   if(!CallAI(InpRouteScan, InpModelScan, system, user, content, used, "")) { g_lastScan = "AI call failed"; return; }

   string obj = ExtractJsonObject(content);
   string cands[];
   JsonArrayObjects(obj, "candidates", cands);
   string view = JsonGetString(obj, "market_view");
   g_lastScan = StringFormat("%s | %d picks: ", view, ArraySize(cands));
   LogRow("SCAN", "", "", 0, 0, 0, 0, 0, StringFormat("%d candidates", ArraySize(cands)), view);

   int analysed = 0;
   for(int c = 0; c < ArraySize(cands) && analysed < g_cfg.maxCandidates; c++)
     {
      string sym   = JsonGetString(cands[c], "symbol");
      string bias  = JsonGetString(cands[c], "bias");
      double score = JsonGetNumber(cands[c], "score");
      string note  = JsonGetString(cands[c], "note");
      StringToUpper(bias);
      g_lastScan += StringFormat("%s %s %.2f; ", sym, bias, score);

      int idx = SymbolIndex(sym);
      if(idx < 0)                  { Print("AITrader: scan picked unknown symbol ", sym); continue; }
      if(score < g_cfg.minScanScore)  continue;
      if(HasPosition(sym))         continue;
      if(!EntryAllowed(why))       { Print("AITrader: stop entries - ", why); break; }
      analysed++;
      EvaluateEntry(idx, bias, score, note);
     }
  }

bool EntryAllowed(string &why)
  {
   if(g_haltedToday)                                  { why = "daily loss limit"; return false; }
   if(IsFridayClose())                                { why = "Friday close window"; return false; }
   if(!InSession())                                   { why = "outside " + SessionName() + " session"; return false; }
   if(CountPositions() >= g_cfg.maxPositions)            { why = "max positions"; return false; }
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
   string system = StringFormat(
      "You are a disciplined trader and risk manager. The scanner flagged %s with a %s bias (score %.2f: %s). "
      "Confirm or reject using the data. Decide whether to open ONE position now and how much to risk. "
      "Reply ONLY with JSON: {\"action\":\"BUY\"|\"SELL\"|\"HOLD\",\"confidence\":0.0-1.0,"
      "\"risk_percent\":0.0-%.2f,\"sl\":price,\"tp\":price,\"reason\":\"max 30 words\"}. "
      "risk_percent is %% of equity lost if SL is hit: lower it for high volatility, weak confluence, nearby "
      "major levels, or exposure correlated with open positions. BUY fills at ask, SELL at bid. SL beyond a "
      "logical swing level, %.1f-%.1f ATR from entry. TP at least %.1f x SL distance at a realistic target. "
      "Prices with %d decimals. HOLD with risk_percent 0 when the edge is unclear.",
      sym, bias, score, note, remaining, g_cfg.slMin, g_cfg.slMax, g_cfg.minRR, SymDigits(sym));
   string user = SymbolContext(idx) + "Open positions:\n" + PositionsSummary() +
                 StringFormat("Remaining risk budget: %.2f%% of equity\n", remaining);

   string content, used;
   if(!CallAI(InpRouteEntry, InpModelEntry, system, user, content, used, "")) return;

   EntryDecision d;
   if(!ParseEntry(content, d))
     { LogRow("ENTRY", sym, "PARSE_ERROR", 0, 0, 0, 0, 0, used, StringSubstr(content, 0, 200)); return; }
   d.reason = used + ": " + d.reason;

   // Second opinion from a DIFFERENT provider before any trade
   if(g_cfg.consensus && (d.action == "BUY" || d.action == "SELL") && d.confidence >= g_cfg.minConf)
     {
      string system2 = system + " You are the independent second reviewer: judge the data yourself; do not assume "
                       "the scanner is right. Reject marginal setups.";
      string content2, used2;
      if(!CallAI(InpRouteReview, "", system2, user, content2, used2, used))
        {
         if(g_cfg.consensusStrict)
           { LogRow("ENTRY", sym, d.action, d.confidence, d.risk_pct, d.sl, d.tp, 0, "REJECTED: no 2nd model available", d.reason); return; }
         Notify(sym + ": no 2nd model available, using single-model decision");
        }
      else
        {
         EntryDecision d2;
         if(!ParseEntry(content2, d2) || d2.action != d.action)
           {
            string why = StringFormat("no consensus: %s says %s, %s says %s", used, d.action, used2,
                                      d2.action == "" ? "unparseable" : d2.action);
            Notify(sym + " " + why);
            LogRow("ENTRY", sym, d.action, d.confidence, d.risk_pct, d.sl, d.tp, 0, "REJECTED: " + why,
                   d.reason + " | " + used2 + ": " + d2.reason);
            return;
           }
         // Agreement: be as cautious as the more cautious model
         d.confidence = MathMin(d.confidence, d2.confidence);
         d.risk_pct   = MathMin(d.risk_pct, d2.risk_pct);
         d.reason     = d.reason + " | " + used2 + " agrees: " + d2.reason;
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
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK), bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double entry = isBuy ? ask : bid;
   double sl = NormPrice(sym, d.sl), tp = NormPrice(sym, d.tp);
   double atr = Buf(g_hATR[idx]);
   double slDist = MathAbs(entry - sl), tpDist = MathAbs(tp - entry);
   double minStop = StopLevel(sym);
   double riskPct = MathMin(d.risk_pct, riskBudget);

   if(d.confidence < g_cfg.minConf)                  err = StringFormat("confidence %.2f < %.2f", d.confidence, g_cfg.minConf);
   else if(riskPct <= 0)                                err = "risk_percent <= 0 or no budget";
   else if(isBuy && !(sl < bid && tp > ask))            err = "BUY needs sl < bid < ask < tp";
   else if(!isBuy && !(sl > ask && tp < bid))           err = "SELL needs tp < bid < ask < sl";
   else if(atr <= 0)                                    err = "ATR unavailable";
   else if(slDist < g_cfg.slMin * atr || slDist > g_cfg.slMax * atr)
                                                        err = StringFormat("SL %.2f ATR outside [%.2f, %.2f]", slDist / atr, g_cfg.slMin, g_cfg.slMax);
   else if(slDist <= minStop || tpDist <= minStop)      err = "SL/TP inside broker stop level";
   else if(tpDist / slDist < g_cfg.minRR)                  err = StringFormat("R:R %.2f < %.2f", tpDist / slDist, g_cfg.minRR);

   double lots = 0;
   if(err == "")
     {
      lots = LotsForRisk(sym, isBuy, entry, sl, riskPct);
      if(lots <= 0) err = "risk too small for min lot, or insufficient margin";
     }
   if(err != "")
     {
      Notify(sym + " entry rejected: " + err);
      LogRow("ENTRY", sym, d.action, d.confidence, d.risk_pct, sl, tp, 0, "REJECTED: " + err, d.reason);
      return;
     }

   if(InpDryRun)
     {
      Notify(StringFormat("[DRY] %s %s %.2f lots risk %.2f%%", d.action, sym, lots, riskPct));
      LogRow("ENTRY", sym, d.action, d.confidence, riskPct, sl, tp, lots, "DRY_RUN", d.reason);
      return;
     }

   g_trade.SetTypeFillingBySymbol(sym);
   string cmt = StringFormat("AI c%.0f r%.2f", d.confidence * 100, riskPct);
   bool ok = isBuy ? g_trade.Buy(lots, sym, ask, sl, tp, cmt) : g_trade.Sell(lots, sym, bid, sl, tp, cmt);
   uint rc = g_trade.ResultRetcode();
   string status = (ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED)) ? "PLACED" :
                   "FAILED_" + IntegerToString(rc) + " " + g_trade.ResultRetcodeDescription();
   Notify(StringFormat("%s %s %.2f lots: %s", d.action, sym, lots, status));
   LogRow("ENTRY", sym, d.action, d.confidence, riskPct, sl, tp, lots, status, d.reason);
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
      "setup is invalidated, and avoid over-managing: HOLD is the normal answer while the thesis is intact. "
      "Reply ONLY with JSON: {\"action\":\"HOLD\"|\"CLOSE\"|\"PARTIAL\"|\"MODIFY\",\"confidence\":0.0-1.0,"
      "\"new_sl\":price,\"new_tp\":price,\"close_fraction\":0.0,\"reason\":\"max 25 words\"}. Prices with %d decimals.",
      isBuy ? "BUY" : "SELL", sym, dg);
   string user = StringFormat(
      "Position #%I64u %s %s %.2f lots, opened %s (%.1f h ago) at %s. Current %s. SL %s TP %s. "
      "Floating P/L %.2f %s (%.2fR). Entry note: %s\n",
      ticket, isBuy ? "BUY" : "SELL", sym, vol, TimeToString(opened, TIME_DATE | TIME_MINUTES),
      (TimeCurrent() - opened) / 3600.0, DoubleToString(open, dg), DoubleToString(cur, dg),
      DoubleToString(sl, dg), DoubleToString(tp, dg), pnl, AccountInfoString(ACCOUNT_CURRENCY), rMult, cmt);
   user += SymbolContext(idx);

   string content;
   string used;
   if(!CallAI(InpRouteManage, InpModelManage, system, user, content, used, "")) return;

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
double LotsForRisk(string sym, bool isBuy, double entry, double sl, double riskPct)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double pnl = 0;
   if(!OrderCalcProfit(type, sym, 1.0, entry, sl, pnl) || pnl >= 0) return 0;
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
      double pnl = 0;
      if(OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, PositionGetString(POSITION_SYMBOL),
                         PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_CURRENT), sl, pnl) && pnl < 0)
         pct += -pnl / eq * 100.0;
     }
   return pct;
  }

//+------------------------------------------------------------------+
//| AI HTTP client (OpenAI-compatible chat completions)               |
//+------------------------------------------------------------------+
void AddProvider(bool enabled, string name, string url, string key, string keyFile, string model, bool openrouter)
  {
   if(!enabled) return;
   if(key == "") key = ReadKeyFile(keyFile);
   if(key == "") { PrintFormat("AITrader: %s skipped - no key (input empty and <Common>\\Files\\%s missing)", name, keyFile); return; }
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

string HostOf(string url)
  {
   int p = StringFind(url, "://");
   int q = StringFind(url, "/", p < 0 ? 0 : p + 3);
   return q > 0 ? StringSubstr(url, 0, q) : url;
  }

string RouteName(ENUM_AI_ROUTE r)
  {
   if(r == ROUTE_DEEPSEEK)   return "DeepSeek";
   if(r == ROUTE_OPENROUTER) return "OpenRouter";
   return InpP1Name;
  }

// Try the routed provider first, then the others in chain order, skipping 'exclude'.
// The per-stage model override applies only when the primary (asAi) answers.
// 'used' receives the name of the provider that answered.
bool CallAI(ENUM_AI_ROUTE route, string stageModel, string system, string user, string &content,
            string &used, string exclude)
  {
   content = ""; used = "";
   system = ProfileBrief() + " " + system;
   int n = ArraySize(g_prov);
   int order[];
   ArrayResize(order, 0);
   string first = RouteName(route);
   for(int i = 0; i < n; i++) if(g_prov[i].name == first) { ArrayResize(order, 1); order[0] = i; }
   for(int i = 0; i < n; i++)
      if(g_prov[i].name != first) { int k = ArraySize(order); ArrayResize(order, k + 1); order[k] = i; }

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
   d.action = ""; d.confidence = 0; d.risk_pct = 0; d.sl = 0; d.tp = 0; d.reason = "";
   string o = ExtractJsonObject(content);
   if(o == "") return false;
   d.action = UpperTrim(JsonGetString(o, "action"));
   if(d.action != "BUY" && d.action != "SELL" && d.action != "HOLD") return false;
   d.confidence = NormConf(JsonGetNumber(o, "confidence"));
   d.risk_pct   = JsonGetNumber(o, "risk_percent");
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

int CountTodayEntries()
  {
   if(!HistorySelect(DayStart(), TimeCurrent() + 60)) return 0;
   int c = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t != 0 && (ulong)HistoryDealGetInteger(t, DEAL_MAGIC) == InpMagic &&
         HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN)
         c++;
     }
   return c;
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
   g_pTxt[n] = text; g_pClr[n] = c;
  }

// Adds 'text' under a short heading, wrapping long text onto indented lines.
void PanelAddWrapped(string head, string text, color c)
  {
   string pad = "            ";
   string prefix = StringSubstr(head + pad, 0, 11) + " ";
   int width = MathMax(30, InpPanelWrapChars - 12);
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
   string status = g_haltedToday ? "HALTED - daily loss limit" : (InpDryRun ? "DRY RUN - no orders sent" : "LIVE TRADING");
   color  stClr  = g_haltedToday ? CLR_BAD : (InpDryRun ? CLR_WARN : CLR_BAD);

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
   PanelAddWrapped("EXPOSURE", StringFormat("open risk %.2f%% / %.2f%% | positions %d/%d | trades today %d/%d",
                   openRisk, InpMaxTotalRiskPct, CountPositions(), g_cfg.maxPositions,
                   CountTodayEntries(), g_cfg.maxTradesDay),
                   openRisk >= InpMaxTotalRiskPct - 0.01 ? CLR_WARN : CLR_TEXT);
   PanelAdd("", CLR_TEXT);
   PanelAddWrapped("LAST SCAN", g_lastScan, CLR_TEXT);
   PanelAddWrapped("LAST EVENT", g_lastEvent, CLR_HEAD);
   DrawPanel();
  }

void DrawPanel()
  {
   int n = ArraySize(g_pTxt);
   int pad = 10;
   TextSetFont("Consolas", -InpPanelFontSize * 10);
   uint w = 0, h = 0;
   int maxW = 0, lineH = 0;
   for(int i = 0; i < n; i++)
     {
      TextGetSize(g_pTxt[i] == "" ? " " : g_pTxt[i], w, h);
      if((int)w > maxW)  maxW = (int)w;
      if((int)h > lineH) lineH = (int)h;
     }
   lineH += 3;

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
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpPanelX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpPanelY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, maxW + 2 * pad);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, n * lineH + 2 * pad - 3);
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
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + pad);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY + pad + i * lineH);
      ObjectSetInteger(0, name, OBJPROP_COLOR, g_pClr[i]);
      ObjectSetString(0, name, OBJPROP_TEXT, g_pTxt[i] == "" ? " " : g_pTxt[i]);
     }
   // remove labels left over from a longer previous frame
   for(int i = n; ObjectFind(0, PANEL_PREFIX + "L" + IntegerToString(i)) >= 0; i++)
      ObjectDelete(0, PANEL_PREFIX + "L" + IntegerToString(i));
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
