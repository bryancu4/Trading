//+------------------------------------------------------------------+
//|                                               BreakoutBot.mq4   |
//|                     Bollinger Band Squeeze Breakout EA           |
//+------------------------------------------------------------------+
//  Strategy:
//  1. Wait for BB bands to compress (squeeze = low volatility)
//  2. When price breaks outside the bands after a squeeze → enter
//  3. Exit: partial close at TP1, breakeven, then trail to TP2
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict

//=== INPUTS =========================================================
input string          Sym           = "XAUUSD";  // Symbol
input ENUM_TIMEFRAMES TF            = PERIOD_M5; // Timeframe
input double          RiskPercent   = 1.0;       // Risk % per trade
input int             Magic         = 55550101;  // Magic number
input int             Slippage      = 30;

// --- Bollinger Bands ---
input int    BB_Period    = 20;   // BB period
input double BB_Dev       = 2.0;  // BB deviation
input double Squeeze_Pct  = 0.5;  // Squeeze: BB width < X% of price (lower = rarer)

// --- ATR exits ---
input int    ATR_Period      = 14;
input double ATR_SL_Mult     = 1.5;  // SL = X * ATR
input double ATR_TP1_Mult    = 1.5;  // Partial close (50%) at X * ATR
input double ATR_TP2_Mult    = 3.0;  // Final TP at X * ATR
input double ATR_Trail_Mult  = 1.0;  // Trail after breakeven

// --- Daily bias filter ---
input bool   UseDailyBias  = true;  // Only trade in direction of daily bias
input int    D1_EMA_Period  = 50;   // D1 EMA period (primary bias)
// Bias = BULL when: D1 price > D1 EMA  AND  today's price > today's open
// Bias = BEAR when: D1 price < D1 EMA  AND  today's price < today's open
// Bias = NONE when: signals conflict → skip trade

// --- Safety ---
input double MaxSpread      = 35.0; // Max spread (points)
input double DailyLossLimit = 2.0;  // Stop if daily loss > X% balance

//=== GLOBALS ========================================================
bool     g_SqueezeArmed = false;
double   g_BBWidth      = 0;
double   g_DayBalance   = 0;
double   g_DayOpen      = 0;   // today's opening price
datetime g_LastDay      = 0;
int      g_DailyBias    = 0;   // 1=bull, -1=bear, 0=none

#define UI_PFX "BB_"

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Sym)
      Print("WARNING: Chart=", Symbol(), " Sym=", Sym);
   g_DayBalance = AccountBalance();
   g_LastDay    = TimeCurrent();
   DeleteUI();
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   DeleteUI();
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Sym) return;

   RefreshDay();
   UpdateBias();
   TrackSqueeze();
   ManageTrade();
   DrawUI();

   if (!IsNewBar())     return;
   if (HasOpenTrade())  return;
   if (SpreadTooWide()) return;
   if (DailyLossHit())  return;

   CheckEntry();
}

//+------------------------------------------------------------------+
//| Entry: breakout of BB after a squeeze                           |
//+------------------------------------------------------------------+
void CheckEntry() {
   if (!g_SqueezeArmed) return;

   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double close = iClose(NULL, TF, 1);
   double atr   = iATR(NULL, TF, ATR_Period, 1);

   if (upper <= 0 || atr <= 0) return;

   bool buySignal  = (close > upper);
   bool sellSignal = (close < lower);
   if (!buySignal && !sellSignal) return;

   // Apply daily bias filter
   if (UseDailyBias) {
      if (g_DailyBias == 0)  { Print("No clear bias today — skipping"); return; }
      if (buySignal  && g_DailyBias != 1) { Print("BUY signal blocked by BEARISH bias"); return; }
      if (sellSignal && g_DailyBias != -1){ Print("SELL signal blocked by BULLISH bias"); return; }
   }

   double slDist = ATR_SL_Mult  * atr;
   double tpDist = ATR_TP2_Mult * atr;
   double lots   = CalcLots(slDist);
   if (lots <= 0) return;

   if (buySignal) {
      double sl = NormalizeDouble(Ask - slDist, Digits);
      double tp = NormalizeDouble(Ask + tpDist, Digits);
      int t = OrderSend(Sym, OP_BUY, lots, Ask, Slippage, sl, tp,
                        "BB BUY", Magic, 0, clrGreen);
      if (t > 0) {
         Print("BUY #", t, " lots=", lots, " width=", DoubleToStr(g_BBWidth,3), "% SL=", sl, " TP=", tp);
         g_SqueezeArmed = false;
      } else Print("BUY failed err=", GetLastError());

   } else {
      double sl = NormalizeDouble(Bid + slDist, Digits);
      double tp = NormalizeDouble(Bid - tpDist, Digits);
      int t = OrderSend(Sym, OP_SELL, lots, Bid, Slippage, sl, tp,
                        "BB SELL", Magic, 0, clrRed);
      if (t > 0) {
         Print("SELL #", t, " lots=", lots, " width=", DoubleToStr(g_BBWidth,3), "% SL=", sl, " TP=", tp);
         g_SqueezeArmed = false;
      } else Print("SELL failed err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Detect squeeze (bands compress below threshold)                 |
//+------------------------------------------------------------------+
void TrackSqueeze() {
   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double mid   = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_MAIN,  1);
   if (mid <= 0) return;

   g_BBWidth = (upper - lower) / mid * 100.0;

   if (g_BBWidth < Squeeze_Pct && !g_SqueezeArmed) {
      g_SqueezeArmed = true;
      Print("Squeeze armed | width=", DoubleToStr(g_BBWidth, 3), "%");
   }
}

//+------------------------------------------------------------------+
//| Partial close → breakeven → trail                               |
//+------------------------------------------------------------------+
void ManageTrade() {
   double atr = iATR(NULL, TF, ATR_Period, 1);
   if (atr <= 0) return;

   double tp1Dist   = ATR_TP1_Mult  * atr;
   double trailDist = ATR_Trail_Mult * atr;

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Sym || OrderMagicNumber() != Magic) continue;

      double open  = OrderOpenPrice();
      double curSL = OrderStopLoss();
      double curTP = OrderTakeProfit();
      double lots  = OrderLots();
      int    tkt   = OrderTicket();

      if (OrderType() == OP_BUY) {
         if (Bid - open >= tp1Dist && curSL < open) {
            double cl = MathMax(NormalizeDouble(lots * 0.5, 2), MarketInfo(Sym, MODE_MINLOT));
            if (cl < lots) OrderClose(tkt, cl, Bid, Slippage, clrOrange);
            double beSL = NormalizeDouble(open + 0.1 * atr, Digits);
            if (beSL > curSL) OrderModify(tkt, open, beSL, curTP, 0, clrYellow);
         } else if (curSL >= open) {
            double tSL = NormalizeDouble(Bid - trailDist, Digits);
            if (tSL > curSL + Point) OrderModify(tkt, open, tSL, curTP, 0, clrYellow);
         }
      } else if (OrderType() == OP_SELL) {
         if (open - Ask >= tp1Dist && (curSL > open || curSL == 0)) {
            double cl = MathMax(NormalizeDouble(lots * 0.5, 2), MarketInfo(Sym, MODE_MINLOT));
            if (cl < lots) OrderClose(tkt, cl, Ask, Slippage, clrOrange);
            double beSL = NormalizeDouble(open - 0.1 * atr, Digits);
            if (beSL < curSL || curSL == 0) OrderModify(tkt, open, beSL, curTP, 0, clrYellow);
         } else if (curSL > 0 && curSL <= open) {
            double tSL = NormalizeDouble(Ask + trailDist, Digits);
            if (tSL < curSL - Point) OrderModify(tkt, open, tSL, curTP, 0, clrYellow);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UI: BB band lines + squeeze label + dashboard                   |
//+------------------------------------------------------------------+
void DrawUI() {
   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double mid   = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_MAIN,  1);
   if (upper <= 0) return;

   // Band colors: magenta = squeeze armed, gray = watching
   color bandClr = g_SqueezeArmed ? clrMagenta : clrDimGray;
   int   bandW   = g_SqueezeArmed ? 2 : 1;

   DrawHLine(UI_PFX+"Upper", upper, bandClr, STYLE_SOLID, bandW);
   DrawHLine(UI_PFX+"Lower", lower, bandClr, STYLE_SOLID, bandW);
   DrawHLine(UI_PFX+"Mid",   mid,   clrDimGray, STYLE_DOT, 1);

   // Breakout trigger labels
   datetime t = TimeCurrent() + PeriodSeconds(TF) * 6;
   DrawText(UI_PFX+"ULbl", "BB Upper (buy break)", t, upper, bandClr);
   DrawText(UI_PFX+"LLbl", "BB Lower (sell break)", t, lower, bandClr);

   // D1 EMA and Day Open lines
   double d1Ema  = iMA(NULL, PERIOD_D1, D1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE, 1);
   color  biasClr = (g_DailyBias == 1) ? clrLime : (g_DailyBias == -1) ? clrTomato : clrGray;
   if (d1Ema > 0) {
      DrawHLine(UI_PFX+"D1EMA",   d1Ema,    biasClr,    STYLE_DASH, 2);
      DrawText(UI_PFX+"D1EMALbl", "D1 EMA(" + IntegerToString(D1_EMA_Period) + ")",
               TimeCurrent() + PeriodSeconds(TF) * 8, d1Ema, biasClr);
   }
   if (g_DayOpen > 0) {
      DrawHLine(UI_PFX+"DayOpen",   g_DayOpen, clrGold, STYLE_DOT, 1);
      DrawText(UI_PFX+"DayOpenLbl", "Day Open: " + DoubleToStr(g_DayOpen, Digits),
               TimeCurrent() + PeriodSeconds(TF) * 8, g_DayOpen, clrGold);
   }

   // Dashboard comment
   string biasStr = (g_DailyBias ==  1) ? "BULLISH — BUY only"  :
                    (g_DailyBias == -1) ? "BEARISH — SELL only" : "NEUTRAL — no trade";
   string sqzLine = g_SqueezeArmed
      ? "ARMED — waiting for breakout"
      : "Width: " + DoubleToStr(g_BBWidth, 3) + "% (need <" + DoubleToStr(Squeeze_Pct, 2) + "%)";
   string status  = HasOpenTrade()  ? "IN TRADE"    :
                    DailyLossHit()  ? "DAILY LIMIT" :
                    SpreadTooWide() ? "SPREAD WIDE" : "WATCHING";

   Comment(
      "╔══ BreakoutBot (BB Squeeze) ══╗\n" +
      "║ Status : " + status + "\n" +
      "║ Bias   : " + biasStr + "\n" +
      "║ Squeeze: " + sqzLine + "\n" +
      "╠══════════════════════════════╣\n" +
      "║ BB Upper : " + DoubleToStr(upper, Digits) + "\n" +
      "║ BB Lower : " + DoubleToStr(lower, Digits) + "\n" +
      "║ D1 EMA   : " + DoubleToStr(d1Ema,      Digits) + "\n" +
      "║ Day Open : " + DoubleToStr(g_DayOpen,   Digits) + "\n" +
      "║ ATR: " + DoubleToStr(iATR(NULL, TF, ATR_Period, 1) / Point, 1) + "pts" +
      "  Spread: " + DoubleToStr(MarketInfo(Sym, MODE_SPREAD), 0) + "pts\n" +
      "║ Day P&L  : " + DoubleToStr(AccountEquity() - g_DayBalance, 2) + "\n" +
      "╚══════════════════════════════╝"
   );

   ChartRedraw();
}

void DrawHLine(string name, double price, color clr, int style, int width) {
   if (ObjectFind(name) < 0) ObjectCreate(name, OBJ_HLINE, 0, 0, price);
   ObjectSet(name, OBJPROP_PRICE1, price);
   ObjectSet(name, OBJPROP_COLOR,  clr);
   ObjectSet(name, OBJPROP_STYLE,  style);
   ObjectSet(name, OBJPROP_WIDTH,  width);
}

void DrawText(string name, string text, datetime t, double price, color clr) {
   if (ObjectFind(name) < 0) ObjectCreate(name, OBJ_TEXT, 0, t, price);
   ObjectSet(name, OBJPROP_TIME1,  t);
   ObjectSet(name, OBJPROP_PRICE1, price);
   ObjectSetText(name, text, 8, "Arial", clr);
}

void DeleteUI() {
   string names[] = {"Upper","Lower","Mid","ULbl","LLbl"};
   for (int i = 0; i < ArraySize(names); i++)
      ObjectDelete(UI_PFX + names[i]);
}

//+------------------------------------------------------------------+
double CalcLots(double slDist) {
   double tv = MarketInfo(Sym, MODE_TICKVALUE);
   double ts = MarketInfo(Sym, MODE_TICKSIZE);
   double mn = MarketInfo(Sym, MODE_MINLOT);
   double mx = MarketInfo(Sym, MODE_MAXLOT);
   double st = MarketInfo(Sym, MODE_LOTSTEP);
   if (tv <= 0 || ts <= 0 || slDist <= 0) return 0;
   double lots = (AccountBalance() * RiskPercent / 100.0) / ((slDist / ts) * tv);
   lots = MathFloor(lots / st) * st;
   return NormalizeDouble(MathMax(mn, MathMin(mx, lots)), 2);
}

bool HasOpenTrade() {
   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == Sym && OrderMagicNumber() == Magic) return true;
   }
   return false;
}

bool SpreadTooWide() { return MarketInfo(Sym, MODE_SPREAD) > MaxSpread; }

bool DailyLossHit() {
   return (AccountEquity() - g_DayBalance) <= -(g_DayBalance * DailyLossLimit / 100.0);
}

void RefreshDay() {
   datetime now = TimeCurrent();
   if (TimeDay(now) != TimeDay(g_LastDay)) {
      g_DayBalance = AccountBalance();
      g_DayOpen    = iOpen(NULL, PERIOD_D1, 0);
      g_LastDay    = now;
   }
   if (g_DayOpen == 0) g_DayOpen = iOpen(NULL, PERIOD_D1, 0);
}

//+------------------------------------------------------------------+
//| Calculate today's directional bias                              |
//|  BULL  (+1): D1 price > D1 EMA  AND  price > today's open       |
//|  BEAR  (-1): D1 price < D1 EMA  AND  price < today's open       |
//|  NONE   (0): mixed signals → sit out                             |
//+------------------------------------------------------------------+
void UpdateBias() {
   double d1Close  = iClose(NULL, PERIOD_D1, 1);   // yesterday's close (confirmed)
   double d1Ema    = iMA(NULL, PERIOD_D1, D1_EMA_Period, 0, MODE_EMA, PRICE_CLOSE, 1);
   double curPrice = (Bid + Ask) / 2.0;

   if (d1Ema <= 0 || g_DayOpen <= 0) { g_DailyBias = 0; return; }

   bool d1Bull = (d1Close > d1Ema);   // daily trend up
   bool d1Bear = (d1Close < d1Ema);   // daily trend down
   bool intBull = (curPrice > g_DayOpen);  // intraday moving up
   bool intBear = (curPrice < g_DayOpen);  // intraday moving down

   if (d1Bull && intBull)      g_DailyBias =  1;
   else if (d1Bear && intBear) g_DailyBias = -1;
   else                        g_DailyBias =  0;
}

bool IsNewBar() {
   static datetime last = 0;
   datetime cur = iTime(NULL, TF, 0);
   if (cur != last) { last = cur; return true; }
   return false;
}
//+------------------------------------------------------------------+
