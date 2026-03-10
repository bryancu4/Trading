//+------------------------------------------------------------------+
//|                                              TradeManager.mq4    |
//|                         Recovery grid manager for open trades    |
//+------------------------------------------------------------------+
//  How it works:
//  - Monitors all open trades on the symbol (filtered by MagicFilter)
//  - Groups them into BUY basket and SELL basket
//  - If a basket is in drawdown by ATR * LayerATRMult points, adds a new
//    recovery layer (same direction, same or scaled lot size)
//  - After each new layer, recalculates the weighted average entry
//    and updates TP for ALL basket trades to: avg + TP_Points (buy)
//  - If the basket loss exceeds SL_Points from the worst entry,
//    closes the entire basket (hard stop)
//  - Max protection: never adds more than MaxLayers recovery trades
//+------------------------------------------------------------------+
#property copyright "Copyright 2024"
#property version   "1.00"
#property strict

//=== INPUTS =========================================================
input string Symbol_To_Manage = "XAUUSD";  // Symbol to manage
input int    MagicFilter       = 0;         // Magic to manage (0 = all trades on symbol)
input int    MagicTM           = 77770101;  // Magic for recovery layers added by this EA

// --- Recovery parameters ---
input int    MaxLayers        = 5;      // Max recovery layers to add (including original)
input double InitialLots      = 0.01;   // Lot size for first recovery layer
input double LotMultiplier    = 1.5;    // Multiply lots each recovery layer (1.0 = fixed)

// --- Dynamic layer distance (ATR-based) ---
input ENUM_TIMEFRAMES ATR_Timeframe   = PERIOD_M5;  // Timeframe for ATR
input int             ATR_Period      = 14;          // ATR period
input double          LayerATRMult    = 1.5;         // Layer distance = ATR * this
input double          MinLayerPoints  = 50.0;        // Minimum layer distance (points floor)
input double          MaxLayerPoints  = 500.0;       // Maximum layer distance (points cap)

// --- Dynamic TP (ATR-based) ---
input double          TP_ATRMult      = 1.0;         // TP above avg entry = ATR * this
input double          MinTPPoints     = 50.0;        // Minimum TP distance (points floor)

// --- Basket SL ---
input double          SL_ATRMult      = 5.0;         // Basket SL = ATR * this from worst entry
input double          MinSLPoints     = 200.0;       // Minimum SL distance (points floor)

// --- Options ---
input bool   ModifyExistingTP = true;   // Update TP of ALL basket trades to combined target
input bool   CloseOnSL        = true;   // Close entire basket when SL is hit
input int    Slippage         = 30;

//=== GLOBALS ========================================================
datetime g_LastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit() {
   if (Symbol() != Symbol_To_Manage)
      Print("WARNING: Chart is ", Symbol(), " but managing ", Symbol_To_Manage);
   Print("TradeManager started | MaxLayers=", MaxLayers,
         " LayerDist=", LayerATRMult, "xATR (min ", MinLayerPoints, "pts)",
         " TP=", TP_ATRMult, "xATR SL=", SL_ATRMult, "xATR");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   Print("TradeManager stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
void OnTick() {
   if (Symbol() != Symbol_To_Manage) return;

   ManageBasket(OP_BUY);
   ManageBasket(OP_SELL);
}

//+------------------------------------------------------------------+
//| Core basket management for one direction                         |
//+------------------------------------------------------------------+
void ManageBasket(int direction) {
   // --- Collect all open trades for this basket ---
   int    tickets[];
   double openPrices[];
   double lots[];
   int    count = 0;

   for (int i = 0; i < OrdersTotal(); i++) {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() != Symbol_To_Manage) continue;
      if (OrderType() != direction) continue;
      if (MagicFilter != 0 && OrderMagicNumber() != MagicFilter
          && OrderMagicNumber() != MagicTM) continue;

      ArrayResize(tickets,    count + 1);
      ArrayResize(openPrices, count + 1);
      ArrayResize(lots,       count + 1);
      tickets[count]    = OrderTicket();
      openPrices[count] = OrderOpenPrice();
      lots[count]       = OrderLots();
      count++;
   }

   if (count == 0) return;

   // --- Basket statistics ---
   double weightedSum = 0, totalLots = 0;
   double worstEntry  = openPrices[0];

   for (int i = 0; i < count; i++) {
      weightedSum += openPrices[i] * lots[i];
      totalLots   += lots[i];
      if (direction == OP_BUY  && openPrices[i] < worstEntry) worstEntry = openPrices[i];
      if (direction == OP_SELL && openPrices[i] > worstEntry) worstEntry = openPrices[i];
   }

   double avgEntry = weightedSum / totalLots;

   // Current price
   double curPrice = (direction == OP_BUY) ? Bid : Ask;

   // --- Dynamic distances from ATR ---
   double ptSize      = MarketInfo(Symbol_To_Manage, MODE_POINT);
   double atr         = GetATRPoints();
   double layerDist   = atr * LayerATRMult;
   double tpDist      = atr * TP_ATRMult;
   double slDist      = atr * SL_ATRMult;
   layerDist = MathMax(layerDist, MinLayerPoints);
   layerDist = MathMin(layerDist, MaxLayerPoints);
   tpDist    = MathMax(tpDist,    MinTPPoints);
   slDist    = MathMax(slDist,    MinSLPoints);

   // --- Calculate combined TP price ---
   double tpPrice  = (direction == OP_BUY)
                     ? avgEntry + tpDist * ptSize
                     : avgEntry - tpDist * ptSize;

   // --- Check basket SL (from worst entry) ---
   if (CloseOnSL) {
      double lossFromWorst = (direction == OP_BUY)
                             ? (worstEntry - curPrice) / ptSize
                             : (curPrice - worstEntry) / ptSize;
      if (lossFromWorst >= slDist) {
         Print("Basket SL hit (", direction == OP_BUY ? "BUY" : "SELL",
               ") loss=", DoubleToStr(lossFromWorst, 1), "pts SL=", DoubleToStr(slDist, 1),
               "pts ATR=", DoubleToStr(atr, 1), "pts — closing all");
         CloseBasket(tickets, count, direction);
         return;
      }
   }

   // --- Update TP for all basket trades ---
   if (ModifyExistingTP) {
      for (int i = 0; i < count; i++) {
         if (!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_TRADES)) continue;
         double curTP = OrderTakeProfit();
         if (MathAbs(curTP - tpPrice) > ptSize) {
            OrderModify(tickets[i], OrderOpenPrice(), OrderStopLoss(),
                        NormalizeDouble(tpPrice, Digits), 0, clrCyan);
         }
      }
   }

   // --- Check if we need a recovery layer ---
   if (count >= MaxLayers) return;   // max layers reached

   // Find the last (most recent) layer entry price
   double lastEntry = openPrices[0];
   for (int i = 1; i < count; i++) {
      if (direction == OP_BUY  && openPrices[i] < lastEntry) lastEntry = openPrices[i];
      if (direction == OP_SELL && openPrices[i] > lastEntry) lastEntry = openPrices[i];
   }

   double distFromLast = (direction == OP_BUY)
                         ? (lastEntry - curPrice) / ptSize
                         : (curPrice - lastEntry) / ptSize;

   if (distFromLast < layerDist) return;  // not deep enough for next layer

   // --- Open recovery layer ---
   double layerLots = CalculateLayerLots(count);
   if (layerLots <= 0) return;

   // New layer TP will be updated immediately on next tick, use current tpPrice
   double layerSL = 0.0;  // no individual SL — basket SL handles it
   double layerTP = NormalizeDouble(tpPrice, Digits);

   int ticket;
   if (direction == OP_BUY) {
      ticket = OrderSend(Symbol_To_Manage, OP_BUY, layerLots, Ask, Slippage,
                         layerSL, layerTP, "TM Recovery BUY L" + IntegerToString(count+1),
                         MagicTM, 0, clrDodgerBlue);
   } else {
      ticket = OrderSend(Symbol_To_Manage, OP_SELL, layerLots, Bid, Slippage,
                         layerSL, layerTP, "TM Recovery SELL L" + IntegerToString(count+1),
                         MagicTM, 0, clrOrangeRed);
   }

   if (ticket > 0) {
      Print("Recovery layer ", count + 1, " opened | ",
            direction == OP_BUY ? "BUY" : "SELL",
            " lots=", layerLots,
            " dist=", DoubleToStr(distFromLast, 1), "pts",
            " (layerDist=", DoubleToStr(layerDist, 1), "pts ATR=", DoubleToStr(atr, 1), "pts)",
            " avgEntry=", DoubleToStr(avgEntry, Digits),
            " newTP=", DoubleToStr(tpPrice, Digits));
   } else {
      Print("Recovery layer failed err=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| Close all trades in basket                                       |
//+------------------------------------------------------------------+
void CloseBasket(int &tickets[], int count, int direction) {
   for (int i = count - 1; i >= 0; i--) {
      if (!OrderSelect(tickets[i], SELECT_BY_TICKET, MODE_TRADES)) continue;
      double closePrice = (direction == OP_BUY) ? Bid : Ask;
      if (!OrderClose(tickets[i], OrderLots(), closePrice, Slippage, clrRed))
         Print("Close failed ticket=", tickets[i], " err=", GetLastError());
      else
         Print("Closed basket trade #", tickets[i]);
   }
}

//+------------------------------------------------------------------+
//| Get ATR value in points (adapts to current volatility)          |
//+------------------------------------------------------------------+
double GetATRPoints() {
   double ptSize = MarketInfo(Symbol_To_Manage, MODE_POINT);
   double atr    = iATR(Symbol_To_Manage, ATR_Timeframe, ATR_Period, 1);
   if (atr <= 0 || ptSize <= 0) return MinLayerPoints;  // fallback
   return atr / ptSize;
}

//+------------------------------------------------------------------+
//| Calculate lot size for the Nth recovery layer (0-indexed)       |
//+------------------------------------------------------------------+
double CalculateLayerLots(int layerIndex) {
   double minLot  = MarketInfo(Symbol_To_Manage, MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol_To_Manage, MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol_To_Manage, MODE_LOTSTEP);

   double lots = InitialLots;
   for (int i = 0; i < layerIndex; i++)
      lots *= LotMultiplier;

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+
