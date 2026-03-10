//+------------------------------------------------------------------+
//|                                                ClaudeScalper.mq4 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
//  Strategy: H1 trend filter + M5 pullback entry (EMA21/50 + RSI + ADX)
//  Exits:    Partial close at TP1, breakeven, then trail to TP2
//  Safety:   Session filter, spread guard, daily loss limit
//  Adapts:   Win-rate based RSI/ATR tuning via GlobalVariables
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "3.00"
#property strict

//=== INPUTS =========================================================
input string          Symbol_To_Trade   = "XAUUSD";  // Symbol
input ENUM_TIMEFRAMES Timeframe         = PERIOD_M5;  // Entry timeframe
input double          RiskPercent       = 1.0;        // Risk % per trade
input int             Magic             = 20240101;   // Magic number
input int             Slippage          = 30;         // Slippage (points)

// --- Indicators ---
input int   EMA_Fast       = 21;    // M5 fast EMA
input int   EMA_Slow       = 50;    // M5 slow EMA
input int   H1_EMA         = 50;    // H1 trend EMA
input int   RSI_Period     = 14;    // RSI period
input int   ADX_Period     = 14;    // ADX period
input double ADX_Min       = 20.0;  // Minimum ADX for entry

// --- ATR-based exits ---
input double ATR_SL_Mult   = 1.5;   // SL = X * ATR
input double ATR_TP1_Mult  = 1.5;   // Partial TP = X * ATR (50% close)
input double ATR_TP2_Mult  = 3.0;   // Final TP = X * ATR
input double ATR_Trail_Mult= 1.0;   // Trail distance after TP1 hit

// --- Session filter (broker server time hours, GMT+2 default) ---
input bool   UseSessionFilter = true;  // Enable session filter
input int    SessionStartHour = 9;     // Session open hour
input int    SessionEndHour   = 21;    // Session close hour

// --- Safety ---
input double MaxSpreadPoints  = 35.0;  // Max allowed spread (points)
input double DailyLossLimit   = 2.0;   // Stop trading if daily loss > X% balance

// --- Adaptive learning ---
input int    LearnSampleSize  = 20;    // Rolling trade window for adaptation
input bool   ResetLearning    = false; // Wipe saved learned params on start

//=== ADAPTIVE PARAMS (tuned by learning system) =====================
double g_RSI_PullbackBuy;    // RSI must dip below this before buy trigger
double g_RSI_TriggerBuy;     // RSI must recover above this to trigger buy
double g_RSI_PullbackSell;   // RSI must rise above this before sell trigger
double g_RSI_TriggerSell;    // RSI must fall below this to trigger sell
double g_ATR_SL;
double g_ATR_TP1;
double g_ATR_TP2;
double g_ATR_Trail;

#define DEF_RSI_PB_BUY    50.0
#define DEF_RSI_TR_BUY    42.0
#define DEF_RSI_PB_SELL   50.0
#define DEF_RSI_TR_SELL   58.0

//=== TRADE TRACKING =================================================
double g_TradeProfit[];
int    g_TradeCount   = 0;
int    g_LastHistory  = 0;
double g_DayStartBalance = 0;
datetime g_LastDayCheck  = 0;

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Symbol_To_Trade)
      Print("WARNING: Chart symbol ", Symbol(), " != ", Symbol_To_Trade);

   ArrayResize(g_TradeProfit, LearnSampleSize);
   ArrayInitialize(g_TradeProfit, 0);

   if (ResetLearning) ClearLearnedParams();
   LoadLearnedParams();

   g_LastHistory    = OrdersHistoryTotal();
   g_DayStartBalance = AccountBalance();
   g_LastDayCheck   = TimeCurrent();

   Print("ClaudeScalper v3 | RSI pullback<", g_RSI_PullbackBuy, " trigger>", g_RSI_TriggerBuy,
         " | SL=", g_ATR_SL, " TP1=", g_ATR_TP1, " TP2=", g_ATR_TP2);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   SaveLearnedParams();
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Symbol_To_Trade) return;

   RefreshDayBalance();
   ManageOpenTrade();
   CheckClosedTrades();

   if (!IsNewBar())    return;
   if (HasOpenTrade()) return;
   if (!IsTradingSession()) return;
   if (IsSpreadTooWide())   return;
   if (IsDailyLossHit())    return;

   // --- Indicators ---
   double emaFast  = iMA(NULL, Timeframe, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow  = iMA(NULL, Timeframe, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double h1Ema    = iMA(NULL, PERIOD_H1, H1_EMA,   0, MODE_EMA, PRICE_CLOSE, 1);
   double h1Close  = iClose(NULL, PERIOD_H1, 1);
   double rsi0     = iRSI(NULL, Timeframe, RSI_Period, PRICE_CLOSE, 1);  // last closed bar
   double rsi1     = iRSI(NULL, Timeframe, RSI_Period, PRICE_CLOSE, 2);  // bar before that
   double adx      = iADX(NULL, Timeframe, ADX_Period, PRICE_CLOSE, MODE_MAIN, 1);
   double atr      = iATR(NULL, Timeframe, ATR_Period, 1);
   double price    = iClose(NULL, Timeframe, 1);

   if (atr <= 0 || adx <= 0) return;

   // Trend alignment: M5 must agree with H1
   bool h1Bull = (h1Close > h1Ema);
   bool h1Bear = (h1Close < h1Ema);
   bool m5Bull = (price > emaFast) && (emaFast > emaSlow);
   bool m5Bear = (price < emaFast) && (emaFast < emaSlow);

   // ADX confirms trending
   bool trending = (adx >= ADX_Min);

   // RSI pullback entry: RSI dipped then recovered (buy) / rose then fell (sell)
   bool rsiBuySignal  = (rsi1 < g_RSI_PullbackBuy) && (rsi0 > g_RSI_TriggerBuy);
   bool rsiSellSignal = (rsi1 > g_RSI_PullbackSell) && (rsi0 < g_RSI_TriggerSell);

   double sl_dist  = g_ATR_SL   * atr;
   double tp1_dist = g_ATR_TP1  * atr;
   double tp2_dist = g_ATR_TP2  * atr;

   if (h1Bull && m5Bull && trending && rsiBuySignal) {
      double entry = Ask;
      double sl    = entry - sl_dist;
      double tp    = entry + tp2_dist;
      double lots  = CalculateLots(sl_dist);
      if (lots > 0) {
         int ticket = OrderSend(Symbol(), OP_BUY, lots, entry, Slippage,
                                NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                                "CS3 BUY", Magic, 0, clrGreen);
         if (ticket > 0)
            Print("BUY #", ticket, " lots=", lots, " RSI=", DoubleToStr(rsi0,1),
                  " ADX=", DoubleToStr(adx,1), " SL=", sl, " TP=", tp);
         else
            Print("BUY failed err=", GetLastError());
      }
   } else if (h1Bear && m5Bear && trending && rsiSellSignal) {
      double entry = Bid;
      double sl    = entry + sl_dist;
      double tp    = entry - tp2_dist;
      double lots  = CalculateLots(sl_dist);
      if (lots > 0) {
         int ticket = OrderSend(Symbol(), OP_SELL, lots, entry, Slippage,
                                NormalizeDouble(sl, Digits), NormalizeDouble(tp, Digits),
                                "CS3 SELL", Magic, 0, clrRed);
         if (ticket > 0)
            Print("SELL #", ticket, " lots=", lots, " RSI=", DoubleToStr(rsi0,1),
                  " ADX=", DoubleToStr(adx,1), " SL=", sl, " TP=", tp);
         else
            Print("SELL failed err=", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| Manage open trade: partial close → breakeven → trail             |
//+------------------------------------------------------------------+
void ManageOpenTrade() {
   double atr       = iATR(NULL, Timeframe, ATR_Period, 1);
   if (atr <= 0) return;

   double tp1_dist  = g_ATR_TP1  * atr;
   double trail_dist= g_ATR_Trail * atr;

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Symbol() || OrderMagicNumber() != Magic) continue;

      double openPrice = OrderOpenPrice();
      double curSL     = OrderStopLoss();
      double curTP     = OrderTakeProfit();
      double lots      = OrderLots();
      int    ticket    = OrderTicket();

      if (OrderType() == OP_BUY) {
         double profit_dist = Bid - openPrice;
         // Step 1: Partial close at TP1 if SL is still below entry (not yet at BE)
         if (profit_dist >= tp1_dist && curSL < openPrice) {
            double closeLots = NormalizeDouble(lots * 0.5, 2);
            closeLots = MathMax(closeLots, MarketInfo(Symbol(), MODE_MINLOT));
            if (closeLots < lots) {
               if (OrderClose(ticket, closeLots, Bid, Slippage, clrOrange))
                  Print("Partial close BUY #", ticket, " lots=", closeLots);
            }
            // Move SL to breakeven + small buffer
            double newSL = openPrice + 0.1 * atr;
            if (newSL > curSL)
               OrderModify(ticket, openPrice, NormalizeDouble(newSL, Digits), curTP, 0, clrYellow);
         }
         // Step 2: Trail after breakeven
         else if (curSL >= openPrice) {
            double trailSL = Bid - trail_dist;
            if (trailSL > curSL + Point)
               OrderModify(ticket, openPrice, NormalizeDouble(trailSL, Digits), curTP, 0, clrYellow);
         }
      } else if (OrderType() == OP_SELL) {
         double profit_dist = openPrice - Ask;
         // Step 1: Partial close at TP1
         if (profit_dist >= tp1_dist && (curSL > openPrice || curSL == 0)) {
            double closeLots = NormalizeDouble(lots * 0.5, 2);
            closeLots = MathMax(closeLots, MarketInfo(Symbol(), MODE_MINLOT));
            if (closeLots < lots) {
               if (OrderClose(ticket, closeLots, Ask, Slippage, clrOrange))
                  Print("Partial close SELL #", ticket, " lots=", closeLots);
            }
            // Move SL to breakeven - small buffer
            double newSL = openPrice - 0.1 * atr;
            if (newSL < curSL || curSL == 0)
               OrderModify(ticket, openPrice, NormalizeDouble(newSL, Digits), curTP, 0, clrYellow);
         }
         // Step 2: Trail after breakeven
         else if (curSL > 0 && curSL <= openPrice) {
            double trailSL = Ask + trail_dist;
            if (trailSL < curSL - Point)
               OrderModify(ticket, openPrice, NormalizeDouble(trailSL, Digits), curTP, 0, clrYellow);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect newly closed trades and adapt parameters                  |
//+------------------------------------------------------------------+
void CheckClosedTrades() {
   int histTotal = OrdersHistoryTotal();
   if (histTotal <= g_LastHistory) return;

   for (int i = g_LastHistory; i < histTotal; i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if (OrderSymbol() != Symbol() || OrderMagicNumber() != Magic) continue;
      if (OrderType() != OP_BUY && OrderType() != OP_SELL) continue;

      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      int    idx    = g_TradeCount % LearnSampleSize;
      g_TradeProfit[idx] = profit;
      g_TradeCount++;

      AdaptParameters();
      Print("Learn: profit=", DoubleToStr(profit,2),
            " winRate=", DoubleToStr(CalcWinRate(),2),
            " RSI_PB=", g_RSI_PullbackBuy, " RSI_Trig=", g_RSI_TriggerBuy);
   }

   g_LastHistory = histTotal;
   SaveLearnedParams();
}

//+------------------------------------------------------------------+
void AdaptParameters() {
   int filled = MathMin(g_TradeCount, LearnSampleSize);
   if (filled < 5) return;

   double winRate = CalcWinRate();
   double totalP = 0, totalL = 0;
   for (int i = 0; i < filled; i++) {
      if (g_TradeProfit[i] > 0) totalP += g_TradeProfit[i];
      else                       totalL += MathAbs(g_TradeProfit[i]);
   }
   double pf = (totalL > 0) ? totalP / totalL : 2.0;

   // Tighten RSI pullback threshold when losing (require deeper pullback)
   if (winRate < 0.40) {
      g_RSI_PullbackBuy   = MathMax(g_RSI_PullbackBuy  - 2.0, 40.0); // need deeper dip
      g_RSI_TriggerBuy    = MathMax(g_RSI_TriggerBuy   - 1.0, 38.0);
      g_RSI_PullbackSell  = MathMin(g_RSI_PullbackSell + 2.0, 60.0);
      g_RSI_TriggerSell   = MathMin(g_RSI_TriggerSell  + 1.0, 62.0);
   } else if (winRate > 0.65) {
      g_RSI_PullbackBuy   = MathMin(g_RSI_PullbackBuy  + 1.0, 55.0); // allow shallower pullback
      g_RSI_TriggerBuy    = MathMin(g_RSI_TriggerBuy   + 1.0, 48.0);
      g_RSI_PullbackSell  = MathMax(g_RSI_PullbackSell - 1.0, 45.0);
      g_RSI_TriggerSell   = MathMax(g_RSI_TriggerSell  - 1.0, 52.0);
   }

   // Poor profit factor: widen SL so trades breathe more
   if (pf < 1.0) {
      g_ATR_SL    = MathMin(g_ATR_SL    + 0.1, 2.5);
      g_ATR_TP1   = MathMin(g_ATR_TP1   + 0.1, 2.5);
      g_ATR_TP2   = MathMin(g_ATR_TP2   + 0.1, 4.5);
   } else if (pf > 2.0) {
      g_ATR_SL    = MathMax(g_ATR_SL    - 0.1, 1.2);
      g_ATR_TP1   = MathMax(g_ATR_TP1   - 0.1, 1.2);
      g_ATR_TP2   = MathMax(g_ATR_TP2   - 0.1, 2.5);
   }
}

double CalcWinRate() {
   int filled = MathMin(g_TradeCount, LearnSampleSize);
   if (filled == 0) return 0.5;
   int wins = 0;
   for (int i = 0; i < filled; i++)
      if (g_TradeProfit[i] > 0) wins++;
   return (double)wins / filled;
}

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool IsTradingSession() {
   if (!UseSessionFilter) return true;
   int hour = TimeHour(TimeCurrent());
   return (hour >= SessionStartHour && hour < SessionEndHour);
}

bool IsSpreadTooWide() {
   double spread = MarketInfo(Symbol(), MODE_SPREAD);
   return (spread > MaxSpreadPoints);
}

bool IsDailyLossHit() {
   double dailyPnL = AccountEquity() - g_DayStartBalance;
   double limit    = -g_DayStartBalance * DailyLossLimit / 100.0;
   return (dailyPnL <= limit);
}

void RefreshDayBalance() {
   datetime now = TimeCurrent();
   if (TimeDay(now) != TimeDay(g_LastDayCheck)) {
      g_DayStartBalance = AccountBalance();
      g_LastDayCheck    = now;
   }
}

//+------------------------------------------------------------------+
double CalculateLots(double slDistance) {
   double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
   double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
   double minLot    = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot    = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep   = MarketInfo(Symbol(), MODE_LOTSTEP);
   if (tickValue <= 0 || tickSize <= 0 || slDistance <= 0) return 0;
   double riskAmt  = AccountBalance() * RiskPercent / 100.0;
   double lots     = riskAmt / ((slDistance / tickSize) * tickValue);
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lots)), 2);
}

bool HasOpenTrade() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == Symbol() && OrderMagicNumber() == Magic) return true;
   }
   return false;
}

bool IsNewBar() {
   static datetime last = 0;
   datetime cur = iTime(NULL, Timeframe, 0);
   if (cur != last) { last = cur; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Persistence                                                      |
//+------------------------------------------------------------------+
void SaveLearnedParams() {
   string p = "CS3_" + Symbol_To_Trade + "_";
   GlobalVariableSet(p+"RSI_PBBuy",  g_RSI_PullbackBuy);
   GlobalVariableSet(p+"RSI_TRBuy",  g_RSI_TriggerBuy);
   GlobalVariableSet(p+"RSI_PBSell", g_RSI_PullbackSell);
   GlobalVariableSet(p+"RSI_TRSell", g_RSI_TriggerSell);
   GlobalVariableSet(p+"ATR_SL",     g_ATR_SL);
   GlobalVariableSet(p+"ATR_TP1",    g_ATR_TP1);
   GlobalVariableSet(p+"ATR_TP2",    g_ATR_TP2);
   GlobalVariableSet(p+"ATR_Trail",  g_ATR_Trail);
}

void LoadLearnedParams() {
   string p = "CS3_" + Symbol_To_Trade + "_";
   g_RSI_PullbackBuy  = GlobalVariableCheck(p+"RSI_PBBuy")  ? GlobalVariableGet(p+"RSI_PBBuy")  : DEF_RSI_PB_BUY;
   g_RSI_TriggerBuy   = GlobalVariableCheck(p+"RSI_TRBuy")  ? GlobalVariableGet(p+"RSI_TRBuy")  : DEF_RSI_TR_BUY;
   g_RSI_PullbackSell = GlobalVariableCheck(p+"RSI_PBSell") ? GlobalVariableGet(p+"RSI_PBSell") : DEF_RSI_PB_SELL;
   g_RSI_TriggerSell  = GlobalVariableCheck(p+"RSI_TRSell") ? GlobalVariableGet(p+"RSI_TRSell") : DEF_RSI_TR_SELL;
   g_ATR_SL           = GlobalVariableCheck(p+"ATR_SL")     ? GlobalVariableGet(p+"ATR_SL")     : ATR_SL_Mult;
   g_ATR_TP1          = GlobalVariableCheck(p+"ATR_TP1")    ? GlobalVariableGet(p+"ATR_TP1")    : ATR_TP1_Mult;
   g_ATR_TP2          = GlobalVariableCheck(p+"ATR_TP2")    ? GlobalVariableGet(p+"ATR_TP2")    : ATR_TP2_Mult;
   g_ATR_Trail        = GlobalVariableCheck(p+"ATR_Trail")  ? GlobalVariableGet(p+"ATR_Trail")  : ATR_Trail_Mult;
}

void ClearLearnedParams() {
   string p = "CS3_" + Symbol_To_Trade + "_";
   string keys[8] = {"RSI_PBBuy","RSI_TRBuy","RSI_PBSell","RSI_TRSell",
                      "ATR_SL","ATR_TP1","ATR_TP2","ATR_Trail"};
   for (int i = 0; i < 8; i++) GlobalVariableDel(p + keys[i]);
   Print("Learned params reset.");
}
//+------------------------------------------------------------------+
