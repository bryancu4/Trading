//+------------------------------------------------------------------+
//|                                         BreakoutIndicator.mq4   |
//|          Consolidation range detector + breakout signals         |
//+------------------------------------------------------------------+
//  What it draws:
//  - Cyan line segments    : range HIGH during consolidation
//  - Cyan line segments    : range LOW  during consolidation
//  - Gray dotted segments  : range MID  during consolidation
//  - Blue up arrow  (233)  : bullish breakout bar
//  - Red down arrow (234)  : bearish breakout bar
//  - Teal chart box        : current LIVE consolidation only
//  - Comment dashboard     : live range stats
//
//  NOTE: Line buffers (not objects) are used for historical ranges
//        so they show correctly in backtesting and on scrolled charts.
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict
#property indicator_chart_window

#property indicator_buffers 5

// Arrows
#property indicator_color1  clrDodgerBlue
#property indicator_color2  clrOrangeRed
#property indicator_width1  2
#property indicator_width2  2

// Range lines
#property indicator_color3  clrAqua
#property indicator_color4  clrAqua
#property indicator_color5  clrGray
#property indicator_width3  2
#property indicator_width4  2
#property indicator_width5  1

//=== INPUTS =========================================================
input int    RangeBars           = 20;    // Bars to define the range
input double ConsolidationMaxATR = 2.0;   // Range height < this * ATR to qualify
input int    ATR_Period          = 14;    // ATR period
input bool   ShowMidLine         = true;  // Show midpoint line
input bool   ShowDashboard       = true;  // Show info panel
input bool   ShowLiveBox         = true;  // Draw teal box on current live range

//=== BUFFERS ========================================================
double BuyArrow[];     // 0 — buy signal arrows
double SellArrow[];    // 1 — sell signal arrows
double RangeHigh[];    // 2 — range high during consolidation
double RangeLow[];     // 3 — range low  during consolidation
double RangeMid[];     // 4 — range mid  during consolidation

//=== STATE ==========================================================
bool     g_InConsol   = false;
datetime g_ConsolStart= 0;
double   g_ConsolHi   = 0;
double   g_ConsolLo   = 0;
double   g_ConsolATR  = 0;

double   g_LiveHi     = 0;
double   g_LiveLo     = 0;
bool     g_LiveArmed  = false;

//+------------------------------------------------------------------+
int OnInit() {
   // Arrows
   SetIndexBuffer(0, BuyArrow);
   SetIndexBuffer(1, SellArrow);
   SetIndexEmptyValue(0, 0.0);
   SetIndexEmptyValue(1, 0.0);
   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, 2, clrDodgerBlue);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, 2, clrOrangeRed);
   SetIndexArrow(0, 233);
   SetIndexArrow(1, 234);
   SetIndexLabel(0, "Breakout BUY");
   SetIndexLabel(1, "Breakout SELL");

   // Range lines — DRAW_LINE draws a continuous line wherever buffer != EMPTY_VALUE
   SetIndexBuffer(2, RangeHigh);
   SetIndexBuffer(3, RangeLow);
   SetIndexBuffer(4, RangeMid);
   SetIndexEmptyValue(2, EMPTY_VALUE);
   SetIndexEmptyValue(3, EMPTY_VALUE);
   SetIndexEmptyValue(4, EMPTY_VALUE);
   SetIndexStyle(2, DRAW_LINE, STYLE_SOLID, 2, clrAqua);
   SetIndexStyle(3, DRAW_LINE, STYLE_SOLID, 2, clrAqua);
   SetIndexStyle(4, DRAW_LINE, STYLE_DOT,   1, clrGray);
   SetIndexLabel(2, "Range High");
   SetIndexLabel(3, "Range Low");
   SetIndexLabel(4, "Range Mid");

   IndicatorShortName("BreakoutIndicator(" + IntegerToString(RangeBars) + ")");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   DeleteLiveBox();
   Comment("");
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[]) {

   if (rates_total < RangeBars + ATR_Period + 2) return(0);

   // Full recalculation
   if (prev_calculated == 0) {
      ArrayInitialize(BuyArrow,  0.0);
      ArrayInitialize(SellArrow, 0.0);
      ArrayInitialize(RangeHigh, EMPTY_VALUE);
      ArrayInitialize(RangeLow,  EMPTY_VALUE);
      ArrayInitialize(RangeMid,  EMPTY_VALUE);
      g_InConsol  = false;
      g_ConsolHi  = 0;
      g_ConsolLo  = 0;
      g_ConsolATR = 0;
      g_LiveHi    = 0;
      g_LiveLo    = 0;
      g_LiveArmed = false;
      DeleteLiveBox();
   }

   int start = (prev_calculated <= RangeBars + ATR_Period)
               ? RangeBars + ATR_Period
               : prev_calculated - 1;

   for (int i = start; i < rates_total; i++) {
      // Clear this bar's buffers first
      BuyArrow[i]  = 0.0;
      SellArrow[i] = 0.0;
      RangeHigh[i] = EMPTY_VALUE;
      RangeLow[i]  = EMPTY_VALUE;
      RangeMid[i]  = EMPTY_VALUE;

      double atr = iATR(Symbol(), Period(), ATR_Period, rates_total - 1 - i);
      if (atr <= 0) continue;

      // Rolling high/low over the previous RangeBars completed bars
      double hi = -1e10, lo = 1e10;
      for (int j = i - RangeBars; j < i; j++) {
         if (high[j] > hi) hi = high[j];
         if (low[j]  < lo) lo = low[j];
      }

      bool isConsol = ((hi - lo) <= atr * ConsolidationMaxATR);
      bool isLast   = (i == rates_total - 1);

      //--- Consolidation START
      if (isConsol && !g_InConsol) {
         g_InConsol    = true;
         g_ConsolStart = time[i - RangeBars];
         g_ConsolHi    = hi;
         g_ConsolLo    = lo;
         g_ConsolATR   = atr;
      }

      //--- Consolidation CONTINUES — expand bounds to union of all windows
      if (isConsol && g_InConsol) {
         if (hi > g_ConsolHi) g_ConsolHi = hi;
         if (lo < g_ConsolLo) g_ConsolLo = lo;
      }

      //--- Consolidation ACTIVE — fill buffer values for this bar
      if (isConsol) {
         RangeHigh[i] = g_ConsolHi;
         RangeLow[i]  = g_ConsolLo;
         if (ShowMidLine) RangeMid[i] = (g_ConsolHi + g_ConsolLo) / 2.0;
      }

      //--- Consolidation ENDED — emit signal on the breakout bar
      if (!isConsol && g_InConsol) {
         bool bullBreak = (close[i] > g_ConsolHi) && (close[i] > open[i]);
         bool bearBreak = (close[i] < g_ConsolLo) && (close[i] < open[i]);

         if (bullBreak) BuyArrow[i]  = low[i]  - g_ConsolATR * 0.5;
         if (bearBreak) SellArrow[i] = high[i] + g_ConsolATR * 0.5;

         g_InConsol  = false;
         g_LiveArmed = false;
      }

      //--- LIVE bar: update or clear the teal chart box
      if (isLast) {
         if (isConsol) {
            g_LiveHi    = g_ConsolHi;
            g_LiveLo    = g_ConsolLo;
            g_LiveArmed = true;
            if (ShowLiveBox) DrawLiveBox(g_ConsolStart, g_ConsolHi, g_ConsolLo);
         } else {
            g_LiveHi    = 0;
            g_LiveLo    = 0;
            g_LiveArmed = false;
            DeleteLiveBox();
         }
      }
   }

   if (ShowDashboard) UpdateDashboard();
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Live box — only for the current active consolidation             |
//+------------------------------------------------------------------+
void DrawLiveBox(datetime t1, double hi, double lo) {
   datetime t2 = TimeCurrent() + Period() * 60 * 5;
   string   n  = "BRK_LiveBox";

   if (ObjectFind(n) < 0)
      ObjectCreate(n, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSet(n, OBJPROP_TIME1,  t1);
   ObjectSet(n, OBJPROP_PRICE1, hi);
   ObjectSet(n, OBJPROP_TIME2,  t2);
   ObjectSet(n, OBJPROP_PRICE2, lo);
   ObjectSet(n, OBJPROP_COLOR,  clrTeal);
   ObjectSet(n, OBJPROP_BACK,   true);
}

void DeleteLiveBox() {
   if (ObjectFind("BRK_LiveBox") >= 0) ObjectDelete("BRK_LiveBox");
}

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateDashboard() {
   double atr    = iATR(Symbol(), Period(), ATR_Period, 1);
   double ptSize = MarketInfo(Symbol(), MODE_POINT);
   if (ptSize <= 0) return;

   double spread   = MarketInfo(Symbol(), MODE_SPREAD);
   double rangeH   = (g_LiveHi > 0) ? (g_LiveHi - g_LiveLo) / ptSize : 0;
   double maxRange = (atr > 0) ? atr * ConsolidationMaxATR / ptSize : 0;
   string state    = g_LiveArmed ? "CONSOLIDATION - watching breakout" : "No active consolidation";

   string tfStr;
   switch (Period()) {
      case PERIOD_M1:  tfStr = "M1";  break;
      case PERIOD_M5:  tfStr = "M5";  break;
      case PERIOD_M15: tfStr = "M15"; break;
      case PERIOD_M30: tfStr = "M30"; break;
      case PERIOD_H1:  tfStr = "H1";  break;
      case PERIOD_H4:  tfStr = "H4";  break;
      case PERIOD_D1:  tfStr = "D1";  break;
      default: tfStr = IntegerToString(Period());
   }

   string dash = "";
   dash += "=== BreakoutIndicator ===\n";
   dash += "Symbol : " + Symbol() + "   TF: " + tfStr + "\n";
   dash += "Spread : " + DoubleToStr(spread, 0) + "pts\n";
   dash += "ATR    : " + DoubleToStr(atr / ptSize, 1) + "pts" +
           "   Max box: " + DoubleToStr(maxRange, 1) + "pts\n";
   if (g_LiveHi > 0)
      dash += "Range  : " + DoubleToStr(rangeH, 1) + "pts\n" +
              "Box    : " + DoubleToStr(g_LiveLo, Digits) +
              " - " + DoubleToStr(g_LiveHi, Digits) + "\n";
   else
      dash += "Range  : scanning...\n";
   dash += "State  : " + state + "\n";
   Comment(dash);
}
//+------------------------------------------------------------------+
