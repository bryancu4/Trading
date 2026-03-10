//+------------------------------------------------------------------+
//|                                                ClaudeScalper.mq4 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property strict

//--- Input Parameters
input string          Symbol_To_Trade  = "XAUUSD";  // Symbol
input ENUM_TIMEFRAMES Timeframe        = PERIOD_M5;  // Timeframe
input double          RiskPercent      = 1.0;        // Risk % per trade
input int             EMA_Fast         = 50;         // Fast EMA period
input int             EMA_Slow         = 200;        // Slow EMA period
input int             RSI_Period       = 14;         // RSI period
input int             ATR_Period       = 14;         // ATR period
input int             Magic            = 20240101;   // Magic Number
input int             Slippage         = 30;         // Slippage in points
input int             LearnSampleSize  = 20;         // Trades to learn from
input bool            ResetLearning    = false;      // Reset learned parameters

//--- Adaptive parameters (adjusted by the learning system)
double g_RSI_BuyMin;
double g_RSI_BuyMax;
double g_RSI_SellMin;
double g_RSI_SellMax;
double g_ATR_SL_Mult;
double g_ATR_TP_Mult;
double g_ATR_Trail_Mult;

//--- Default starting values
#define DEF_RSI_BUY_MIN    45.0
#define DEF_RSI_BUY_MAX    65.0
#define DEF_RSI_SELL_MIN   35.0
#define DEF_RSI_SELL_MAX   55.0
#define DEF_ATR_SL         2.0
#define DEF_ATR_TP         3.0
#define DEF_ATR_TRAIL      1.5

//--- Trade history arrays (in-memory, last LearnSampleSize trades)
double g_TradeProfit[];   // profit/loss of each recorded trade
double g_TradeRSI[];      // RSI at entry
double g_TradeATR[];      // ATR at entry
int    g_TradeCount = 0;  // total trades recorded this session

//--- Track last known history count to detect new closed trades
int    g_LastHistoryCount = 0;

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Symbol_To_Trade)
      Print("WARNING: EA is on ", Symbol(), " but Symbol_To_Trade is ", Symbol_To_Trade);

   ArrayResize(g_TradeProfit, LearnSampleSize);
   ArrayResize(g_TradeRSI,    LearnSampleSize);
   ArrayResize(g_TradeATR,    LearnSampleSize);
   ArrayInitialize(g_TradeProfit, 0);
   ArrayInitialize(g_TradeRSI,    0);
   ArrayInitialize(g_TradeATR,    0);

   if (ResetLearning)
      ClearLearnedParams();

   LoadLearnedParams();

   g_LastHistoryCount = OrdersHistoryTotal();

   Print("ClaudeScalper v2 initialized | RSI Buy[", g_RSI_BuyMin, "-", g_RSI_BuyMax,
         "] Sell[", g_RSI_SellMin, "-", g_RSI_SellMax,
         "] SL=", g_ATR_SL_Mult, "xATR TP=", g_ATR_TP_Mult, "xATR");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   SaveLearnedParams();
   Print("ClaudeScalper deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Symbol_To_Trade) return;

   ManageOpenTrade();
   CheckClosedTrades();   // scan for newly closed trades → learn

   if (!IsNewBar()) return;
   if (HasOpenTrade())  return;

   double emaFast = iMA(NULL, Timeframe, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(NULL, Timeframe, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi     = iRSI(NULL, Timeframe, RSI_Period, PRICE_CLOSE, 1);
   double atr     = iATR(NULL, Timeframe, ATR_Period, 1);
   double price   = iClose(NULL, Timeframe, 1);

   if (emaFast <= 0 || emaSlow <= 0 || atr <= 0) return;

   double sl_dist = g_ATR_SL_Mult * atr;
   double tp_dist = g_ATR_TP_Mult * atr;

   bool buySignal  = (price > emaFast) && (emaFast > emaSlow)
                     && (rsi >= g_RSI_BuyMin) && (rsi <= g_RSI_BuyMax);
   bool sellSignal = (price < emaFast) && (emaFast < emaSlow)
                     && (rsi >= g_RSI_SellMin) && (rsi <= g_RSI_SellMax);

   if (buySignal) {
      double entry = Ask;
      double sl    = entry - sl_dist;
      double tp    = entry + tp_dist;
      double lots  = CalculateLots(sl_dist);
      if (lots > 0) {
         int ticket = OrderSend(Symbol(), OP_BUY, lots, entry, Slippage, sl, tp,
                                "ClaudeScalper BUY", Magic, 0, clrGreen);
         if (ticket > 0)
            Print("BUY opened #", ticket, " lots=", lots, " RSI=", DoubleToStr(rsi,2),
                  " SL=", sl, " TP=", tp);
         else
            Print("BUY failed. Error: ", GetLastError());
      }
   } else if (sellSignal) {
      double entry = Bid;
      double sl    = entry + sl_dist;
      double tp    = entry - tp_dist;
      double lots  = CalculateLots(sl_dist);
      if (lots > 0) {
         int ticket = OrderSend(Symbol(), OP_SELL, lots, entry, Slippage, sl, tp,
                                "ClaudeScalper SELL", Magic, 0, clrRed);
         if (ticket > 0)
            Print("SELL opened #", ticket, " lots=", lots, " RSI=", DoubleToStr(rsi,2),
                  " SL=", sl, " TP=", tp);
         else
            Print("SELL failed. Error: ", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Scan order history for newly closed EA trades and learn          |
//+------------------------------------------------------------------+
void CheckClosedTrades() {
   int histTotal = OrdersHistoryTotal();
   if (histTotal <= g_LastHistoryCount) return;

   for (int i = g_LastHistoryCount; i < histTotal; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderSymbol() != Symbol() || OrderMagicNumber() != Magic) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      double rsiAtEntry = iRSI(NULL, Timeframe, RSI_Period, PRICE_CLOSE, 1);
      double atrAtEntry = iATR(NULL, Timeframe, ATR_Period, 1);

      RecordTrade(profit, rsiAtEntry, atrAtEntry);
      AdaptParameters();

      Print("Learning: trade profit=", DoubleToStr(profit, 2),
            " | new RSI Buy[", g_RSI_BuyMin, "-", g_RSI_BuyMax, "]",
            " Sell[", g_RSI_SellMin, "-", g_RSI_SellMax, "]",
            " SL=", g_ATR_SL_Mult, " TP=", g_ATR_TP_Mult);
   }

   g_LastHistoryCount = histTotal;
   SaveLearnedParams();
}

//+------------------------------------------------------------------+
//| Store trade result in circular buffer                            |
//+------------------------------------------------------------------+
void RecordTrade(double profit, double rsi, double atr) {
   int idx = g_TradeCount % LearnSampleSize;
   g_TradeProfit[idx] = profit;
   g_TradeRSI[idx]    = rsi;
   g_TradeATR[idx]    = atr;
   g_TradeCount++;
}

//+------------------------------------------------------------------+
//| Adjust adaptive parameters based on recent trade performance     |
//+------------------------------------------------------------------+
void AdaptParameters() {
   int   filled  = MathMin(g_TradeCount, LearnSampleSize);
   if (filled < 5) return;   // need at least 5 trades to start learning

   int    wins       = 0;
   double totalProfit = 0;
   double totalLoss   = 0;

   for (int i = 0; i < filled; i++) {
      if (g_TradeProfit[i] > 0) {
         wins++;
         totalProfit += g_TradeProfit[i];
      } else {
         totalLoss += MathAbs(g_TradeProfit[i]);
      }
   }

   double winRate     = (double)wins / filled;
   double profitFactor = (totalLoss > 0) ? totalProfit / totalLoss : 2.0;

   // --- Adapt RSI zones ---
   // Low win rate → tighten RSI bands (require stronger confirmation)
   // High win rate → relax slightly to catch more trades
   double rsiStep = 1.0;
   if (winRate < 0.40) {
      g_RSI_BuyMin  = MathMin(g_RSI_BuyMin  + rsiStep, 55.0);
      g_RSI_BuyMax  = MathMax(g_RSI_BuyMax  - rsiStep, 58.0);
      g_RSI_SellMax = MathMax(g_RSI_SellMax - rsiStep, 42.0);
      g_RSI_SellMin = MathMin(g_RSI_SellMin + rsiStep, 40.0);
   } else if (winRate > 0.65) {
      g_RSI_BuyMin  = MathMax(g_RSI_BuyMin  - rsiStep, 40.0);
      g_RSI_BuyMax  = MathMin(g_RSI_BuyMax  + rsiStep, 70.0);
      g_RSI_SellMax = MathMin(g_RSI_SellMax + rsiStep, 60.0);
      g_RSI_SellMin = MathMax(g_RSI_SellMin - rsiStep, 30.0);
   }

   // Enforce minimum band width of 8 points
   if (g_RSI_BuyMax - g_RSI_BuyMin < 8)   g_RSI_BuyMax  = g_RSI_BuyMin  + 8;
   if (g_RSI_SellMax - g_RSI_SellMin < 8) g_RSI_SellMax = g_RSI_SellMin + 8;

   // --- Adapt ATR multipliers ---
   // Poor profit factor → wider SL (more room to breathe), larger TP target
   // Good profit factor → tighter SL is fine
   if (profitFactor < 1.0) {
      g_ATR_SL_Mult   = MathMin(g_ATR_SL_Mult   + 0.1, 3.5);
      g_ATR_TP_Mult   = MathMin(g_ATR_TP_Mult   + 0.1, 5.0);
      g_ATR_Trail_Mult = MathMin(g_ATR_Trail_Mult + 0.1, 3.0);
   } else if (profitFactor > 2.0) {
      g_ATR_SL_Mult   = MathMax(g_ATR_SL_Mult   - 0.1, 1.5);
      g_ATR_TP_Mult   = MathMax(g_ATR_TP_Mult   - 0.1, 2.0);
      g_ATR_Trail_Mult = MathMax(g_ATR_Trail_Mult - 0.1, 1.0);
   }
}

//+------------------------------------------------------------------+
//| Trailing stop management                                         |
//+------------------------------------------------------------------+
void ManageOpenTrade() {
   double atr = iATR(NULL, Timeframe, ATR_Period, 1);
   if (atr <= 0) return;
   double trailDist = g_ATR_Trail_Mult * atr;

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Symbol() || OrderMagicNumber() != Magic) continue;

      double newSL;
      if (OrderType() == OP_BUY) {
         newSL = Bid - trailDist;
         if (newSL > OrderStopLoss() + Point)
            OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newSL, Digits),
                        OrderTakeProfit(), 0, clrYellow);
      } else if (OrderType() == OP_SELL) {
         newSL = Ask + trailDist;
         if (newSL < OrderStopLoss() - Point || OrderStopLoss() == 0)
            OrderModify(OrderTicket(), OrderOpenPrice(), NormalizeDouble(newSL, Digits),
                        OrderTakeProfit(), 0, clrYellow);
      }
   }
}

//+------------------------------------------------------------------+
//| Lot sizing by risk %                                             |
//+------------------------------------------------------------------+
double CalculateLots(double slDistance) {
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double minLot    = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot    = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep   = MarketInfo(Symbol(), MODE_LOTSTEP);

   if (tickValue <= 0 || tickSize <= 0 || slDistance <= 0) return 0;

   double riskAmount = AccountBalance() * RiskPercent / 100.0;
   double slInTicks  = slDistance / tickSize;
   double lots       = riskAmount / (slInTicks * tickValue);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
bool HasOpenTrade() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == Symbol() && OrderMagicNumber() == Magic) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
bool IsNewBar() {
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(NULL, Timeframe, 0);
   if (currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Persist learned parameters using MT4 GlobalVariables            |
//+------------------------------------------------------------------+
void SaveLearnedParams() {
   string prefix = "CS_" + Symbol_To_Trade + "_";
   GlobalVariableSet(prefix + "RSI_BuyMin",   g_RSI_BuyMin);
   GlobalVariableSet(prefix + "RSI_BuyMax",   g_RSI_BuyMax);
   GlobalVariableSet(prefix + "RSI_SellMin",  g_RSI_SellMin);
   GlobalVariableSet(prefix + "RSI_SellMax",  g_RSI_SellMax);
   GlobalVariableSet(prefix + "ATR_SL",       g_ATR_SL_Mult);
   GlobalVariableSet(prefix + "ATR_TP",       g_ATR_TP_Mult);
   GlobalVariableSet(prefix + "ATR_Trail",    g_ATR_Trail_Mult);
}

void LoadLearnedParams() {
   string prefix = "CS_" + Symbol_To_Trade + "_";
   g_RSI_BuyMin    = GlobalVariableCheck(prefix + "RSI_BuyMin")  ? GlobalVariableGet(prefix + "RSI_BuyMin")  : DEF_RSI_BUY_MIN;
   g_RSI_BuyMax    = GlobalVariableCheck(prefix + "RSI_BuyMax")  ? GlobalVariableGet(prefix + "RSI_BuyMax")  : DEF_RSI_BUY_MAX;
   g_RSI_SellMin   = GlobalVariableCheck(prefix + "RSI_SellMin") ? GlobalVariableGet(prefix + "RSI_SellMin") : DEF_RSI_SELL_MIN;
   g_RSI_SellMax   = GlobalVariableCheck(prefix + "RSI_SellMax") ? GlobalVariableGet(prefix + "RSI_SellMax") : DEF_RSI_SELL_MAX;
   g_ATR_SL_Mult   = GlobalVariableCheck(prefix + "ATR_SL")      ? GlobalVariableGet(prefix + "ATR_SL")      : DEF_ATR_SL;
   g_ATR_TP_Mult   = GlobalVariableCheck(prefix + "ATR_TP")      ? GlobalVariableGet(prefix + "ATR_TP")      : DEF_ATR_TP;
   g_ATR_Trail_Mult = GlobalVariableCheck(prefix + "ATR_Trail")  ? GlobalVariableGet(prefix + "ATR_Trail")   : DEF_ATR_TRAIL;
}

void ClearLearnedParams() {
   string prefix = "CS_" + Symbol_To_Trade + "_";
   GlobalVariableDel(prefix + "RSI_BuyMin");
   GlobalVariableDel(prefix + "RSI_BuyMax");
   GlobalVariableDel(prefix + "RSI_SellMin");
   GlobalVariableDel(prefix + "RSI_SellMax");
   GlobalVariableDel(prefix + "ATR_SL");
   GlobalVariableDel(prefix + "ATR_TP");
   GlobalVariableDel(prefix + "ATR_Trail");
   Print("Learned parameters reset to defaults.");
}
//+------------------------------------------------------------------+
