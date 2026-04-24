//+------------------------------------------------------------------+
//|  Momentum Breakout + SMC Filter EA  v2.0                         |
//|  Author : Angel Garcia                                           |
//|  Description: EMA trend + RSI confirmation + BOS detection       |
//|  with dynamic risk management and self-contained HTML dashboard. |
//|  v2.0 — Robust signal logic, confirmed backtesting compatible.   |
//+------------------------------------------------------------------+
#property copyright "Angel Garcia"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== RISK MANAGEMENT ==="
input double RiskPercent     = 1.0;   // Risk % per trade
input double MaxDailyLossPct = 5.0;   // Max daily loss %
input int    MaxDailyTrades  = 5;     // Max trades per day
input double BreakEvenR      = 1.5;   // Move SL to BE at X*R profit
input double TrailStartR     = 2.0;   // Start trailing at X*R profit

input group "=== EMA SETTINGS ==="
input int    EMA_Fast        = 21;    // Fast EMA period
input int    EMA_Slow        = 50;    // Slow EMA period
input ENUM_TIMEFRAMES EMA_TF = PERIOD_H1; // Indicator timeframe

input group "=== RSI SETTINGS ==="
input int    RSI_Period      = 14;    // RSI period
input double RSI_Bull_Min    = 45.0;  // RSI minimum for bull entry
input double RSI_Bull_Max    = 70.0;  // RSI maximum for bull entry
input double RSI_Bear_Min    = 30.0;  // RSI minimum for bear entry
input double RSI_Bear_Max    = 55.0;  // RSI maximum for bear entry

input group "=== BOS SETTINGS ==="
input int    BOS_Lookback    = 15;    // Bars for swing detection
input int    BOS_Strength    = 3;     // Bars each side to confirm swing

input group "=== ATR SETTINGS ==="
input int    ATR_Period      = 14;    // ATR period for SL/TP
input double ATR_SL_Multi    = 1.5;   // ATR multiplier for Stop Loss
input double ATR_TP_Multi    = 2.5;   // ATR multiplier for Take Profit

input group "=== TRADE FILTER ==="
input bool   RequireBOS      = true;  // Require Break of Structure
input bool   OnlyNewBar      = true;  // Only check signals on new bar

//--- Global Variables
int    handleEMAFast, handleEMASlow, handleRSI, handleATR;
double emaFast[], emaSlow[], rsiVal[], atrVal[];

int      dailyTrades      = 0;
double   dailyStartEquity = 0;
datetime lastTradeDay     = 0;
datetime lastBarTime      = 0;

int      totalWins        = 0;
int      totalLosses      = 0;
double   totalProfit      = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   handleEMAFast = iMA(_Symbol, EMA_TF, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow = iMA(_Symbol, EMA_TF, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, EMA_TF, RSI_Period, PRICE_CLOSE);
   handleATR     = iATR(_Symbol, EMA_TF, ATR_Period);

   if(handleEMAFast==INVALID_HANDLE || handleEMASlow==INVALID_HANDLE ||
      handleRSI==INVALID_HANDLE     || handleATR==INVALID_HANDLE)
     {
      Print("ERROR: Failed to initialise indicators.");
      return INIT_FAILED;
     }

   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsiVal,  true);
   ArraySetAsSeries(atrVal,  true);

   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("SMC EA v2.0 initialised on ", _Symbol);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinit                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleEMAFast);
   IndicatorRelease(handleEMASlow);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
  }

//+------------------------------------------------------------------+
//| Main tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- Reset daily counters ---
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d",now.year,now.mon,now.day));
   if(today != lastTradeDay)
     {
      dailyTrades      = 0;
      dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      lastTradeDay     = today;
     }

   // --- New bar check ---
   if(OnlyNewBar)
     {
      datetime currentBar = iTime(_Symbol, EMA_TF, 0);
      if(currentBar == lastBarTime) 
        {
         ManageOpenTrade();
         WriteDashboard();
         return;
        }
      lastBarTime = currentBar;
     }

   // --- Copy indicators ---
   if(CopyBuffer(handleEMAFast,0,0,BOS_Lookback+5,emaFast) < BOS_Lookback+5) return;
   if(CopyBuffer(handleEMASlow,0,0,BOS_Lookback+5,emaSlow) < BOS_Lookback+5) return;
   if(CopyBuffer(handleRSI,    0,0,3,rsiVal)                < 3)              return;
   if(CopyBuffer(handleATR,    0,0,3,atrVal)                < 3)              return;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss = dailyStartEquity > 0
                      ? (dailyStartEquity - equity) / dailyStartEquity * 100.0
                      : 0;

   // --- Daily loss limit ---
   if(dailyLoss >= MaxDailyLossPct)
     {
      CloseAllPositions("Daily loss limit");
      WriteDashboard();
      return;
     }

   // --- Manage existing trade ---
   ManageOpenTrade();

   // --- Entry logic ---
   if(PositionsTotal() == 0 && dailyTrades < MaxDailyTrades)
     {
      int signal = GetSignal();
      if(signal ==  1) OpenTrade(ORDER_TYPE_BUY);
      if(signal == -1) OpenTrade(ORDER_TYPE_SELL);
     }

   WriteDashboard();
  }

//+------------------------------------------------------------------+
//| Signal Engine — 2 required layers (BOS optional)                 |
//+------------------------------------------------------------------+
int GetSignal()
  {
   // Layer 1: EMA trend
   bool bullTrend = emaFast[1] > emaSlow[1];
   bool bearTrend = emaFast[1] < emaSlow[1];

   // EMA momentum confirmation (fast crossing above slow recently)
   bool emaBullMom = emaFast[1] > emaSlow[1] && emaFast[2] > emaSlow[2];
   bool emaBearMom = emaFast[1] < emaSlow[1] && emaFast[2] < emaSlow[2];

   // Layer 2: RSI in valid zone
   double rsi = rsiVal[1];
   bool rsiBull = rsi >= RSI_Bull_Min && rsi <= RSI_Bull_Max;
   bool rsiBear = rsi >= RSI_Bear_Min && rsi <= RSI_Bear_Max;

   // Layer 3: BOS (optional)
   bool bosBull = RequireBOS ? DetectBOS(true)  : true;
   bool bosBear = RequireBOS ? DetectBOS(false) : true;

   // Debug log
   PrintFormat("EMA fast=%.5f slow=%.5f | RSI=%.1f | BOSbull=%s BOSbear=%s",
               emaFast[1], emaSlow[1], rsi,
               bosBull?"Y":"N", bosBear?"Y":"N");

   if(bullTrend && emaBullMom && rsiBull && bosBull) return  1;
   if(bearTrend && emaBearMom && rsiBear && bosBear) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
//| BOS Detection — finds swing high/low break                       |
//+------------------------------------------------------------------+
bool DetectBOS(bool bullish)
  {
   int strength = BOS_Strength;
   int lookback = BOS_Lookback;

   // Find the most recent valid swing point
   double swingLevel = 0;
   bool   found      = false;

   if(bullish)
     {
      // Look for a swing high that was recently broken upward
      double highs[];
      ArraySetAsSeries(highs, true);
      if(CopyHigh(_Symbol, EMA_TF, 0, lookback + strength, highs) < lookback)
         return false;

      // Find highest swing high in lookback (excluding last 'strength' bars)
      for(int i = strength; i < lookback; i++)
        {
         bool isSwing = true;
         for(int j = 1; j <= strength; j++)
            if(highs[i] < highs[i-j] || highs[i] < highs[i+j])
              { isSwing = false; break; }
         if(isSwing)
           { swingLevel = highs[i]; found = true; break; }
        }

      if(!found) return false;
      // Current bar closed above that swing high
      double closes[];
      ArraySetAsSeries(closes, true);
      if(CopyClose(_Symbol, EMA_TF, 0, 3, closes) < 2) return false;
      return closes[1] > swingLevel;
     }
   else
     {
      // Look for a swing low that was recently broken downward
      double lows[];
      ArraySetAsSeries(lows, true);
      if(CopyLow(_Symbol, EMA_TF, 0, lookback + strength, lows) < lookback)
         return false;

      for(int i = strength; i < lookback; i++)
        {
         bool isSwing = true;
         for(int j = 1; j <= strength; j++)
            if(lows[i] > lows[i-j] || lows[i] > lows[i+j])
              { isSwing = false; break; }
         if(isSwing)
           { swingLevel = lows[i]; found = true; break; }
        }

      if(!found) return false;
      double closes[];
      ArraySetAsSeries(closes, true);
      if(CopyClose(_Symbol, EMA_TF, 0, 3, closes) < 2) return false;
      return closes[1] < swingLevel;
     }
  }

//+------------------------------------------------------------------+
//| Lot calculator                                                   |
//+------------------------------------------------------------------+
double CalcLots(double slPoints)
  {
   if(slPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = balance * RiskPercent / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickVal==0 || tickSize==0) return minLot;
   double valPerLot = (slPoints / tickSize) * tickVal;
   if(valPerLot==0) return minLot;

   double lots = MathFloor((riskAmt / valPerLot) / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lots));
  }

//+------------------------------------------------------------------+
//| Open trade                                                       |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
  {
   double atr   = atrVal[1];
   if(atr <= 0) { Print("ATR=0, skipping trade"); return; }

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double price, sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      price = ask;
      sl    = NormalizeDouble(price - atr * ATR_SL_Multi, _Digits);
      tp    = NormalizeDouble(price + atr * ATR_TP_Multi, _Digits);
     }
   else
     {
      price = bid;
      sl    = NormalizeDouble(price + atr * ATR_SL_Multi, _Digits);
      tp    = NormalizeDouble(price - atr * ATR_TP_Multi, _Digits);
     }

   double slDist = MathAbs(price - sl);
   double lots   = CalcLots(slDist);

   trade.SetExpertMagicNumber(202602);
   trade.SetDeviationInPoints(30);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, price, sl, tp, "SMC-v2")
             : trade.Sell(lots, _Symbol, price, sl, tp, "SMC-v2");

   if(ok)
     {
      dailyTrades++;
      PrintFormat("[TRADE] %s | Lots:%.2f | Price:%.5f | SL:%.5f | TP:%.5f | ATR:%.5f",
                  type==ORDER_TYPE_BUY?"BUY":"SELL", lots, price, sl, tp, atr);
     }
   else
      PrintFormat("[ERROR] Trade failed: %d - %s", GetLastError(), trade.ResultComment());
  }

//+------------------------------------------------------------------+
//| Manage open trade — Break Even + Trail                           |
//+------------------------------------------------------------------+
void ManageOpenTrade()
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != 202602) continue;

      double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);
      double curPx   = PositionGetDouble(POSITION_PRICE_CURRENT);
      double slDist  = MathAbs(openPx - curSL);
      if(slDist == 0) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double profitR = ptype==POSITION_TYPE_BUY
                       ? (curPx - openPx) / slDist
                       : (openPx - curPx) / slDist;

      double newSL   = curSL;
      double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      // Break-even
      if(profitR >= BreakEvenR)
        {
         double beSL = ptype==POSITION_TYPE_BUY
                       ? openPx + point
                       : openPx - point;
         if(ptype==POSITION_TYPE_BUY  && beSL > curSL) newSL = beSL;
         if(ptype==POSITION_TYPE_SELL && beSL < curSL) newSL = beSL;
        }

      // Trailing
      if(profitR >= TrailStartR)
        {
         double trail = slDist * 0.5;
         double trSL  = ptype==POSITION_TYPE_BUY
                        ? curPx - trail
                        : curPx + trail;
         if(ptype==POSITION_TYPE_BUY  && trSL > newSL) newSL = trSL;
         if(ptype==POSITION_TYPE_SELL && trSL < newSL) newSL = trSL;
        }

      if(MathAbs(newSL - curSL) > point)
         trade.PositionModify(ticket, NormalizeDouble(newSL,_Digits), curTP);
     }
  }

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
  {
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
         if(PositionGetInteger(POSITION_MAGIC)==202602)
           { trade.PositionClose(ticket); Print("Closed: ",reason); }
     }
  }

//+------------------------------------------------------------------+
//| Trade transaction — track wins/losses                            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
        {
         long   magic  = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
         double profit = HistoryDealGetDouble(dealTicket,  DEAL_PROFIT);
         long   entry  = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(magic==202602 && entry==DEAL_ENTRY_OUT)
           {
            totalProfit += profit;
            if(profit >= 0) totalWins++;
            else            totalLosses++;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Write self-contained HTML dashboard                              |
//+------------------------------------------------------------------+
void WriteDashboard()
  {
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLoss = dailyStartEquity > 0
                      ? (dailyStartEquity - equity) / dailyStartEquity * 100.0
                      : 0;

   double openPnL  = 0;
   string posDir   = "NONE";
   double posLots  = 0, posOpen = 0, posSL = 0, posTP = 0;
   string posSymbol = _Symbol;

   if(PositionsTotal() > 0)
     {
      ulong ticket = PositionGetTicket(0);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC)==202602)
        {
         openPnL  = PositionGetDouble(POSITION_PROFIT);
         posDir   = PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? "BUY" : "SELL";
         posLots  = PositionGetDouble(POSITION_VOLUME);
         posOpen  = PositionGetDouble(POSITION_PRICE_OPEN);
         posSL    = PositionGetDouble(POSITION_SL);
         posTP    = PositionGetDouble(POSITION_TP);
        }
     }

   int    total    = totalWins + totalLosses;
   double winRate  = total > 0 ? (double)totalWins / total * 100.0 : 0;

   // Determine EA status
   string status = "WAITING";
   if(PositionsTotal() > 0)              status = "ACTIVE";
   if(dailyTrades >= MaxDailyTrades)     status = "LIMIT REACHED";
   if(dailyLoss   >= MaxDailyLossPct)    status = "STOPPED";

   // Colors
   string statusColor = "#3fb950";
   if(status=="STOPPED" || status=="LIMIT REACHED") statusColor = "#f85149";
   else if(status=="WAITING")                        statusColor = "#d29922";

   string pnlColor  = openPnL >= 0 ? "#3fb950" : "#f85149";
   string pnlSign   = openPnL >= 0 ? "+" : "";
   string lossColor = dailyLoss < MaxDailyLossPct*0.5 ? "#3fb950"
                    : dailyLoss < MaxDailyLossPct*0.8 ? "#d29922" : "#f85149";

   double lossRatio   = MathMin(dailyLoss / MathMax(MaxDailyLossPct,0.01) * 100.0, 100.0);
   double tradesRatio = MaxDailyTrades > 0
                        ? MathMin((double)dailyTrades / MaxDailyTrades * 100.0, 100.0) : 0;

   string dirColor = "#8b949e", dirBg = "rgba(139,148,158,.1)";
   if(posDir=="BUY")  { dirColor="#3fb950"; dirBg="rgba(63,185,80,.15)"; }
   if(posDir=="SELL") { dirColor="#f85149"; dirBg="rgba(248,81,73,.15)"; }

   string rsiStr = rsiVal[1] > 0 ? StringFormat("%.1f", rsiVal[1]) : "—";
   string trendStr = emaFast[1] > emaSlow[1] ? "BULLISH" : emaFast[1] < emaSlow[1] ? "BEARISH" : "NEUTRAL";
   string trendColor = emaFast[1] > emaSlow[1] ? "#3fb950" : emaFast[1] < emaSlow[1] ? "#f85149" : "#d29922";

   string posOpenStr = posDir!="NONE" ? StringFormat("%.5f", posOpen) : "—";
   string posSLStr   = posDir!="NONE" ? StringFormat("%.5f", posSL)   : "—";
   string posTPStr   = posDir!="NONE" ? StringFormat("%.5f", posTP)   : "—";
   string posLotsStr = posDir!="NONE" ? StringFormat("%.2f", posLots)  : "—";

   string html = StringFormat(
"<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'/>"
"<meta http-equiv='refresh' content='5'/>"
"<title>SMC EA v2 — %s</title>"
"<style>"
"*{box-sizing:border-box;margin:0;padding:0}"
"body{background:#0d1117;color:#e6edf3;font-family:'Segoe UI',system-ui,sans-serif;font-size:14px;padding:24px}"
"header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid #30363d}"
"h1{font-size:20px;font-weight:600}h1 span{color:#1f6feb}"
".badge{background:#1f6feb;color:#fff;padding:4px 14px;border-radius:20px;font-weight:700;font-size:13px}"
".status{display:flex;align-items:center;gap:8px;font-size:13px;color:#8b949e}"
".dot{width:9px;height:9px;border-radius:50%}"
".grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:20px}"
".card{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:18px}"
".lbl{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:#8b949e;margin-bottom:8px}"
".val{font-size:24px;font-weight:700}.sub{font-size:12px;color:#8b949e;margin-top:4px}"
".sec{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:#8b949e;margin-bottom:10px}"
".panel{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:18px;margin-bottom:18px}"
".ph{display:flex;justify-content:space-between;align-items:center;margin-bottom:14px}"
".dbadge{padding:4px 14px;border-radius:20px;font-weight:700;font-size:13px}"
".pgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));gap:14px}"
".pi .l{font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:.05em;margin-bottom:4px}"
".pi .v{font-size:15px;font-weight:600}"
".pw{margin-bottom:18px}"
".pl{display:flex;justify-content:space-between;font-size:12px;color:#8b949e;margin-bottom:5px}"
".pb{height:5px;background:#21262d;border-radius:3px;overflow:hidden;margin-bottom:10px}"
".pf{height:100%%;border-radius:3px;transition:width .3s}"
"footer{text-align:center;font-size:11px;color:#8b949e;margin-top:20px;padding-top:14px;border-top:1px solid #30363d}"
"</style></head><body>"
// Header
"<header>"
"<h1>SMC EA <span>v2.0</span></h1>"
"<div style='display:flex;align-items:center;gap:12px'>"
"<span class='badge'>%s</span>"
"<div class='status'>"
"<div class='dot' style='background:%s'></div>"
"<span style='color:%s;font-weight:600'>%s</span>"
"</div></div></header>"
// KPI grid
"<div class='grid'>"
"<div class='card'><div class='lbl'>Equity</div><div class='val'>$%.2f</div><div class='sub'>Balance: $%.2f</div></div>"
"<div class='card'><div class='lbl'>Open P&amp;L</div><div class='val' style='color:%s'>%s$%.2f</div></div>"
"<div class='card'><div class='lbl'>Daily Trades</div><div class='val'>%d / %d</div><div class='sub'>%d remaining</div></div>"
"<div class='card'><div class='lbl'>Win Rate</div><div class='val'>%.0f%%</div><div class='sub'>%dW / %dL — P&amp;L $%.2f</div></div>"
"</div>"
// Market context
"<div class='grid' style='margin-bottom:18px'>"
"<div class='card'><div class='lbl'>Trend (EMA)</div><div class='val' style='font-size:18px;color:%s'>%s</div></div>"
"<div class='card'><div class='lbl'>RSI</div><div class='val' style='font-size:18px'>%s</div></div>"
"<div class='card'><div class='lbl'>Daily Loss</div><div class='val' style='font-size:18px;color:%s'>%.2f%%</div><div class='sub'>Limit %.1f%%</div></div>"
"</div>"
// Progress bars
"<div class='pw'>"
"<p class='sec'>Daily Limits</p>"
"<div class='pl'><span>Daily Loss</span><span>%.2f%% / %.1f%%</span></div>"
"<div class='pb'><div class='pf' style='width:%.1f%%;background:%s'></div></div>"
"<div class='pl'><span>Trades Used</span><span>%d / %d</span></div>"
"<div class='pb'><div class='pf' style='width:%.1f%%;background:#1f6feb'></div></div>"
"</div>"
// Open position
"<div class='panel'>"
"<div class='ph'><p class='sec' style='margin:0'>Open Position</p>"
"<span class='dbadge' style='color:%s;background:%s;border:1px solid %s'>%s</span></div>"
"<div class='pgrid'>"
"<div class='pi'><div class='l'>Open Price</div><div class='v'>%s</div></div>"
"<div class='pi'><div class='l'>Stop Loss</div><div class='v' style='color:#f85149'>%s</div></div>"
"<div class='pi'><div class='l'>Take Profit</div><div class='v' style='color:#3fb950'>%s</div></div>"
"<div class='pi'><div class='l'>Lots</div><div class='v'>%s</div></div>"
"</div></div>"
// Settings
"<div class='panel'>"
"<p class='sec' style='margin-bottom:12px'>EA Settings</p>"
"<div class='pgrid'>"
"<div class='pi'><div class='l'>Risk / Trade</div><div class='v'>%.1f%%</div></div>"
"<div class='pi'><div class='l'>Max Daily Loss</div><div class='v'>%.1f%%</div></div>"
"<div class='pi'><div class='l'>ATR SL Multi</div><div class='v'>%.1fx</div></div>"
"<div class='pi'><div class='l'>ATR TP Multi</div><div class='v'>%.1fx</div></div>"
"</div></div>"
"<footer>Momentum Breakout + SMC Filter EA v2.0 &nbsp;|&nbsp; Angel Garcia &nbsp;|&nbsp;"
"Last update: %s &nbsp;|&nbsp; Auto-refresh 5s</footer>"
"</body></html>",
      // title tag
      _Symbol,
      // header
      _Symbol, statusColor, statusColor, status,
      // KPI
      equity, balance,
      pnlColor, pnlSign, MathAbs(openPnL),
      dailyTrades, MaxDailyTrades, MaxDailyTrades - dailyTrades,
      winRate, totalWins, totalLosses, totalProfit,
      // market context
      trendColor, trendStr,
      rsiStr,
      lossColor, dailyLoss, MaxDailyLossPct,
      // progress
      dailyLoss, MaxDailyLossPct, lossRatio, lossColor,
      dailyTrades, MaxDailyTrades, tradesRatio,
      // position
      dirColor, dirBg, dirColor, posDir,
      posOpenStr, posSLStr, posTPStr, posLotsStr,
      // settings
      RiskPercent, MaxDailyLossPct, ATR_SL_Multi, ATR_TP_Multi,
      // footer
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
   );

   int fh = FileOpen("dashboard_live.html", FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(fh != INVALID_HANDLE)
     { FileWriteString(fh, html); FileClose(fh); }
  }
//+------------------------------------------------------------------+
