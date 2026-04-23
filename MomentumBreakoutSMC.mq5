//+------------------------------------------------------------------+
//|  Momentum Breakout + SMC Filter EA                               |
//|  Author : Angel Garcia                                           |
//|  Version: 1.0                                                    |
//|  Description: Automated trading system combining EMA trend       |
//|  filter, RSI confirmation, breakout detection and Smart Money    |
//|  Concepts (BOS, Order Blocks, FVGs) with full risk management.  |
//+------------------------------------------------------------------+
#property copyright "Angel Garcia"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== RISK MANAGEMENT ==="
input double RiskPercent      = 1.0;    // Risk % per trade
input double MaxDailyLossPct  = 5.0;    // Max daily loss %
input int    MaxDailyTrades   = 5;      // Max trades per day
input double BreakEvenR       = 1.5;    // Move SL to BE at X*R
input double TrailStartR      = 2.0;    // Start trailing at X*R

input group "=== EMA SETTINGS ==="
input int    EMA_Fast         = 21;     // Fast EMA period
input int    EMA_Slow         = 50;     // Slow EMA period
input ENUM_TIMEFRAMES EMA_TF  = PERIOD_H1; // EMA timeframe

input group "=== RSI SETTINGS ==="
input int    RSI_Period       = 14;     // RSI period
input double RSI_OB           = 70.0;   // Overbought level
input double RSI_OS           = 30.0;   // Oversold level

input group "=== SMC SETTINGS ==="
input int    BOS_Lookback     = 20;     // Bars to look back for BOS
input int    OB_Lookback      = 10;     // Order Block lookback
input int    FVG_Lookback     = 5;      // FVG lookback bars

input group "=== DASHBOARD ==="
input string DataFilePath     = "ea_data.js"; // JS output file name

//--- Global Variables
int    handleEMAFast, handleEMASlow, handleRSI;
double emaFast[], emaSlow[], rsiVal[];
int    dailyTrades    = 0;
double dailyStartEquity = 0;
datetime lastTradeDay  = 0;
double openSL          = 0;
double openTP          = 0;
double openLots        = 0;
ulong  openTicket      = 0;

//+------------------------------------------------------------------+
//| Initialisation                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   handleEMAFast = iMA(_Symbol, EMA_TF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(_Symbol, EMA_TF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, EMA_TF, RSI_Period, PRICE_CLOSE);

   if(handleEMAFast == INVALID_HANDLE || handleEMASlow == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
     {
      Print("Error initialising indicators. EA stopped.");
      return(INIT_FAILED);
     }

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsiVal,  true);

   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("Momentum Breakout + SMC EA initialised on ", _Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Deinitialisation                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleEMAFast);
   IndicatorRelease(handleEMASlow);
   IndicatorRelease(handleRSI);
  }

//+------------------------------------------------------------------+
//| Main tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Reset daily counters on new day
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", now.year, now.mon, now.day));
   if(today != lastTradeDay)
     {
      dailyTrades      = 0;
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      lastTradeDay     = today;
     }

   // Copy indicator buffers
   if(CopyBuffer(handleEMAFast, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   if(CopyBuffer(handleRSI,     0, 0, 3, rsiVal)  < 3) return;

   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss = (dailyStartEquity - equity) / dailyStartEquity * 100.0;

   // --- Daily loss limit ---
   if(dailyLoss >= MaxDailyLossPct)
     {
      CloseAllPositions("Daily loss limit reached");
      WriteJSON(equity, balance, dailyLoss, "STOPPED - Daily loss limit");
      return;
     }

   // --- Manage open trade (BE + Trail) ---
   ManageOpenTrade();

   // --- New entry logic ---
   if(PositionsTotal() == 0 && dailyTrades < MaxDailyTrades)
     {
      int signal = GetEntrySignal();
      if(signal == 1)  ExecuteTrade(ORDER_TYPE_BUY);
      if(signal == -1) ExecuteTrade(ORDER_TYPE_SELL);
     }

   // --- Write dashboard JSON ---
   WriteJSON(equity, balance, dailyLoss, PositionsTotal() > 0 ? "ACTIVE" : "WAITING");
  }

//+------------------------------------------------------------------+
//| 3-Layer Signal Engine                                             |
//+------------------------------------------------------------------+
int GetEntrySignal()
  {
   // Layer 1: EMA Trend
   bool bullTrend = emaFast[0] > emaSlow[0];
   bool bearTrend = emaFast[0] < emaSlow[0];

   // Layer 2: RSI filter
   bool rsiBull = rsiVal[0] > 50 && rsiVal[0] < RSI_OB;
   bool rsiBear = rsiVal[0] < 50 && rsiVal[0] > RSI_OS;

   // Layer 3: SMC — Break of Structure
   bool bosBull = DetectBOS(true);
   bool bosBear = DetectBOS(false);

   if(bullTrend && rsiBull && bosBull) return 1;
   if(bearTrend && rsiBear && bosBear) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| Break of Structure Detection                                      |
//+------------------------------------------------------------------+
bool DetectBOS(bool bullish)
  {
   double prices[];
   ArraySetAsSeries(prices, true);
   if(bullish)
     {
      // Bullish BOS: current high breaks above recent swing high
      if(CopyHigh(_Symbol, EMA_TF, 0, BOS_Lookback, prices) < BOS_Lookback) return false;
      double swingHigh = prices[1];
      for(int i = 2; i < BOS_Lookback - 1; i++)
         swingHigh = MathMax(swingHigh, prices[i]);
      return prices[0] > swingHigh;
     }
   else
     {
      // Bearish BOS: current low breaks below recent swing low
      if(CopyLow(_Symbol, EMA_TF, 0, BOS_Lookback, prices) < BOS_Lookback) return false;
      double swingLow = prices[1];
      for(int i = 2; i < BOS_Lookback - 1; i++)
         swingLow = MathMin(swingLow, prices[i]);
      return prices[0] < swingLow;
     }
  }

//+------------------------------------------------------------------+
//| Order Block Zone (nearest OB level)                              |
//+------------------------------------------------------------------+
double GetOrderBlock(bool bullish)
  {
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyHigh(_Symbol, EMA_TF, 0, OB_Lookback, hi) < OB_Lookback) return 0;
   if(CopyLow (_Symbol, EMA_TF, 0, OB_Lookback, lo) < OB_Lookback) return 0;
   // Return the body midpoint of the most recent OB candle
   return bullish ? lo[OB_Lookback - 1] : hi[OB_Lookback - 1];
  }

//+------------------------------------------------------------------+
//| Lot size calculator (% risk)                                     |
//+------------------------------------------------------------------+
double CalcLots(double slPoints)
  {
   if(slPoints <= 0) return 0;
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * RiskPercent / 100.0;
   double tickVal    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lotStep    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickVal == 0 || tickSize == 0) return minLot;
   double valuePerLot = (slPoints / tickSize) * tickVal;
   if(valuePerLot == 0) return minLot;

   double lots = riskAmount / valuePerLot;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
  }

//+------------------------------------------------------------------+
//| Execute trade                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
  {
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atr   = GetATR();
   if(atr <= 0) return;

   double sl, tp, price;
   if(type == ORDER_TYPE_BUY)
     {
      price = ask;
      sl    = price - atr * 1.5;
      tp    = price + atr * 3.0;
     }
   else
     {
      price = bid;
      sl    = price + atr * 1.5;
      tp    = price - atr * 3.0;
     }

   double slPoints = MathAbs(price - sl);
   double lots     = CalcLots(slPoints);
   if(lots <= 0) return;

   trade.SetExpertMagicNumber(202601);
   bool result = (type == ORDER_TYPE_BUY)
                 ? trade.Buy(lots, _Symbol, price, sl, tp, "SMC-BOS-Entry")
                 : trade.Sell(lots, _Symbol, price, sl, tp, "SMC-BOS-Entry");

   if(result)
     {
      dailyTrades++;
      openSL     = sl;
      openTP     = tp;
      openLots   = lots;
      openTicket = trade.ResultOrder();
      PrintFormat("Trade opened: %s | Lots: %.2f | SL: %.5f | TP: %.5f", 
                  type == ORDER_TYPE_BUY ? "BUY" : "SELL", lots, sl, tp);
     }
   else
      PrintFormat("Trade failed. Error: %d", GetLastError());
  }

//+------------------------------------------------------------------+
//| ATR-based volatility measure                                     |
//+------------------------------------------------------------------+
double GetATR()
  {
   int h = iATR(_Symbol, EMA_TF, 14);
   if(h == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h, 0, 0, 1, buf) < 1) return 0;
   IndicatorRelease(h);
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Break-Even + Trailing Stop Manager                               |
//+------------------------------------------------------------------+
void ManageOpenTrade()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 202601) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double priceCur  = PositionGetDouble(POSITION_PRICE_CURRENT);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double slDist    = MathAbs(openPrice - currentSL);
      if(slDist == 0) continue;

      double profitR = posType == POSITION_TYPE_BUY
                       ? (priceCur - openPrice) / slDist
                       : (openPrice - priceCur) / slDist;

      double newSL = currentSL;

      // Break-Even
      if(profitR >= BreakEvenR && MathAbs(currentSL - openPrice) > SymbolInfoDouble(_Symbol, SYMBOL_POINT))
        {
         newSL = posType == POSITION_TYPE_BUY ? openPrice : openPrice;
        }

      // Trailing Stop
      if(profitR >= TrailStartR)
        {
         double trail = slDist * 0.5;
         newSL = posType == POSITION_TYPE_BUY
                 ? MathMax(newSL, priceCur - trail)
                 : MathMin(newSL, priceCur + trail);
        }

      if(MathAbs(newSL - currentSL) > SymbolInfoDouble(_Symbol, SYMBOL_POINT))
         trade.PositionModify(ticket, newSL, currentTP);
     }
  }

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC) == 202601)
           {
            trade.PositionClose(ticket);
            Print("Position closed. Reason: ", reason);
           }
     }
  }

//+------------------------------------------------------------------+
//| Write complete HTML dashboard with embedded data                 |
//+------------------------------------------------------------------+
void WriteJSON(double equity, double balance, double dailyLoss, string status)
  {
   double openPnL    = 0;
   string posDir     = "NONE";
   double posLots    = 0;
   double posOpen    = 0;
   double posSL      = 0;
   double posTP      = 0;

   if(PositionsTotal() > 0)
     {
      ulong ticket = PositionGetTicket(0);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == 202601)
        {
         openPnL = PositionGetDouble(POSITION_PROFIT);
         posDir  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL";
         posLots = PositionGetDouble(POSITION_VOLUME);
         posOpen = PositionGetDouble(POSITION_PRICE_OPEN);
         posSL   = PositionGetDouble(POSITION_SL);
         posTP   = PositionGetDouble(POSITION_TP);
        }
     }

   string pnlColor  = openPnL >= 0 ? "#3fb950" : "#f85149";
   string pnlSign   = openPnL >= 0 ? "+" : "";
   string statusColor = "";
   if(StringFind(status,"STOPPED") >= 0)      statusColor = "#f85149";
   else if(StringFind(status,"WAITING") >= 0) statusColor = "#d29922";
   else                                        statusColor = "#3fb950";

   string dirColor = "";
   string dirBg    = "";
   if(posDir == "BUY")       { dirColor="#3fb950"; dirBg="rgba(63,185,80,.15)"; }
   else if(posDir == "SELL") { dirColor="#f85149"; dirBg="rgba(248,81,73,.15)"; }
   else                      { dirColor="#8b949e"; dirBg="rgba(139,148,158,.1)";}

   double lossRatio   = MathMin(dailyLoss / MaxDailyLossPct * 100.0, 100.0);
   double tradesRatio = MaxDailyTrades > 0 ? MathMin((double)dailyTrades / MaxDailyTrades * 100.0, 100.0) : 0;
   string lossBarColor = lossRatio < 50 ? "#3fb950" : lossRatio < 80 ? "#d29922" : "#f85149";

   string posOpenStr = posDir != "NONE" ? StringFormat("%.5f", posOpen) : "—";
   string posSLStr   = posDir != "NONE" ? StringFormat("%.5f", posSL)   : "—";
   string posTPStr   = posDir != "NONE" ? StringFormat("%.5f", posTP)   : "—";
   string posLotsStr = posDir != "NONE" ? StringFormat("%.2f", posLots)  : "—";

   string html = StringFormat(
"<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'/>"
"<meta http-equiv='refresh' content='5'/>"
"<title>SMC EA Dashboard</title>"
"<style>"
"*{box-sizing:border-box;margin:0;padding:0}"
"body{background:#0d1117;color:#e6edf3;font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;padding:24px}"
"header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #30363d}"
"header h1{font-size:20px;font-weight:600}"
"header h1 span{color:#1f6feb}"
".badge{background:#1f6feb;color:#fff;padding:4px 12px;border-radius:20px;font-weight:600;font-size:13px}"
".status{display:flex;align-items:center;gap:8px;font-size:13px;color:#8b949e}"
".dot{width:8px;height:8px;border-radius:50%}"
".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px;margin-bottom:24px}"
".card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px}"
".lbl{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:#8b949e;margin-bottom:8px}"
".val{font-size:26px;font-weight:700}"
".sub{font-size:12px;color:#8b949e;margin-top:4px}"
".sec{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:#8b949e;margin-bottom:12px}"
".panel{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px;margin-bottom:24px}"
".ph{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}"
".dbadge{padding:4px 14px;border-radius:20px;font-weight:700;font-size:13px}"
".pgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:16px}"
".pi .l{font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px}"
".pi .v{font-size:16px;font-weight:600}"
".pw{margin-bottom:24px}"
".pl{display:flex;justify-content:space-between;font-size:12px;color:#8b949e;margin-bottom:6px}"
".pb{height:6px;background:#30363d;border-radius:3px;overflow:hidden;margin-bottom:10px}"
".pf{height:100%%;border-radius:3px}"
"footer{text-align:center;font-size:11px;color:#8b949e;margin-top:24px;padding-top:16px;border-top:1px solid #30363d}"
"</style></head><body>"
"<header>"
"<h1>SMC EA <span>Dashboard</span></h1>"
"<div style='display:flex;align-items:center;gap:12px'>"
"<span class='badge'>%s</span>"
"<div class='status'><div class='dot' style='background:%s'></div><span>%s</span></div>"
"</div></header>"
"<div class='grid'>"
"<div class='card'><div class='lbl'>Equity</div><div class='val'>$%.2f</div><div class='sub'>Balance: $%.2f</div></div>"
"<div class='card'><div class='lbl'>Open P&amp;L</div><div class='val' style='color:%s'>%s$%.2f</div></div>"
"<div class='card'><div class='lbl'>Daily Trades</div><div class='val'>%d / %d</div><div class='sub'>%d remaining</div></div>"
"<div class='card'><div class='lbl'>Daily Loss</div><div class='val' style='color:%s'>%.2f%%</div><div class='sub'>Limit: %.1f%%</div></div>"
"</div>"
"<div class='pw'>"
"<p class='sec'>Daily Limits</p>"
"<div class='pl'><span>Daily Loss</span><span>%.2f%% / %.1f%%</span></div>"
"<div class='pb'><div class='pf' style='width:%.1f%%;background:%s'></div></div>"
"<div class='pl'><span>Trades Used</span><span>%d / %d</span></div>"
"<div class='pb'><div class='pf' style='width:%.1f%%;background:#3fb950'></div></div>"
"</div>"
"<div class='panel'>"
"<div class='ph'><p class='sec' style='margin:0'>Open Position</p>"
"<span class='dbadge' style='color:%s;background:%s;border:1px solid %s'>%s</span></div>"
"<div class='pgrid'>"
"<div class='pi'><div class='l'>Open Price</div><div class='v'>%s</div></div>"
"<div class='pi'><div class='l'>Stop Loss</div><div class='v' style='color:#f85149'>%s</div></div>"
"<div class='pi'><div class='l'>Take Profit</div><div class='v' style='color:#3fb950'>%s</div></div>"
"<div class='pi'><div class='l'>Lots</div><div class='v'>%s</div></div>"
"</div></div>"
"<div class='card'>"
"<p class='sec' style='margin-bottom:12px'>EA Settings</p>"
"<div class='pgrid'>"
"<div class='pi'><div class='l'>Risk per Trade</div><div class='v'>%.1f%%</div></div>"
"<div class='pi'><div class='l'>Max Daily Loss</div><div class='v'>%.1f%%</div></div>"
"<div class='pi'><div class='l'>Last Update</div><div class='v' style='font-size:13px'>%s</div></div>"
"</div></div>"
"<footer>Momentum Breakout + SMC Filter EA &nbsp;|&nbsp; Angel Garcia &nbsp;|&nbsp; Auto-refreshes every 5s</footer>"
"</body></html>",
      // header
      _Symbol, statusColor, status,
      // cards
      equity, balance,
      pnlColor, pnlSign, MathAbs(openPnL),
      dailyTrades, MaxDailyTrades, MaxDailyTrades - dailyTrades,
      lossBarColor, dailyLoss, MaxDailyLossPct,
      // progress bars
      dailyLoss, MaxDailyLossPct, lossRatio, lossBarColor,
      dailyTrades, MaxDailyTrades, tradesRatio,
      // position
      dirColor, dirBg, dirColor, posDir,
      posOpenStr, posSLStr, posTPStr, posLotsStr,
      // settings
      RiskPercent, MaxDailyLossPct,
      TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)
   );

   int fh = FileOpen("dashboard_live.html", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh != INVALID_HANDLE)
     {
      FileWriteString(fh, html);
      FileClose(fh);
     }
  }
//+------------------------------------------------------------------+
