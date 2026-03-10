//+------------------------------------------------------------------+
//|                                               BreakoutBot.mq4   |
//|                          Triple Breakout Strategy EA             |
//+------------------------------------------------------------------+
//  3 Breakout modes (selectable):
//
//  MODE_NBAR    — Buy/Sell breakout of the last N candles high/low
//  MODE_ASIAN   — Trade breakout of Asian session range at London open
//  MODE_BBSQZ   — Trade Bollinger Band squeeze release
//  MODE_CONFIRM — All 3 must agree (highest quality, fewer trades)
//
//  Exits: ATR-based SL, partial TP at 1.5x ATR, trail remainder
//  Safety: spread guard, daily loss limit, 1 trade at a time
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict

//=== ENUMS ==========================================================
enum EBreakoutMode {
   MODE_NBAR    = 0,  // N-Bar high/low breakout
   MODE_ASIAN   = 1,  // Asian session range breakout
   MODE_BBSQZ   = 2,  // Bollinger Band squeeze breakout
   MODE_CONFIRM = 3   // All 3 must confirm (most selective)
};

//=== INPUTS =========================================================
input string          Sym            = "XAUUSD";    // Symbol
input ENUM_TIMEFRAMES TF             = PERIOD_M5;   // Timeframe
input EBreakoutMode   Mode           = MODE_CONFIRM; // Breakout mode
input double          RiskPercent    = 1.0;          // Risk % per trade
input int             Magic          = 55550101;     // Magic number
input int             Slippage       = 30;

// --- Mode 1: N-Bar breakout ---
input int    NBar_Period      = 20;   // Lookback bars for range
input double NBar_Buffer      = 5.0;  // Extra points beyond range to confirm

// --- Mode 2: Asian session range ---
input int    Asian_StartHour  = 0;    // Asian session start (broker hour)
input int    Asian_EndHour    = 8;    // Asian session end (broker hour)
input int    London_StartHour = 8;    // Trade window start (broker hour)
input int    London_EndHour   = 17;   // Trade window end (broker hour)
input double Asian_Buffer     = 10.0; // Extra points beyond range to confirm

// --- Mode 3: Bollinger Band squeeze ---
input int    BB_Period        = 20;   // BB period
input double BB_Dev           = 2.0;  // BB deviation
input double Squeeze_Pct      = 0.5;  // Squeeze when BB width < X% of price

// --- ATR exits (all modes share these) ---
input int    ATR_Period       = 14;
input double ATR_SL_Mult      = 1.5;  // SL = X * ATR
input double ATR_TP1_Mult     = 1.5;  // Partial close (50%) at X * ATR
input double ATR_TP2_Mult     = 3.0;  // Final TP at X * ATR
input double ATR_Trail_Mult   = 1.0;  // Trail distance after breakeven

// --- Safety ---
input double MaxSpread        = 35.0; // Max spread (points)
input double DailyLossLimit   = 2.0;  // Stop if daily loss > X% balance

//=== GLOBALS ========================================================
double   g_AsianHigh      = 0;
double   g_AsianLow       = 999999;
bool     g_AsianReady     = false;
datetime g_LastAsianDay   = 0;
datetime g_AsianStartTime = 0;   // time Asian session opened today
datetime g_AsianEndTime   = 0;   // time Asian session closed today

bool     g_SqueezeWasActive = false;
double   g_LastBBWidth      = 0;

double   g_DayBalance = 0;
datetime g_LastDay    = 0;

// UI object name prefix (avoids conflicts with other EAs)
#define UI_PFX  "BBB_"

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Sym)
      Print("WARNING: Chart=", Symbol(), " Sym=", Sym);
   g_DayBalance = AccountBalance();
   g_LastDay    = TimeCurrent();
   DeleteUIObjects();
   Print("BreakoutBot started | Mode=", Mode,
         " SL=", ATR_SL_Mult, "xATR TP1=", ATR_TP1_Mult,
         "xATR TP2=", ATR_TP2_Mult, "xATR");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   DeleteUIObjects();
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Sym) return;

   RefreshDayBalance();
   BuildAsianRange();
   TrackBBSqueeze();
   ManageOpenTrade();
   DrawUI();

   if (!IsNewBar())     return;
   if (HasOpenTrade())  return;
   if (SpreadTooWide()) return;
   if (DailyLossHit())  return;

   CheckEntry();
}

//+------------------------------------------------------------------+
//| Evaluate all 3 signals and open trade based on mode             |
//+------------------------------------------------------------------+
void CheckEntry() {
   int buyNBar = 0, sellNBar = 0;
   int buyAsian= 0, sellAsian= 0;
   int buyBB   = 0, sellBB   = 0;

   GetNBarSignal(buyNBar, sellNBar);
   GetAsianSignal(buyAsian, sellAsian);
   GetBBSqueezeSignal(buyBB, sellBB);

   bool doBuy = false, doSell = false;

   switch (Mode) {
      case MODE_NBAR:
         doBuy  = (buyNBar  > 0);
         doSell = (sellNBar > 0);
         break;
      case MODE_ASIAN:
         doBuy  = (buyAsian  > 0);
         doSell = (sellAsian > 0);
         break;
      case MODE_BBSQZ:
         doBuy  = (buyBB  > 0);
         doSell = (sellBB > 0);
         break;
      case MODE_CONFIRM:
         doBuy  = (buyNBar > 0)  && (buyAsian > 0)  && (buyBB > 0);
         doSell = (sellNBar > 0) && (sellAsian > 0) && (sellBB > 0);
         break;
   }

   if (!doBuy && !doSell) return;

   double atr = iATR(NULL, TF, ATR_Period, 1);
   if (atr <= 0) return;

   double slDist = ATR_SL_Mult  * atr;
   double tpDist = ATR_TP2_Mult * atr;
   double lots   = CalculateLots(slDist);
   if (lots <= 0) return;

   string tag = "[N=" + IntegerToString(buyNBar + sellNBar) +
                " A=" + IntegerToString(buyAsian + sellAsian) +
                " B=" + IntegerToString(buyBB + sellBB) + "]";

   if (doBuy) {
      double sl = NormalizeDouble(Ask - slDist, Digits);
      double tp = NormalizeDouble(Ask + tpDist, Digits);
      int ticket = OrderSend(Sym, OP_BUY, lots, Ask, Slippage, sl, tp,
                             "BreakBot BUY", Magic, 0, clrGreen);
      if (ticket > 0) {
         Print("BUY #", ticket, " lots=", lots, " SL=", sl, " TP=", tp, " ", tag);
         g_AsianReady      = false;
         g_SqueezeWasActive= false;
      } else {
         Print("BUY failed err=", GetLastError());
      }
   } else if (doSell) {
      double sl = NormalizeDouble(Bid + slDist, Digits);
      double tp = NormalizeDouble(Bid - tpDist, Digits);
      int ticket = OrderSend(Sym, OP_SELL, lots, Bid, Slippage, sl, tp,
                             "BreakBot SELL", Magic, 0, clrRed);
      if (ticket > 0) {
         Print("SELL #", ticket, " lots=", lots, " SL=", sl, " TP=", tp, " ", tag);
         g_AsianReady      = false;
         g_SqueezeWasActive= false;
      } else {
         Print("SELL failed err=", GetLastError());
      }
   }
}

//+------------------------------------------------------------------+
//| SIGNAL 1: N-Bar range breakout                                  |
//+------------------------------------------------------------------+
void GetNBarSignal(int &buy, int &sell) {
   buy = 0; sell = 0;
   double ptSize = MarketInfo(Sym, MODE_POINT);
   double highN = 0, lowN = 999999;

   for (int i = 2; i <= NBar_Period + 1; i++) {
      double h = iHigh(NULL, TF, i);
      double l = iLow(NULL, TF,  i);
      if (h > highN) highN = h;
      if (l < lowN)  lowN  = l;
   }

   double close     = iClose(NULL, TF, 1);
   double buyLevel  = highN + NBar_Buffer * ptSize;
   double sellLevel = lowN  - NBar_Buffer * ptSize;

   if (close > buyLevel)  buy  = 1;
   if (close < sellLevel) sell = 1;
}

//+------------------------------------------------------------------+
//| SIGNAL 2: Asian session range breakout                          |
//+------------------------------------------------------------------+
void GetAsianSignal(int &buy, int &sell) {
   buy = 0; sell = 0;
   if (!g_AsianReady) return;

   int hour = TimeHour(TimeCurrent());
   if (hour < London_StartHour || hour >= London_EndHour) return;

   double ptSize    = MarketInfo(Sym, MODE_POINT);
   double close     = iClose(NULL, TF, 1);
   double buyLevel  = g_AsianHigh + Asian_Buffer * ptSize;
   double sellLevel = g_AsianLow  - Asian_Buffer * ptSize;

   if (close > buyLevel)  buy  = 1;
   if (close < sellLevel) sell = 1;
}

//+------------------------------------------------------------------+
//| SIGNAL 3: Bollinger Band squeeze breakout                       |
//+------------------------------------------------------------------+
void GetBBSqueezeSignal(int &buy, int &sell) {
   buy = 0; sell = 0;
   if (!g_SqueezeWasActive) return;  // must have had a prior squeeze

   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double close = iClose(NULL, TF, 1);

   if (upper <= 0) return;

   if (close > upper) buy  = 1;
   if (close < lower) sell = 1;
}

//+------------------------------------------------------------------+
//| Track BB squeeze — sets flag when bands compress                |
//+------------------------------------------------------------------+
void TrackBBSqueeze() {
   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   double mid   = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_MAIN,  1);
   if (mid <= 0) return;

   double widthPct  = (upper - lower) / mid * 100.0;
   g_LastBBWidth    = widthPct;
   if (widthPct < Squeeze_Pct && !g_SqueezeWasActive) {
      g_SqueezeWasActive = true;
      Print("BB Squeeze detected | width=", DoubleToStr(widthPct, 3), "% of price");
   }
}

//+------------------------------------------------------------------+
//| Build Asian session high/low — resets each new day              |
//+------------------------------------------------------------------+
void BuildAsianRange() {
   datetime now = TimeCurrent();
   int      hour = TimeHour(now);

   // New day reset
   if (TimeDay(now) != TimeDay(g_LastAsianDay)) {
      g_AsianHigh      = 0;
      g_AsianLow       = 999999;
      g_AsianReady     = false;
      g_AsianStartTime = 0;
      g_AsianEndTime   = 0;
      g_LastAsianDay   = now;
   }

   // Accumulate during Asian hours
   if (hour >= Asian_StartHour && hour < Asian_EndHour) {
      if (g_AsianStartTime == 0) g_AsianStartTime = now;
      double h = iHigh(NULL, TF, 1);
      double l = iLow(NULL, TF, 1);
      if (h > g_AsianHigh) g_AsianHigh = h;
      if (l < g_AsianLow)  g_AsianLow  = l;
   }

   // Mark ready once session ends
   if (hour >= Asian_EndHour && !g_AsianReady
       && g_AsianHigh > 0 && g_AsianLow < 999999
       && g_AsianHigh > g_AsianLow) {
      g_AsianReady   = true;
      g_AsianEndTime = now;
      Print("Asian range ready | High=", g_AsianHigh, " Low=", g_AsianLow,
            " Width=", DoubleToStr((g_AsianHigh - g_AsianLow) / Point, 1), "pts");
   }
}

//+------------------------------------------------------------------+
//| Manage open trade: partial close → breakeven → trail           |
//+------------------------------------------------------------------+
void ManageOpenTrade() {
   double atr = iATR(NULL, TF, ATR_Period, 1);
   if (atr <= 0) return;

   double tp1Dist   = ATR_TP1_Mult  * atr;
   double trailDist = ATR_Trail_Mult * atr;

   for (int i = OrdersTotal() - 1; i >= 0; i--) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Sym || OrderMagicNumber() != Magic) continue;

      double openPrice = OrderOpenPrice();
      double curSL     = OrderStopLoss();
      double curTP     = OrderTakeProfit();
      double lots      = OrderLots();
      int    ticket    = OrderTicket();

      if (OrderType() == OP_BUY) {
         if (Bid - openPrice >= tp1Dist && curSL < openPrice) {
            double cl = NormalizeDouble(lots * 0.5, 2);
            cl = MathMax(cl, MarketInfo(Sym, MODE_MINLOT));
            if (cl < lots) OrderClose(ticket, cl, Bid, Slippage, clrOrange);
            double beSL = NormalizeDouble(openPrice + 0.1 * atr, Digits);
            if (beSL > curSL)
               OrderModify(ticket, openPrice, beSL, curTP, 0, clrYellow);
         } else if (curSL >= openPrice) {
            double tSL = NormalizeDouble(Bid - trailDist, Digits);
            if (tSL > curSL + Point)
               OrderModify(ticket, openPrice, tSL, curTP, 0, clrYellow);
         }
      } else if (OrderType() == OP_SELL) {
         if (openPrice - Ask >= tp1Dist && (curSL > openPrice || curSL == 0)) {
            double cl = NormalizeDouble(lots * 0.5, 2);
            cl = MathMax(cl, MarketInfo(Sym, MODE_MINLOT));
            if (cl < lots) OrderClose(ticket, cl, Ask, Slippage, clrOrange);
            double beSL = NormalizeDouble(openPrice - 0.1 * atr, Digits);
            if (beSL < curSL || curSL == 0)
               OrderModify(ticket, openPrice, beSL, curTP, 0, clrYellow);
         } else if (curSL > 0 && curSL <= openPrice) {
            double tSL = NormalizeDouble(Ask + trailDist, Digits);
            if (tSL < curSL - Point)
               OrderModify(ticket, openPrice, tSL, curTP, 0, clrYellow);
         }
      }
   }
}

//+------------------------------------------------------------------+
double CalculateLots(double slDist) {
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

void RefreshDayBalance() {
   datetime now = TimeCurrent();
   if (TimeDay(now) != TimeDay(g_LastDay)) {
      g_DayBalance = AccountBalance();
      g_LastDay    = now;
   }
}

bool IsNewBar() {
   static datetime last = 0;
   datetime cur = iTime(NULL, TF, 0);
   if (cur != last) { last = cur; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Master UI draw — called every tick                              |
//+------------------------------------------------------------------+
void DrawUI() {
   DrawAsianRangeBox();
   DrawNBarLevels();
   DrawBBSqueezeHighlight();
   DrawDashboard();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| 1. Asian session range: shaded box + breakout trigger lines     |
//+------------------------------------------------------------------+
void DrawAsianRangeBox() {
   string boxName  = UI_PFX + "AsianBox";
   string hiName   = UI_PFX + "AsianHi";
   string loName   = UI_PFX + "AsianLo";
   string buyTrig  = UI_PFX + "AsianBuyTrig";
   string sellTrig = UI_PFX + "AsianSellTrig";
   string hiLbl    = UI_PFX + "AsianHiLbl";
   string loLbl    = UI_PFX + "AsianLoLbl";

   // Remove stale objects if no range yet
   if (g_AsianHigh == 0 || g_AsianLow >= 999999) {
      ObjectDelete(boxName); ObjectDelete(hiName); ObjectDelete(loName);
      ObjectDelete(buyTrig); ObjectDelete(sellTrig);
      ObjectDelete(hiLbl);   ObjectDelete(loLbl);
      return;
   }

   double ptSize    = MarketInfo(Sym, MODE_POINT);
   double buyLevel  = g_AsianHigh + Asian_Buffer * ptSize;
   double sellLevel = g_AsianLow  - Asian_Buffer * ptSize;

   // Time range for the box (Asian start → now)
   datetime t1 = (g_AsianStartTime > 0) ? g_AsianStartTime : iTime(NULL, TF, NBar_Period + 5);
   datetime t2 = TimeCurrent() + PeriodSeconds(TF) * 10;

   // Shaded rectangle showing Asian range
   if (ObjectFind(boxName) < 0)
      ObjectCreate(boxName, OBJ_RECTANGLE, 0, t1, g_AsianHigh, t2, g_AsianLow);
   ObjectSet(boxName, OBJPROP_TIME1,  t1);
   ObjectSet(boxName, OBJPROP_TIME2,  t2);
   ObjectSet(boxName, OBJPROP_PRICE1, g_AsianHigh);
   ObjectSet(boxName, OBJPROP_PRICE2, g_AsianLow);
   ObjectSet(boxName, OBJPROP_COLOR,  clrSteelBlue);
   ObjectSet(boxName, OBJPROP_STYLE,  STYLE_SOLID);
   ObjectSet(boxName, OBJPROP_WIDTH,  1);
   ObjectSet(boxName, OBJPROP_BACK,   true);  // draw behind candles

   // Asian High line
   DrawHLine(hiName,   g_AsianHigh, clrDodgerBlue, STYLE_DASH, 1);
   DrawHLine(loName,   g_AsianLow,  clrDodgerBlue, STYLE_DASH, 1);

   // Breakout trigger lines (where the actual trade entry fires)
   color trigColor = g_AsianReady ? clrLime : clrGray;
   DrawHLine(buyTrig,  buyLevel,  trigColor, STYLE_DOT, 2);
   DrawHLine(sellTrig, sellLevel, trigColor, STYLE_DOT, 2);

   // Labels
   DrawLabel(hiLbl,   "Asian High: " + DoubleToStr(g_AsianHigh, Digits),
             t2, g_AsianHigh, clrDodgerBlue);
   DrawLabel(loLbl,   "Asian Low: "  + DoubleToStr(g_AsianLow,  Digits),
             t2, g_AsianLow,  clrDodgerBlue);
}

//+------------------------------------------------------------------+
//| 2. N-Bar range: high/low lines + trigger levels                 |
//+------------------------------------------------------------------+
void DrawNBarLevels() {
   string hiName   = UI_PFX + "NBarHi";
   string loName   = UI_PFX + "NBarLo";
   string buyTrig  = UI_PFX + "NBarBuyTrig";
   string sellTrig = UI_PFX + "NBarSellTrig";
   string hiLbl    = UI_PFX + "NBarHiLbl";
   string loLbl    = UI_PFX + "NBarLoLbl";

   double ptSize = MarketInfo(Sym, MODE_POINT);
   double highN = 0, lowN = 999999;
   for (int i = 2; i <= NBar_Period + 1; i++) {
      double h = iHigh(NULL, TF, i);
      double l = iLow(NULL, TF, i);
      if (h > highN) highN = h;
      if (l < lowN)  lowN  = l;
   }
   if (highN <= 0 || lowN >= 999999) return;

   double buyLevel  = highN + NBar_Buffer * ptSize;
   double sellLevel = lowN  - NBar_Buffer * ptSize;

   DrawHLine(hiName,   highN,     clrOrange,   STYLE_DASH, 1);
   DrawHLine(loName,   lowN,      clrOrange,   STYLE_DASH, 1);
   DrawHLine(buyTrig,  buyLevel,  clrLimeGreen, STYLE_DOT, 2);
   DrawHLine(sellTrig, sellLevel, clrTomato,    STYLE_DOT, 2);

   datetime lblTime = TimeCurrent() + PeriodSeconds(TF) * 12;
   DrawLabel(hiLbl, "NBar High (" + IntegerToString(NBar_Period) + "): " + DoubleToStr(highN, Digits),
             lblTime, highN, clrOrange);
   DrawLabel(loLbl, "NBar Low  (" + IntegerToString(NBar_Period) + "): " + DoubleToStr(lowN, Digits),
             lblTime, lowN,  clrOrange);
}

//+------------------------------------------------------------------+
//| 3. BB squeeze: highlight upper/lower bands when squeeze active  |
//+------------------------------------------------------------------+
void DrawBBSqueezeHighlight() {
   string upName  = UI_PFX + "BBUpper";
   string loName  = UI_PFX + "BBLower";
   string lblName = UI_PFX + "BBSqzLbl";

   double upper = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
   double lower = iBands(NULL, TF, BB_Period, BB_Dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
   if (upper <= 0) return;

   color bandColor = g_SqueezeWasActive ? clrMagenta : clrGray;
   int   bandWidth = g_SqueezeWasActive ? 2 : 1;

   DrawHLine(upName, upper, bandColor, STYLE_SOLID, bandWidth);
   DrawHLine(loName, lower, bandColor, STYLE_SOLID, bandWidth);

   // Squeeze label near upper band
   string sqzText = g_SqueezeWasActive
                    ? "BB SQUEEZE ARMED (width=" + DoubleToStr(g_LastBBWidth, 3) + "%)"
                    : "BB width=" + DoubleToStr(g_LastBBWidth, 3) + "% (need <" + DoubleToStr(Squeeze_Pct, 2) + "%)";
   datetime lblTime = TimeCurrent() + PeriodSeconds(TF) * 14;
   DrawLabel(lblName, sqzText, lblTime, upper, bandColor);
}

//+------------------------------------------------------------------+
//| 4. Dashboard panel — top-right corner info                      |
//+------------------------------------------------------------------+
void DrawDashboard() {
   // Collect live signal states
   int buyN = 0, sellN = 0, buyA = 0, sellA = 0, buyB = 0, sellB = 0;
   GetNBarSignal(buyN, sellN);
   GetAsianSignal(buyA, sellA);
   GetBBSqueezeSignal(buyB, sellB);

   string modeStr;
   switch (Mode) {
      case MODE_NBAR:    modeStr = "N-BAR"; break;
      case MODE_ASIAN:   modeStr = "ASIAN"; break;
      case MODE_BBSQZ:   modeStr = "BB SQUEEZE"; break;
      case MODE_CONFIRM: modeStr = "CONFIRM (all 3)"; break;
      default:           modeStr = "?";
   }

   string spread    = DoubleToStr(MarketInfo(Sym, MODE_SPREAD), 0) + "pts";
   string atrStr    = DoubleToStr(iATR(NULL, TF, ATR_Period, 1) / Point, 1) + "pts";
   string dailyPnL  = DoubleToStr(AccountEquity() - g_DayBalance, 2);

   // Signal icons
   string nbarSig  = (buyN  > 0) ? "BUY ▲"  : (sellN  > 0) ? "SELL ▼"  : "—";
   string asianSig = (buyA  > 0) ? "BUY ▲"  : (sellA  > 0) ? "SELL ▼"  : (g_AsianReady ? "READY" : "BUILDING");
   string bbSig    = (buyB  > 0) ? "BUY ▲"  : (sellB  > 0) ? "SELL ▼"  : (g_SqueezeWasActive ? "ARMED" : "NONE");

   bool tradeOpen = HasOpenTrade();
   string status  = tradeOpen ? "IN TRADE" : (DailyLossHit() ? "DAILY LIMIT" : (SpreadTooWide() ? "SPREAD WIDE" : "WATCHING"));

   string dash =
      "╔══ BreakoutBot v1 ══╗\n" +
      "║ Mode  : " + modeStr + "\n" +
      "║ Status: " + status  + "\n" +
      "║ ATR   : " + atrStr  + "   Spread: " + spread + "\n" +
      "║ Day P&L: " + dailyPnL + "\n" +
      "╠══ Signals ══════════╣\n" +
      "║ N-Bar  (" + IntegerToString(NBar_Period) + " bars) : " + nbarSig  + "\n" +
      "║ Asian Range       : " + asianSig + "\n" +
      "║ BB Squeeze        : " + bbSig    + "\n";

   if (g_AsianReady)
      dash += "║ Asian Hi/Lo: " + DoubleToStr(g_AsianHigh, Digits) + " / " + DoubleToStr(g_AsianLow, Digits) + "\n";

   dash += "╚═════════════════════╝";

   Comment(dash);
}

//+------------------------------------------------------------------+
//| Draw / update a horizontal line                                 |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, int style, int width) {
   if (ObjectFind(name) < 0)
      ObjectCreate(name, OBJ_HLINE, 0, 0, price);
   ObjectSet(name, OBJPROP_PRICE1, price);
   ObjectSet(name, OBJPROP_COLOR,  clr);
   ObjectSet(name, OBJPROP_STYLE,  style);
   ObjectSet(name, OBJPROP_WIDTH,  width);
}

//+------------------------------------------------------------------+
//| Draw / update a price-level text label on the chart             |
//+------------------------------------------------------------------+
void DrawLabel(string name, string text, datetime time, double price, color clr) {
   if (ObjectFind(name) < 0)
      ObjectCreate(name, OBJ_TEXT, 0, time, price);
   ObjectSet(name,    OBJPROP_TIME1,  time);
   ObjectSet(name,    OBJPROP_PRICE1, price);
   ObjectSetText(name, text, 8, "Arial", clr);
}

//+------------------------------------------------------------------+
//| Delete all UI objects created by this EA                        |
//+------------------------------------------------------------------+
void DeleteUIObjects() {
   string names[] = {
      "AsianBox","AsianHi","AsianLo","AsianBuyTrig","AsianSellTrig","AsianHiLbl","AsianLoLbl",
      "NBarHi","NBarLo","NBarBuyTrig","NBarSellTrig","NBarHiLbl","NBarLoLbl",
      "BBUpper","BBLower","BBSqzLbl"
   };
   for (int i = 0; i < ArraySize(names); i++)
      ObjectDelete(UI_PFX + names[i]);
}
//+------------------------------------------------------------------+
