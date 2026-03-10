//+------------------------------------------------------------------+
//|                                             ScalperExpert.mq4   |
//|                              Hedge Recovery Expert Advisor       |
//+------------------------------------------------------------------+
//  Strategy (3-phase state machine):
//
//  Phase 1 — ENTRY (trend-confirmed pullback)
//    - H1 EMA50 sets trend direction
//    - M5 EMA21/50 aligns with H1
//    - ADX > 20 confirms trend strength
//    - RSI pullback + recovery triggers entry
//
//  Phase 2 — MAIN ONLY
//    - Main trade runs with trailing stop
//    - If price moves against by HedgeTrigger*ATR → open HEDGE
//
//  Phase 3 — HEDGED
//    - Hedge runs opposite to main, smaller lot
//    - If HEDGE hits TP → close hedge, move main SL to breakeven
//    - If MAIN recovers to TP → all profit
//    - Emergency exit if combined loss > MaxLoss*ATR
//
//  Why high win rate:
//    - Strong entry filter (3 confluences) reduces bad trades
//    - Hedge converts full losses into partial recovery
//    - Breakeven lock means hedged trades rarely fully lose
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict

//=== INPUTS =========================================================
input string          Sym             = "XAUUSD";   // Symbol
input ENUM_TIMEFRAMES TF              = PERIOD_M5;  // Entry timeframe
input double          RiskPercent     = 1.0;        // Risk % per trade
input int             Magic           = 88880101;   // Magic number
input int             Slippage        = 30;

// --- Trend indicators ---
input int    EMA_Fast    = 21;    // M5 fast EMA
input int    EMA_Slow    = 50;    // M5 slow EMA
input int    H1_EMA      = 50;    // H1 trend EMA
input int    RSI_Period  = 14;    // RSI period
input int    ATR_Period  = 14;    // ATR period
input int    ADX_Period  = 14;    // ADX period
input double ADX_Min     = 22.0;  // Min ADX for entry

// --- Main trade exits ---
input double ATR_SL_Mult    = 2.0;  // Main SL = X * ATR
input double ATR_TP_Mult    = 3.0;  // Main TP = X * ATR
input double ATR_Trail_Mult = 1.0;  // Trail distance after breakeven

// --- Hedge parameters ---
input double HedgeTriggerMult = 1.5;  // Open hedge when main is -X*ATR
input double HedgeLotRatio    = 0.6;  // Hedge lots = ratio of main lots
input double HedgeTPMult      = 1.2;  // Hedge TP = X * ATR from hedge entry
input double MaxLossMult      = 4.0;  // Emergency close if combined loss > X*ATR

// --- Session filter ---
input bool UseSession    = true;  // Enable session filter
input int  SessionStart  = 9;     // Hour open
input int  SessionEnd    = 21;    // Hour close
input double MaxSpread   = 35.0;  // Max spread in points

//=== STATE MACHINE ==================================================
enum EState { STATE_IDLE, STATE_MAIN, STATE_HEDGED };

EState g_state        = STATE_IDLE;
int    g_mainTicket   = -1;
int    g_hedgeTicket  = -1;
int    g_mainDir      = -1;   // OP_BUY or OP_SELL
double g_mainATR      = 0;    // ATR at main entry (fixes exit levels)
double g_mainEntry    = 0;
double g_mainLots     = 0;

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Sym)
      Print("WARNING: Chart is ", Symbol(), " but Sym=", Sym);
   Print("ScalperExpert started | SL=", ATR_SL_Mult, "xATR TP=", ATR_TP_Mult,
         "xATR HedgeTrig=", HedgeTriggerMult, "xATR HedgeLot=", HedgeLotRatio, "x");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("ScalperExpert stopped.");
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Sym) return;

   SyncState();   // resync state from open orders (handles restarts)

   switch (g_state) {
      case STATE_IDLE:   HandleIdle();   break;
      case STATE_MAIN:   HandleMain();   break;
      case STATE_HEDGED: HandleHedged(); break;
   }
}

//+------------------------------------------------------------------+
//| STATE: IDLE — look for entry signal                              |
//+------------------------------------------------------------------+
void HandleIdle() {
   if (!IsNewBar())         return;
   if (!InSession())        return;
   if (SpreadTooWide())     return;

   double emaFast = iMA(NULL, TF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(NULL, TF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double h1Ema   = iMA(NULL, PERIOD_H1, H1_EMA, 0, MODE_EMA, PRICE_CLOSE, 1);
   double h1Close = iClose(NULL, PERIOD_H1, 1);
   double rsi0    = iRSI(NULL, TF, RSI_Period, PRICE_CLOSE, 1);
   double rsi1    = iRSI(NULL, TF, RSI_Period, PRICE_CLOSE, 2);
   double adx     = iADX(NULL, TF, ADX_Period, PRICE_CLOSE, MODE_MAIN, 1);
   double atr     = iATR(NULL, TF, ATR_Period, 1);
   double price   = iClose(NULL, TF, 1);

   if (atr <= 0 || adx < ADX_Min) return;

   bool h1Bull = h1Close > h1Ema;
   bool h1Bear = h1Close < h1Ema;
   bool m5Bull = price > emaFast && emaFast > emaSlow;
   bool m5Bear = price < emaFast && emaFast < emaSlow;

   // RSI pullback: dipped below 50 then recovered above 42 (buy)
   //               rose above 50 then fell below 58 (sell)
   bool buySignal  = (rsi1 < 50.0) && (rsi0 > 42.0) && h1Bull && m5Bull;
   bool sellSignal = (rsi1 > 50.0) && (rsi0 < 58.0) && h1Bear && m5Bear;

   if (!buySignal && !sellSignal) return;

   double slDist = ATR_SL_Mult * atr;
   double tpDist = ATR_TP_Mult * atr;
   double lots   = CalculateLots(slDist);
   if (lots <= 0) return;

   int ticket = -1;
   if (buySignal) {
      double sl = NormalizeDouble(Ask - slDist, Digits);
      double tp = NormalizeDouble(Ask + tpDist, Digits);
      ticket = OrderSend(Sym, OP_BUY, lots, Ask, Slippage, sl, tp,
                         "SE Main BUY", Magic, 0, clrGreen);
      if (ticket > 0) {
         g_mainDir   = OP_BUY;
         g_mainEntry = Ask;
      }
   } else {
      double sl = NormalizeDouble(Bid + slDist, Digits);
      double tp = NormalizeDouble(Bid - tpDist, Digits);
      ticket = OrderSend(Sym, OP_SELL, lots, Bid, Slippage, sl, tp,
                         "SE Main SELL", Magic, 0, clrRed);
      if (ticket > 0) {
         g_mainDir   = OP_SELL;
         g_mainEntry = Bid;
      }
   }

   if (ticket > 0) {
      g_mainTicket = ticket;
      g_mainATR    = atr;
      g_mainLots   = lots;
      g_state      = STATE_MAIN;
      Print("MAIN opened #", ticket, " dir=", g_mainDir == OP_BUY ? "BUY" : "SELL",
            " lots=", lots, " ATR=", DoubleToStr(atr, 2),
            " RSI=", DoubleToStr(rsi0, 1), " ADX=", DoubleToStr(adx, 1));
   } else {
      Print("MAIN open failed err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| STATE: MAIN — trail stop, watch for hedge trigger                |
//+------------------------------------------------------------------+
void HandleMain() {
   if (!OrderSelect(g_mainTicket, SELECT_BY_TICKET, MODE_TRADES)) {
      // Main was closed (by TP/SL/manual) — back to idle
      Print("Main trade closed externally → IDLE");
      ResetState();
      return;
   }

   double atr      = iATR(NULL, TF, ATR_Period, 1);
   if (atr <= 0) return;

   double curPrice  = (g_mainDir == OP_BUY) ? Bid : Ask;
   double openPrice = OrderOpenPrice();
   double curSL     = OrderStopLoss();
   double curTP     = OrderTakeProfit();

   // Trail stop once in profit
   double trailDist = ATR_Trail_Mult * atr;
   if (g_mainDir == OP_BUY) {
      double profit_dist = Bid - openPrice;
      if (profit_dist >= atr) {  // in profit by 1xATR → start trailing
         double newSL = NormalizeDouble(Bid - trailDist, Digits);
         if (newSL > curSL + Point)
            OrderModify(g_mainTicket, openPrice, newSL, curTP, 0, clrYellow);
      }
   } else {
      double profit_dist = openPrice - Ask;
      if (profit_dist >= atr) {
         double newSL = NormalizeDouble(Ask + trailDist, Digits);
         if (newSL < curSL - Point || curSL == 0)
            OrderModify(g_mainTicket, openPrice, newSL, curTP, 0, clrYellow);
      }
   }

   // Check hedge trigger: price moved -HedgeTriggerMult*ATR against main
   double lossDist = (g_mainDir == OP_BUY)
                     ? (openPrice - curPrice)
                     : (curPrice - openPrice);

   if (lossDist >= HedgeTriggerMult * g_mainATR) {
      OpenHedge();
   }
}

//+------------------------------------------------------------------+
//| STATE: HEDGED — wait for hedge TP or emergency exit              |
//+------------------------------------------------------------------+
void HandleHedged() {
   bool mainAlive  = OrderSelect(g_mainTicket,  SELECT_BY_TICKET, MODE_TRADES);
   bool hedgeAlive = OrderSelect(g_hedgeTicket, SELECT_BY_TICKET, MODE_TRADES);

   // If hedge closed (hit TP) → move main to breakeven, back to MAIN state
   if (!hedgeAlive && mainAlive) {
      if (OrderSelect(g_mainTicket, SELECT_BY_TICKET, MODE_TRADES)) {
         double openPrice = OrderOpenPrice();
         double buffer    = 0.1 * g_mainATR;
         double beSL      = (g_mainDir == OP_BUY)
                            ? NormalizeDouble(openPrice + buffer, Digits)
                            : NormalizeDouble(openPrice - buffer, Digits);
         double curSL = OrderStopLoss();
         bool needsUpdate = (g_mainDir == OP_BUY)
                            ? (beSL > curSL + Point)
                            : (beSL < curSL - Point || curSL == 0);
         if (needsUpdate)
            OrderModify(g_mainTicket, openPrice, beSL, OrderTakeProfit(), 0, clrLime);
         Print("Hedge TP hit → main #", g_mainTicket, " moved to breakeven SL=", beSL);
      }
      g_hedgeTicket = -1;
      g_state       = STATE_MAIN;
      return;
   }

   // If main closed (TP or trailing stop) → close hedge remainder
   if (!mainAlive && hedgeAlive) {
      if (OrderSelect(g_hedgeTicket, SELECT_BY_TICKET, MODE_TRADES)) {
         double closePrice = (OrderType() == OP_BUY) ? Bid : Ask;
         OrderClose(g_hedgeTicket, OrderLots(), closePrice, Slippage, clrOrange);
         Print("Main closed → closing hedge #", g_hedgeTicket);
      }
      ResetState();
      return;
   }

   // Both closed — back to idle
   if (!mainAlive && !hedgeAlive) {
      ResetState();
      return;
   }

   // Emergency exit: combined floating loss > MaxLossMult * ATR
   double atr = iATR(NULL, TF, ATR_Period, 1);
   if (atr > 0) {
      double combinedLoss = 0;
      if (OrderSelect(g_mainTicket,  SELECT_BY_TICKET, MODE_TRADES))
         combinedLoss += OrderProfit() + OrderSwap() + OrderCommission();
      if (OrderSelect(g_hedgeTicket, SELECT_BY_TICKET, MODE_TRADES))
         combinedLoss += OrderProfit() + OrderSwap() + OrderCommission();

      // Convert max loss to currency
      double tickVal   = MarketInfo(Sym, MODE_TICKVALUE);
      double tickSize  = MarketInfo(Sym, MODE_TICKSIZE);
      double maxLossCur = (MaxLossMult * atr / tickSize) * tickVal * g_mainLots;

      if (combinedLoss <= -MathAbs(maxLossCur)) {
         Print("Emergency exit: combined loss=", DoubleToStr(combinedLoss, 2),
               " limit=", DoubleToStr(-maxLossCur, 2));
         CloseAll();
         ResetState();
      }
   }
}

//+------------------------------------------------------------------+
//| Open hedge trade (opposite direction, smaller lot)               |
//+------------------------------------------------------------------+
void OpenHedge() {
   double atr      = iATR(NULL, TF, ATR_Period, 1);
   if (atr <= 0) return;

   double hedgeLots = NormalizeDouble(g_mainLots * HedgeLotRatio, 2);
   double minLot    = MarketInfo(Sym, MODE_MINLOT);
   double maxLot    = MarketInfo(Sym, MODE_MAXLOT);
   double lotStep   = MarketInfo(Sym, MODE_LOTSTEP);
   hedgeLots = MathFloor(hedgeLots / lotStep) * lotStep;
   hedgeLots = MathMax(minLot, MathMin(maxLot, hedgeLots));

   double hedgeTP   = HedgeTPMult * atr;
   int    hedgeDir  = (g_mainDir == OP_BUY) ? OP_SELL : OP_BUY;
   int    ticket    = -1;

   if (hedgeDir == OP_SELL) {
      double tp = NormalizeDouble(Bid - hedgeTP, Digits);
      ticket = OrderSend(Sym, OP_SELL, hedgeLots, Bid, Slippage, 0, tp,
                         "SE Hedge SELL", Magic, 0, clrOrangeRed);
   } else {
      double tp = NormalizeDouble(Ask + hedgeTP, Digits);
      ticket = OrderSend(Sym, OP_BUY, hedgeLots, Ask, Slippage, 0, tp,
                         "SE Hedge BUY", Magic, 0, clrDodgerBlue);
   }

   if (ticket > 0) {
      g_hedgeTicket = ticket;
      g_state       = STATE_HEDGED;
      Print("HEDGE opened #", ticket, " dir=", hedgeDir == OP_BUY ? "BUY" : "SELL",
            " lots=", hedgeLots, " TP=", DoubleToStr(hedgeTP / Point, 1), "pts");
   } else {
      Print("HEDGE open failed err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close all EA trades                                              |
//+------------------------------------------------------------------+
void CloseAll() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Sym || OrderMagicNumber() != Magic) continue;
      double cp = (OrderType() == OP_BUY) ? Bid : Ask;
      if (!OrderClose(OrderTicket(), OrderLots(), cp, Slippage, clrRed))
         Print("CloseAll failed #", OrderTicket(), " err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Sync state from open orders (handles EA restarts)               |
//+------------------------------------------------------------------+
void SyncState() {
   if (g_state != STATE_IDLE) return;  // already tracking

   int mainT = -1, hedgeT = -1;
   for (int i = 0; i < OrdersTotal(); i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Sym || OrderMagicNumber() != Magic) continue;
      string comment = OrderComment();
      if (StringFind(comment, "SE Main") >= 0) {
         mainT      = OrderTicket();
         g_mainDir  = OrderType();
         g_mainEntry= OrderOpenPrice();
         g_mainLots = OrderLots();
      }
      if (StringFind(comment, "SE Hedge") >= 0)
         hedgeT = OrderTicket();
   }

   if (mainT > 0 && hedgeT > 0) {
      g_mainTicket  = mainT;
      g_hedgeTicket = hedgeT;
      g_mainATR     = iATR(NULL, TF, ATR_Period, 1);
      g_state       = STATE_HEDGED;
      Print("Resumed: STATE_HEDGED main=#", mainT, " hedge=#", hedgeT);
   } else if (mainT > 0) {
      g_mainTicket  = mainT;
      g_mainATR     = iATR(NULL, TF, ATR_Period, 1);
      g_state       = STATE_MAIN;
      Print("Resumed: STATE_MAIN main=#", mainT);
   }
}

//+------------------------------------------------------------------+
void ResetState() {
   g_state       = STATE_IDLE;
   g_mainTicket  = -1;
   g_hedgeTicket = -1;
   g_mainDir     = -1;
   g_mainATR     = 0;
   g_mainEntry   = 0;
   g_mainLots    = 0;
}

//+------------------------------------------------------------------+
double CalculateLots(double slDistance) {
   double tickValue = MarketInfo(Sym, MODE_TICKVALUE);
   double tickSize  = MarketInfo(Sym, MODE_TICKSIZE);
   double minLot    = MarketInfo(Sym, MODE_MINLOT);
   double maxLot    = MarketInfo(Sym, MODE_MAXLOT);
   double lotStep   = MarketInfo(Sym, MODE_LOTSTEP);
   if (tickValue <= 0 || tickSize <= 0 || slDistance <= 0) return 0;
   double lots = (AccountBalance() * RiskPercent / 100.0)
                 / ((slDistance / tickSize) * tickValue);
   lots = MathFloor(lots / lotStep) * lotStep;
   return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lots)), 2);
}

bool InSession() {
   if (!UseSession) return true;
   int h = TimeHour(TimeCurrent());
   return (h >= SessionStart && h < SessionEnd);
}

bool SpreadTooWide() {
   return (MarketInfo(Sym, MODE_SPREAD) > MaxSpread);
}

bool IsNewBar() {
   static datetime last = 0;
   datetime cur = iTime(NULL, TF, 0);
   if (cur != last) { last = cur; return true; }
   return false;
}
//+------------------------------------------------------------------+
