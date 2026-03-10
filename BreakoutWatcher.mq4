//+------------------------------------------------------------------+
//|                                         BreakoutIndicator.mq4   |
//|          Consolidation range detector + breakout signals         |
//+------------------------------------------------------------------+
//  What it draws:
//  - Teal box              : active consolidation (live, updates every tick)
//  - Dark blue box         : completed consolidation that broke UP
//  - Dark red box          : completed consolidation that broke DOWN
//  - Dim gray box          : completed consolidation with no clean breakout
//  - Aqua H-lines          : live range high / low
//  - Gray dotted line      : live range midpoint
//  - Blue up arrow  (233)  : bullish breakout bar
//  - Red down arrow (234)  : bearish breakout bar
//  - Comment dashboard     : live range stats
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict
#property indicator_chart_window

#property indicator_buffers 2
#property indicator_color1  clrDodgerBlue
#property indicator_color2  clrOrangeRed
#property indicator_width1  2
#property indicator_width2  2

//=== INPUTS =========================================================
input int    RangeBars           = 20;            // Bars to build the range
input double ConsolidationMaxATR = 2.0;           // Range height < this * ATR to qualify
input int    ATR_Period          = 14;            // ATR period
input bool   ShowMidLine         = true;          // Show midpoint line
input bool   ShowDashboard       = true;          // Show info panel
input color  BoxBuyBreak         = C'0,50,100';   // Box color: broke upward
input color  BoxSellBreak        = C'100,30,0';   // Box color: broke downward
input color  BoxNoBreak          = C'40,55,55';   // Box color: no clean breakout
input color  BoxLive             = clrTeal;       // Active consolidation color

//=== BUFFERS ========================================================
double BuyArrow[];
double SellArrow[];

//=== CONSOLIDATION STATE (persists between OnCalculate calls) =======
bool     g_InConsol    = false;
datetime g_ConsolStart = 0;
double   g_ConsolHi    = 0;
double   g_ConsolLo    = 0;
double   g_ConsolATR   = 0;

// Live range values (for dashboard)
double   g_LiveHi = 0;
double   g_LiveLo = 0;
bool     g_LiveArmed = false;

//+------------------------------------------------------------------+
int OnInit() {
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
   IndicatorShortName("BreakoutIndicator(" + IntegerToString(RangeBars) + ")");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   DeleteAllObjects();
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

   // Full recalculation — wipe everything and rebuild from scratch
   if (prev_calculated == 0) {
      DeleteAllObjects();
      ArrayInitialize(BuyArrow,  0);
      ArrayInitialize(SellArrow, 0);
      g_InConsol   = false;
      g_ConsolHi   = 0;
      g_ConsolLo   = 0;
      g_ConsolATR  = 0;
      g_LiveHi     = 0;
      g_LiveLo     = 0;
      g_LiveArmed  = false;
   }

   // Start bar: on incremental update, go back 1 bar to re-check boundary
   int start = (prev_calculated <= RangeBars + ATR_Period)
               ? RangeBars + ATR_Period
               : prev_calculated - 1;

   for (int i = start; i < rates_total; i++) {
      BuyArrow[i]  = 0.0;
      SellArrow[i] = 0.0;

      double atr = iATR(Symbol(), Period(), ATR_Period, rates_total - 1 - i);
      if (atr <= 0) continue;

      // Rolling high/low over previous RangeBars completed bars
      double hi = -1e10, lo = 1e10;
      for (int j = i - RangeBars; j < i; j++) {
         if (high[j] > hi) hi = high[j];
         if (low[j]  < lo) lo = low[j];
      }

      bool isConsol = ((hi - lo) <= atr * ConsolidationMaxATR);
      bool isLast   = (i == rates_total - 1);

      //------------------------------------------------------------------
      // CONSOLIDATION START
      //------------------------------------------------------------------
      if (isConsol && !g_InConsol) {
         g_InConsol    = true;
         g_ConsolStart = time[i - RangeBars];
         g_ConsolHi    = hi;
         g_ConsolLo    = lo;
         g_ConsolATR   = atr;
      }

      //------------------------------------------------------------------
      // CONSOLIDATION CONTINUES — expand bounds to cover full period
      //------------------------------------------------------------------
      if (isConsol && g_InConsol) {
         if (hi > g_ConsolHi) g_ConsolHi = hi;
         if (lo < g_ConsolLo) g_ConsolLo = lo;
      }

      //------------------------------------------------------------------
      // CONSOLIDATION ENDED — draw permanent box for completed zone
      //------------------------------------------------------------------
      if (!isConsol && g_InConsol) {
         bool bullBreak = (close[i] > g_ConsolHi) && (close[i] > open[i]);
         bool bearBreak = (close[i] < g_ConsolLo) && (close[i] < open[i]);

         color boxClr = BoxNoBreak;
         if (bullBreak) { boxClr = BoxBuyBreak;  BuyArrow[i]  = low[i]  - g_ConsolATR * 0.5; }
         if (bearBreak) { boxClr = BoxSellBreak; SellArrow[i] = high[i] + g_ConsolATR * 0.5; }

         // Use end-time as unique ID — prevents duplicates on incremental recalc
         string boxId = "BRK_Box_" + IntegerToString((int)time[i]);
         if (ObjectFind(boxId) < 0)
            DrawPermBox(boxId, g_ConsolStart, time[i], g_ConsolHi, g_ConsolLo, boxClr);

         g_InConsol  = false;
         g_LiveArmed = false;
      }

      //------------------------------------------------------------------
      // LIVE BAR — update the teal active box
      //------------------------------------------------------------------
      if (isLast) {
         if (isConsol) {
            g_LiveHi    = g_ConsolHi;
            g_LiveLo    = g_ConsolLo;
            g_LiveArmed = true;
            DrawLiveBox(g_ConsolStart, g_ConsolHi, g_ConsolLo);
         } else {
            g_LiveHi    = 0;
            g_LiveLo    = 0;
            g_LiveArmed = false;
            FadeLiveBox();
         }
      }
   }

   if (ShowDashboard) UpdateDashboard();
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Draw live (active) consolidation box — updates every tick        |
//+------------------------------------------------------------------+
void DrawLiveBox(datetime t1, double hi, double lo) {
   datetime t2 = TimeCurrent() + Period() * 60 * 5;

   string name = "BRK_LiveBox";
   if (ObjectFind(name) < 0)
      ObjectCreate(name, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSet(name, OBJPROP_TIME1,  t1);
   ObjectSet(name, OBJPROP_PRICE1, hi);
   ObjectSet(name, OBJPROP_TIME2,  t2);
   ObjectSet(name, OBJPROP_PRICE2, lo);
   ObjectSet(name, OBJPROP_COLOR,  BoxLive);
   ObjectSet(name, OBJPROP_BACK,   true);

   DrawHLine("BRK_LiveHi",  hi,             clrAqua, STYLE_SOLID, 1);
   DrawHLine("BRK_LiveLo",  lo,             clrAqua, STYLE_SOLID, 1);
   if (ShowMidLine)
      DrawHLine("BRK_LiveMid", (hi + lo) / 2.0, clrGray, STYLE_DOT, 1);
}

//+------------------------------------------------------------------+
//| Fade live box when consolidation breaks                          |
//+------------------------------------------------------------------+
void FadeLiveBox() {
   string names[] = {"BRK_LiveBox","BRK_LiveHi","BRK_LiveLo","BRK_LiveMid"};
   for (int i = 0; i < ArraySize(names); i++)
      if (ObjectFind(names[i]) >= 0)
         ObjectSet(names[i], OBJPROP_COLOR, BoxNoBreak);
}

//+------------------------------------------------------------------+
//| Draw a permanent historical box for a completed consolidation    |
//+------------------------------------------------------------------+
void DrawPermBox(string id, datetime t1, datetime t2,
                 double hi, double lo, color clr) {
   if (ObjectCreate(id, OBJ_RECTANGLE, 0, t1, hi, t2, lo)) {
      ObjectSet(id, OBJPROP_COLOR, clr);
      ObjectSet(id, OBJPROP_BACK,  true);
   }

   // Horizontal segment lines (not infinite H-lines, scoped to the box width)
   string hId = id + "_H";
   string lId = id + "_L";
   color lineClr = (clr == BoxBuyBreak) ? clrSteelBlue :
                   (clr == BoxSellBreak) ? clrIndianRed : clrDimGray;

   if (ObjectFind(hId) < 0) {
      ObjectCreate(hId, OBJ_TREND, 0, t1, hi, t2, hi);
      ObjectSet(hId, OBJPROP_COLOR, lineClr);
      ObjectSet(hId, OBJPROP_STYLE, STYLE_DOT);
      ObjectSet(hId, OBJPROP_RAY,   false);
   }
   if (ObjectFind(lId) < 0) {
      ObjectCreate(lId, OBJ_TREND, 0, t1, lo, t2, lo);
      ObjectSet(lId, OBJPROP_COLOR, lineClr);
      ObjectSet(lId, OBJPROP_STYLE, STYLE_DOT);
      ObjectSet(lId, OBJPROP_RAY,   false);
   }
}

//+------------------------------------------------------------------+
//| Dashboard info panel                                             |
//+------------------------------------------------------------------+
void UpdateDashboard() {
   double atr    = iATR(Symbol(), Period(), ATR_Period, 1);
   double ptSize = MarketInfo(Symbol(), MODE_POINT);
   if (ptSize <= 0) return;

   double spread   = MarketInfo(Symbol(), MODE_SPREAD);
   double rangeH   = (g_LiveHi > 0) ? (g_LiveHi - g_LiveLo) / ptSize : 0;
   double maxRange = (atr > 0) ? atr * ConsolidationMaxATR / ptSize : 0;

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

   string state = g_LiveArmed ? "CONSOLIDATION - watching for breakout" : "No active consolidation";

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
//| Helpers                                                          |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, int style, int width) {
   if (ObjectFind(name) < 0)
      ObjectCreate(name, OBJ_HLINE, 0, 0, price);
   ObjectSet(name, OBJPROP_PRICE1, price);
   ObjectSet(name, OBJPROP_COLOR,  clr);
   ObjectSet(name, OBJPROP_STYLE,  style);
   ObjectSet(name, OBJPROP_WIDTH,  width);
}

void DeleteAllObjects() {
   for (int i = ObjectsTotal() - 1; i >= 0; i--) {
      string name = ObjectName(i);
      if (StringFind(name, "BRK_") == 0)
         ObjectDelete(name);
   }
}
//+------------------------------------------------------------------+
