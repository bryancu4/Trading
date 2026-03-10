//+------------------------------------------------------------------+
//|                                         BreakoutIndicator.mq4   |
//|          Consolidation range detector + breakout signals         |
//+------------------------------------------------------------------+
//  What it draws:
//  - Teal filled rectangle : active consolidation zone
//  - Aqua H-lines          : range high and low (solid while active)
//  - Gray dotted line      : range midpoint
//  - Blue up arrow         : bullish breakout signal
//  - Red down arrow        : bearish breakout signal
//  - Dashboard (Comment)   : live range stats
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict
#property indicator_chart_window

//--- Arrow buffers
#property indicator_buffers 2
#property indicator_color1  clrDodgerBlue
#property indicator_color2  clrOrangeRed
#property indicator_width1  2
#property indicator_width2  2

//=== INPUTS =========================================================
input int    RangeBars           = 20;          // Bars to build the range
input double ConsolidationMaxATR = 2.0;         // Range must be < this * ATR
input int    ATR_Period          = 14;          // ATR period
input bool   ShowMidLine         = true;        // Show range midpoint line
input bool   ShowDashboard       = true;        // Show info panel
input color  BoxColor            = clrTeal;     // Consolidation box color
input color  BreakoutLineColor   = clrDimGray;  // Faded range line color

//=== BUFFERS ========================================================
double BuyArrow[];
double SellArrow[];

//=== GLOBALS ========================================================
double   g_RangeHigh  = 0;
double   g_RangeLow   = 0;
bool     g_RangeArmed = false;
int      g_BoxCount   = 0;

//+------------------------------------------------------------------+
int OnInit() {
   SetIndexBuffer(0, BuyArrow);
   SetIndexBuffer(1, SellArrow);
   SetIndexEmptyValue(0, 0.0);
   SetIndexEmptyValue(1, 0.0);
   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, 2, clrDodgerBlue);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, 2, clrOrangeRed);
   SetIndexArrow(0, 233);  // up arrow
   SetIndexArrow(1, 234);  // down arrow
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

   // Full recalc: wipe all drawn objects
   if (prev_calculated == 0) DeleteAllObjects();

   int start = (prev_calculated <= RangeBars + ATR_Period)
               ? RangeBars + ATR_Period
               : prev_calculated - 1;

   for (int i = start; i < rates_total - 1; i++) {
      BuyArrow[i]  = 0.0;
      SellArrow[i] = 0.0;

      double atr = iATR(Symbol(), Period(), ATR_Period, rates_total - 1 - i);
      if (atr <= 0) continue;

      // Range spans bars [i-RangeBars .. i-1]
      double hi = -1e10, lo = 1e10;
      datetime rangeStart = time[i - RangeBars];
      for (int j = i - RangeBars; j < i; j++) {
         if (high[j] > hi) hi = high[j];
         if (low[j]  < lo) lo = low[j];
      }

      double height        = hi - lo;
      bool isConsolidation = (height <= atr * ConsolidationMaxATR);
      bool isLiveBar       = (i == rates_total - 2);

      // Update live range visuals on current bar
      if (isLiveBar) {
         if (isConsolidation) {
            g_RangeHigh  = hi;
            g_RangeLow   = lo;
            g_RangeArmed = true;
            DrawLiveRange(rangeStart, hi, lo);
         } else {
            if (g_RangeArmed) {
               g_RangeArmed = false;
               FadeRange();
            }
         }
      }

      if (!isConsolidation) continue;

      // Breakout on bar i-1 closing outside the range
      double prevClose = close[i - 1];
      double prevOpen  = open[i - 1];
      bool bullBreak   = (prevClose > hi) && (prevClose > prevOpen);
      bool bearBreak   = (prevClose < lo) && (prevClose < prevOpen);

      if (bullBreak) {
         BuyArrow[i - 1] = low[i - 1] - atr * 0.3;
         // Draw a historical breakout box for each signal
         string id = "BRK_HBox_" + IntegerToString(i);
         if (ObjectFind(id) < 0)
            DrawBreakoutBox(id, rangeStart, time[i], hi, lo, true);
      }
      if (bearBreak) {
         SellArrow[i - 1] = high[i - 1] + atr * 0.3;
         string id = "BRK_HBox_" + IntegerToString(i);
         if (ObjectFind(id) < 0)
            DrawBreakoutBox(id, rangeStart, time[i], hi, lo, false);
      }
   }

   if (ShowDashboard) UpdateDashboard();

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Draw / update the live consolidation box                        |
//+------------------------------------------------------------------+
void DrawLiveRange(datetime t1, double hi, double lo) {
   datetime t2 = TimeCurrent() + Period() * 60 * 5;

   string boxName = "BRK_LiveBox";
   if (ObjectFind(boxName) < 0)
      ObjectCreate(boxName, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSet(boxName, OBJPROP_TIME1,  t1);
   ObjectSet(boxName, OBJPROP_PRICE1, hi);
   ObjectSet(boxName, OBJPROP_TIME2,  t2);
   ObjectSet(boxName, OBJPROP_PRICE2, lo);
   ObjectSet(boxName, OBJPROP_COLOR,  BoxColor);
   ObjectSet(boxName, OBJPROP_STYLE,  STYLE_SOLID);
   ObjectSet(boxName, OBJPROP_BACK,   true);

   DrawHLine("BRK_LiveHigh", hi, clrAqua, STYLE_SOLID, 1);
   DrawHLine("BRK_LiveLow",  lo, clrAqua, STYLE_SOLID, 1);
   if (ShowMidLine)
      DrawHLine("BRK_LiveMid", (hi + lo) / 2.0, clrGray, STYLE_DOT, 1);
}

//+------------------------------------------------------------------+
//| Fade the live range when it breaks                               |
//+------------------------------------------------------------------+
void FadeRange() {
   string names[] = {"BRK_LiveBox","BRK_LiveHigh","BRK_LiveLow","BRK_LiveMid"};
   for (int i = 0; i < ArraySize(names); i++)
      if (ObjectFind(names[i]) >= 0)
         ObjectSet(names[i], OBJPROP_COLOR, BreakoutLineColor);
}

//+------------------------------------------------------------------+
//| Historical breakout box (stays on chart)                        |
//+------------------------------------------------------------------+
void DrawBreakoutBox(string id, datetime t1, datetime t2,
                     double hi, double lo, bool isBuy) {
   color boxClr  = isBuy ? C'0,40,90'  : C'90,30,0';
   color lineClr = isBuy ? clrSteelBlue : clrIndianRed;

   ObjectCreate(id, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSet(id, OBJPROP_COLOR, boxClr);
   ObjectSet(id, OBJPROP_BACK,  true);

   // Dotted level lines for this range
   string hId = id + "_H";
   string lId = id + "_L";
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
//| Dashboard                                                        |
//+------------------------------------------------------------------+
void UpdateDashboard() {
   double atr    = iATR(Symbol(), Period(), ATR_Period, 1);
   double ptSize = MarketInfo(Symbol(), MODE_POINT);
   if (ptSize <= 0) return;

   double spread   = MarketInfo(Symbol(), MODE_SPREAD);
   double rangeH   = (g_RangeHigh > 0) ? (g_RangeHigh - g_RangeLow) / ptSize : 0;
   double maxRange = (atr > 0) ? atr * ConsolidationMaxATR / ptSize : 0;
   string state    = g_RangeArmed ? "CONSOLIDATION - range armed" : "No active range";

   string tf   = "";
   switch (Period()) {
      case PERIOD_M1:  tf = "M1";  break;
      case PERIOD_M5:  tf = "M5";  break;
      case PERIOD_M15: tf = "M15"; break;
      case PERIOD_M30: tf = "M30"; break;
      case PERIOD_H1:  tf = "H1";  break;
      case PERIOD_H4:  tf = "H4";  break;
      case PERIOD_D1:  tf = "D1";  break;
      default: tf = IntegerToString(Period());
   }

   string dash = "";
   dash += "=== BreakoutIndicator ===\n";
   dash += "Symbol : " + Symbol() + "   TF: " + tf + "\n";
   dash += "Spread : " + DoubleToStr(spread, 0) + "pts\n";
   dash += "ATR    : " + DoubleToStr(atr / ptSize, 1) + "pts" +
           "   Max box: " + DoubleToStr(maxRange, 1) + "pts\n";
   if (g_RangeHigh > 0)
      dash += "Range  : " + DoubleToStr(rangeH, 1) + "pts   [" + state + "]\n" +
              "Box    : " + DoubleToStr(g_RangeLow, Digits) +
              " - " + DoubleToStr(g_RangeHigh, Digits) + "\n";
   else
      dash += "Range  : scanning...\n";
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
   g_BoxCount   = 0;
   g_RangeArmed = false;
   g_RangeHigh  = 0;
   g_RangeLow   = 0;
}
//+------------------------------------------------------------------+
