//+------------------------------------------------------------------+
//|                                              MHTS_EA.mq5         |
//|              Converted from Pine "M_Housami Trail System" v4.2.1 |
//|              Target: M5 (works on any TF)                        |
//|              Includes [LOGIC] + [SHADOW] debug blocks            |
//|              v1.11: Added QuickScalp preset for M15              |
//+------------------------------------------------------------------+
#property copyright "Converted from Pine Script"
#property version   "1.11"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         trade;
CPositionInfo  pos;
CSymbolInfo    sym;

//--- Enums
enum ENUM_MA_TYPE    { MA_HMA, MA_ALMA, MA_KAMA, MA_T3, MA_VWMA, MA_EMA };
enum ENUM_VOL_TYPE   { VOL_ATR, VOL_STDEV, VOL_HYBRID };
enum ENUM_SL_MODE    { SL_WICK, SL_ATR };
enum ENUM_RISK_PRESET{ RP_CONSERVATIVE, RP_BALANCED, RP_AGGRESSIVE, RP_SCALPING, RP_QUICKSCALP, RP_CUSTOM };

//--- Inputs
input group "=== Main Settings ==="
input ENUM_MA_TYPE    InpMaType     = MA_ALMA;   // Baseline MA
input int             InpMaLen      = 21;        // Baseline Length
input int             InpRsiLen     = 13;        // RSI Length
input int             InpRsiSmooth  = 3;         // RSI Smoothing
input ENUM_VOL_TYPE   InpVolType    = VOL_HYBRID;// Volatility Engine
input int             InpVolLen     = 13;        // Volatility Length
input double          InpTrailMult  = 2.0;       // Trail Multiplier
input double          InpAdapt      = 1.0;       // Momentum Adaptivity (0..1)

input group "=== Filters ==="
input bool            InpUseHtf     = false;                // Use HTF Bias Filter
input ENUM_TIMEFRAMES InpHtfTf      = PERIOD_H4;            // Higher Timeframe
input bool            InpUseVol     = false;                // Use Volume Filter
input double          InpVolMult    = 1.2;                  // Volume Threshold (x SMA20)

input group "=== Risk Management ==="
input ENUM_RISK_PRESET InpRiskPreset = RP_QUICKSCALP;       // Risk Preset (M15: use QuickScalp)
input ENUM_SL_MODE     InpSlMode     = SL_WICK;
input int              InpAtrLenRisk = 14;
input double           InpSlMult     = 1.5;      // Custom preset only
input double           InpTp1Mult    = 1.0;
input double           InpTp2Mult    = 2.0;
input double           InpTp3Mult    = 3.0;
input bool             InpBeAfterTp1 = true;

input group "=== Trade Settings ==="
input double          InpLotSize    = 0.1;
input ulong           InpMagic      = 20241101;
input int             InpSlippage   = 20;

input group "=== Debug ==="
input bool            InpDebugLogic  = true;   // Print [LOGIC] bar-by-bar
input bool            InpDebugShadow = true;   // Print [SHADOW] raw flips

//--- Handles
int hATR_vol = INVALID_HANDLE, hATR_risk = INVALID_HANDLE;
int hRSI     = INVALID_HANDLE, hVolSMA    = INVALID_HANDLE;
int hHTF_EMA = INVALID_HANDLE;
int hT3_e1=INVALID_HANDLE,hT3_e2=INVALID_HANDLE,hT3_e3=INVALID_HANDLE;
int hT3_e4=INVALID_HANDLE,hT3_e5=INVALID_HANDLE,hT3_e6=INVALID_HANDLE;

//--- State
bool     g_active=false;
int      g_dir=0;
double   g_entry=0, g_sl=0, g_tp1=0, g_tp2=0, g_tp3=0;
bool     g_tp1Hit=false, g_tp2Hit=false, g_tp3Hit=false, g_beActive=false;
datetime g_entryTime=0;

//--- Trail state
double g_trail=0.0;
int    g_trendDir=0;

//--- RSI smoothing state (persistent across bars)
double g_rsiSmooth = 50.0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(!sym.Name(_Symbol)) return INIT_FAILED;
   sym.RefreshRates();

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   hATR_vol  = iATR(_Symbol, _Period, InpVolLen);
   hATR_risk = iATR(_Symbol, _Period, InpAtrLenRisk);
   hRSI      = iRSI(_Symbol, _Period, InpRsiLen, PRICE_CLOSE);
   hVolSMA   = iMA(_Symbol, _Period, 20, 0, MODE_SMA, VOLUME_TICK);

   if(InpUseHtf)
      hHTF_EMA = iMA(_Symbol, InpHtfTf, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(InpMaType == MA_T3)
   {
      hT3_e1=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,PRICE_CLOSE);
      hT3_e2=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,hT3_e1);
      hT3_e3=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,hT3_e2);
      hT3_e4=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,hT3_e3);
      hT3_e5=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,hT3_e4);
      hT3_e6=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,hT3_e5);
   }

   if(hATR_vol==INVALID_HANDLE||hATR_risk==INVALID_HANDLE||
      hRSI==INVALID_HANDLE||hVolSMA==INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   RecoverState();

   PrintFormat("MHTS_EA v1.11 initialized | Symbol=%s | TF=%s | Preset=%s | DebugLogic=%s | DebugShadow=%s",
      _Symbol, EnumToString(_Period), EnumToString(InpRiskPreset),
      (InpDebugLogic?"ON":"off"), (InpDebugShadow?"ON":"off"));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR_vol !=INVALID_HANDLE) IndicatorRelease(hATR_vol);
   if(hATR_risk!=INVALID_HANDLE) IndicatorRelease(hATR_risk);
   if(hRSI     !=INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hVolSMA  !=INVALID_HANDLE) IndicatorRelease(hVolSMA);
   if(hHTF_EMA !=INVALID_HANDLE) IndicatorRelease(hHTF_EMA);
   if(hT3_e1   !=INVALID_HANDLE) IndicatorRelease(hT3_e1);
   if(hT3_e2   !=INVALID_HANDLE) IndicatorRelease(hT3_e2);
   if(hT3_e3   !=INVALID_HANDLE) IndicatorRelease(hT3_e3);
   if(hT3_e4   !=INVALID_HANDLE) IndicatorRelease(hT3_e4);
   if(hT3_e5   !=INVALID_HANDLE) IndicatorRelease(hT3_e5);
   if(hT3_e6   !=INVALID_HANDLE) IndicatorRelease(hT3_e6);
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
double Buf(int handle, int shift, int buf=0)
{
   if(handle==INVALID_HANDLE) return 0.0;
   double a[];
   if(CopyBuffer(handle, buf, shift, 1, a) != 1) return 0.0;
   return a[0];
}
double C(int s){ return iClose(_Symbol,_Period,s); }
double H(int s){ return iHigh (_Symbol,_Period,s); }
double L(int s){ return iLow  (_Symbol,_Period,s); }

double N(double p)
{
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   return NormalizeDouble(p, d);
}

//+------------------------------------------------------------------+
//| ALMA                                                             |
//+------------------------------------------------------------------+
double CalcALMA(int period, double offset, double sigma, int shift)
{
   double m = offset*(period-1);
   double s = (double)period/sigma;
   double wSum=0, pSum=0;
   for(int i=0;i<period;i++)
   {
      double w = MathExp(-((i-m)*(i-m))/(2.0*s*s));
      double p = C(shift+i);
      if(p<=0) continue;
      wSum += w; pSum += w*p;
   }
   return (wSum>0)? pSum/wSum : C(shift);
}

//+------------------------------------------------------------------+
double CalcWMA(int period, int shift)
{
   double wSum=0,sum=0;
   for(int i=0;i<period;i++)
   {
      double w = (double)(period-i);
      wSum += w; sum += w*C(shift+i);
   }
   return (wSum>0)? sum/wSum : C(shift);
}

//+------------------------------------------------------------------+
double CalcHMA(int period, int shift)
{
   int halfP = period/2;
   int sqrtP = (int)MathRound(MathSqrt((double)period));
   if(sqrtP<1) sqrtP=1;
   double wSum=0,sum=0;
   for(int i=0;i<sqrtP;i++)
   {
      double raw = 2.0*CalcWMA(halfP,shift+i) - CalcWMA(period,shift+i);
      double w = (double)(sqrtP-i);
      wSum += w; sum += w*raw;
   }
   return (wSum>0)? sum/wSum : C(shift);
}

//+------------------------------------------------------------------+
double CalcKAMA(int period, int shift)
{
   double fastSC = 2.0/3.0;
   double slowSC = 2.0/31.0;

   int maxBars = Bars(_Symbol,_Period);
   int lookback = MathMin(200, maxBars - period - shift - 5);
   if(lookback < period+5) lookback = period+5;
   int start = shift + lookback;
   if(start >= maxBars-1) start = maxBars-2;

   double k = C(start);
   for(int i=start-1;i>=shift;i--)
   {
      double src  = C(i);
      double srcN = C(i+period);
      if(srcN<=0) srcN = src;
      double mom = MathAbs(src-srcN);
      double noise=0;
      for(int j=0;j<period;j++)
      {
         double c1=C(i+j);
         double c2=C(i+j+1);
         if(c2<=0) c2=c1;
         noise += MathAbs(c1-c2);
      }
      double er = (noise!=0)? mom/noise : 0;
      double sc = MathPow(er*(fastSC-slowSC)+slowSC, 2);
      k = k + sc*(src-k);
   }
   return k;
}

//+------------------------------------------------------------------+
double CalcT3(int shift)
{
   double a=0.7;
   double e3=Buf(hT3_e3,shift), e4=Buf(hT3_e4,shift);
   double e5=Buf(hT3_e5,shift), e6=Buf(hT3_e6,shift);
   double c1=-a*a*a;
   double c2= 3*a*a + 3*a*a*a;
   double c3=-6*a*a - 3*a - 3*a*a*a;
   double c4= 1 + 3*a + a*a*a + 3*a*a;
   return c1*e6 + c2*e5 + c3*e4 + c4*e3;
}

//+------------------------------------------------------------------+
double CalcBaseline(int shift)
{
   switch(InpMaType)
   {
      case MA_ALMA: return CalcALMA(InpMaLen, 0.85, 6.0, shift);
      case MA_HMA:  return CalcHMA(InpMaLen, shift);
      case MA_KAMA: return CalcKAMA(InpMaLen, shift);
      case MA_T3:   return CalcT3(shift);
      case MA_EMA:
      {
         int h=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,PRICE_CLOSE);
         double v=Buf(h,shift); IndicatorRelease(h); return v;
      }
      case MA_VWMA:
      {
         double wSum=0,pSum=0;
         for(int i=0;i<InpMaLen;i++)
         {
            long v=iVolume(_Symbol,_Period,shift+i);
            double p=C(shift+i);
            if(p<=0||v<=0) continue;
            wSum+=(double)v; pSum+=p*(double)v;
         }
         if(wSum>0) return pSum/wSum;
         int h=iMA(_Symbol,_Period,InpMaLen,0,MODE_EMA,PRICE_CLOSE);
         double v=Buf(h,shift); IndicatorRelease(h); return v;
      }
   }
   return C(shift);
}

//+------------------------------------------------------------------+
void GetRisk(double &slM, double &tp1M, double &tp2M, double &tp3M)
{
   switch(InpRiskPreset)
   {
      case RP_CONSERVATIVE: slM=2.5; tp1M=1.0; tp2M=2.0; tp3M=4.0; break;
      case RP_AGGRESSIVE:   slM=1.0; tp1M=1.5; tp2M=2.5; tp3M=4.0; break;
      case RP_SCALPING:     slM=0.8; tp1M=0.8; tp2M=1.5; tp3M=2.0; break;
      case RP_QUICKSCALP:   slM=1.0; tp1M=0.4; tp2M=0.8; tp3M=1.2; break;   // <-- NEW
      case RP_CUSTOM:       slM=InpSlMult; tp1M=InpTp1Mult; tp2M=InpTp2Mult; tp3M=InpTp3Mult; break;
      default:              slM=1.5; tp1M=1.0; tp2M=2.0; tp3M=3.0; break;
   }
}

//+------------------------------------------------------------------+
void RecoverState()
{
   if(pos.SelectByMagic(_Symbol, InpMagic))
   {
      g_active  = true;
      g_dir     = (pos.PositionType()==POSITION_TYPE_BUY)? 1 : -1;
      g_entry   = pos.PriceOpen();
      g_sl      = pos.StopLoss();
      double risk = MathAbs(g_entry-g_sl);
      double slM,tp1M,tp2M,tp3M;
      GetRisk(slM,tp1M,tp2M,tp3M);
      if(g_dir==1)
      {
         g_tp1=g_entry+risk*tp1M;
         g_tp2=g_entry+risk*tp2M;
         g_tp3=g_entry+risk*tp3M;
      }
      else
      {
         g_tp1=g_entry-risk*tp1M;
         g_tp2=g_entry-risk*tp2M;
         g_tp3=g_entry-risk*tp3M;
      }
      g_entryTime=(datetime)pos.Time();
      Print("State recovered: dir=",g_dir," entry=",g_entry," sl=",g_sl);
   }
}

//+------------------------------------------------------------------+
void EnforceStopsLevel(double price, bool isBuy, double &sl, double &tp)
{
   int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = stops * _Point;
   double spread  = (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID));
   if(minDist < spread) minDist = spread;

   if(isBuy)
   {
      if(price - sl < minDist) sl = price - minDist;
      if(tp - price < minDist) tp = price + minDist;
   }
   else
   {
      if(sl - price < minDist) sl = price + minDist;
      if(price - tp < minDist) tp = price - minDist;
   }
}

//+------------------------------------------------------------------+
//| OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Sync state with actual position
   bool hasPos = pos.SelectByMagic(_Symbol, InpMagic);
   if(!hasPos && g_active)
   {
      Print("Position closed by SL/TP or externally");
      g_active = false;
      g_dir    = 0;
      g_tp1Hit = g_tp2Hit = g_tp3Hit = g_beActive = false;
   }

   //--- New bar gating
   datetime curTime = iTime(_Symbol, _Period, 0);
   static datetime lastBarTime = 0;
   if(curTime == lastBarTime) return;
   lastBarTime = curTime;

   //--- Warm-up
   int minBars = MathMax(InpMaLen*2, InpRsiLen+InpRsiSmooth) + 50;
   if(Bars(_Symbol,_Period) < minBars) return;

   //--- Use just-closed bar
   int S = 1;

   //--- Baseline MA
   double baseMa = CalcBaseline(S);

   //--- Smoothed RSI
   double rsiRaw = Buf(hRSI, S);
   if(rsiRaw<=0) rsiRaw = 50.0;
   double alpha = 2.0/(InpRsiSmooth+1.0);
   g_rsiSmooth = g_rsiSmooth + alpha*(rsiRaw - g_rsiSmooth);
   double rsiS = g_rsiSmooth;

   //--- Momentum distance 0..1
   double momDist = MathMin(MathAbs(rsiS-50.0)/50.0, 1.0);

   //--- Effective trail multiplier
   double effTrailMult = InpTrailMult * (1.0 - InpAdapt*momDist*0.4);

   //--- Volatility
   double atrV = Buf(hATR_vol, S);
   double stdV = 0.0;
   {
      double sum=0,sum2=0;
      for(int i=0;i<InpVolLen;i++)
      {
         double c=C(S+i);
         sum += c; sum2 += c*c;
      }
      double mean = sum/InpVolLen;
      double var  = (sum2/InpVolLen) - (mean*mean);
      if(var>0) stdV = MathSqrt(var);
   }
   double volMeasure = atrV;
   if(InpVolType==VOL_STDEV)       volMeasure = stdV;
   else if(InpVolType==VOL_HYBRID) volMeasure = (atrV+stdV)/2.0;

   double trailOffset = volMeasure * effTrailMult;

   //--- HTF bias
   bool htfBull=true, htfBear=true;
   if(InpUseHtf && hHTF_EMA!=INVALID_HANDLE)
   {
      double htfEma   = Buf(hHTF_EMA, 1);
      double htfClose = iClose(_Symbol, InpHtfTf, 1);
      htfBull = (htfClose > htfEma);
      htfBear = (htfClose < htfEma);
   }

   //--- Volume filter
   double volSma = Buf(hVolSMA, S);
   long   curVol = iVolume(_Symbol,_Period,S);
   bool   hasVol = (curVol > 0);
   bool   volOk  = (!InpUseVol || !hasVol || (volSma>0 && (double)curVol > volSma*InpVolMult));

   //--- Trail engine (ratchet)
   double closeBar = C(S);
   double upCand   = baseMa - trailOffset;
   double dnCand   = baseMa + trailOffset;

   int prevDir = g_trendDir;

   if(g_trail == 0.0)
   {
      g_trendDir = (closeBar >= baseMa) ? 1 : -1;
      g_trail    = (g_trendDir==1) ? upCand : dnCand;
   }
   else
   {
      if(g_trendDir==1)
      {
         if(upCand > g_trail) g_trail = upCand;
         if(closeBar < g_trail)
         {
            g_trendDir = -1;
            g_trail    = dnCand;
         }
      }
      else
      {
         if(dnCand < g_trail) g_trail = dnCand;
         if(closeBar > g_trail)
         {
            g_trendDir = 1;
            g_trail    = upCand;
         }
      }
   }

   bool rawBuy  = (g_trendDir== 1 && prevDir==-1);
   bool rawSell = (g_trendDir==-1 && prevDir== 1);

   bool longSig  = rawBuy  && htfBull && volOk;
   bool shortSig = rawSell && htfBear && volOk;

   //--- Risk params & ATR
   double slM,tp1M,tp2M,tp3M;
   GetRisk(slM,tp1M,tp2M,tp3M);
   double riskAtr  = Buf(hATR_risk, S);
   double riskDist = riskAtr * slM;

   //==================================================================
   //=== [DEBUG 2] Shadow trade — fires on any raw flip ===============
   //==================================================================
   if(InpDebugShadow && (rawBuy || rawSell))
   {
      int    shadowDir = rawBuy ? 1 : -1;
      double shadowRef = closeBar;
      double shadowSl=0, shadowRisk=0;

      if(shadowDir == 1)
      {
         double slAtr  = shadowRef - riskDist;
         double slWick = MathMin(L(S) - riskAtr*0.25, shadowRef - riskAtr*0.5);
         shadowSl      = (InpSlMode==SL_ATR) ? slAtr : slWick;
         shadowRisk    = shadowRef - shadowSl;
      }
      else
      {
         double slAtr  = shadowRef + riskDist;
         double slWick = MathMax(H(S) + riskAtr*0.25, shadowRef + riskAtr*0.5);
         shadowSl      = (InpSlMode==SL_ATR) ? slAtr : slWick;
         shadowRisk    = shadowSl - shadowRef;
      }

      if(shadowRisk > 0)
      {
         double sTp1 = (shadowDir==1) ? shadowRef + shadowRisk*tp1M : shadowRef - shadowRisk*tp1M;
         double sTp2 = (shadowDir==1) ? shadowRef + shadowRisk*tp2M : shadowRef - shadowRisk*tp2M;
         double sTp3 = (shadowDir==1) ? shadowRef + shadowRisk*tp3M : shadowRef - shadowRisk*tp3M;

         // Filter status flags
         string filterStatus = "";
         if(!volOk)                                   filterStatus += "VOL ";
         if(shadowDir== 1 && !htfBull)                filterStatus += "HTF ";
         if(shadowDir==-1 && !htfBear)                filterStatus += "HTF ";
         if(g_active && g_dir == shadowDir)           filterStatus += "ALREADY-IN ";
         if(g_active && g_dir != shadowDir)           filterStatus += "REVERSAL ";
         if(filterStatus == "")                       filterStatus = "PASS";

         // Score (mirrors Pine)
         double momScore = MathMin(momDist/0.6, 1.0) * 40.0;
         double volRatio = (volSma>0) ? (double)curVol/volSma : 1.0;
         double volScore = hasVol ? MathMin(MathMax(volRatio-0.5,0.0),2.0)/2.0*30.0 : 15.0;
         double htfScore = (shadowDir==1 ? (htfBull?30.0:10.0) : (htfBear?30.0:10.0));
         double score    = momScore + volScore + htfScore;

         PrintFormat("[SHADOW] %s %s | Bar=%s | Entry=%.5f SL=%.5f TP1=%.5f TP2=%.5f TP3=%.5f | Risk=%.5f | Score=%.0f | Filters: %s",
            (shadowDir==1 ? "BUY " : "SELL"),
            _Symbol,
            TimeToString(curTime, TIME_DATE|TIME_MINUTES),
            shadowRef, shadowSl, sTp1, sTp2, sTp3,
            shadowRisk, score, filterStatus);
      }
   }
   //=== [/DEBUG 2] ==================================================

   //--- Trade management for active position
   if(g_active && hasPos)
   {
      datetime barT = iTime(_Symbol,_Period,S);
      if(barT > g_entryTime)
      {
         double hi = H(S), lo = L(S);

         if(g_dir==1)
         {
            if(!g_tp1Hit && hi >= g_tp1) g_tp1Hit = true;
            if(!g_tp2Hit && hi >= g_tp2) g_tp2Hit = true;
            if(!g_tp3Hit && hi >= g_tp3) g_tp3Hit = true;
         }
         else
         {
            if(!g_tp1Hit && lo <= g_tp1) g_tp1Hit = true;
            if(!g_tp2Hit && lo <= g_tp2) g_tp2Hit = true;
            if(!g_tp3Hit && lo <= g_tp3) g_tp3Hit = true;
         }

         // Break-even after TP1
         if(InpBeAfterTp1 && g_tp1Hit && !g_beActive)
         {
            if(pos.SelectByMagic(_Symbol, InpMagic))
            {
               double tpKeep = pos.TakeProfit();
               double newSl  = N(g_entry);
               if(trade.PositionModify(_Symbol, newSl, tpKeep))
               {
                  g_beActive = true;
                  g_sl       = g_entry;
                  Print("Break-even activated @ ", g_entry);
               }
            }
         }
      }
   }

   //--- Reversals
   if(g_active && hasPos)
   {
      if(longSig && g_dir==-1)
      {
         Print("Reversal -> LONG");
         trade.PositionClose(_Symbol, InpSlippage);
         g_active=false; g_dir=0;
         hasPos = false;
      }
      else if(shortSig && g_dir==1)
      {
         Print("Reversal -> SHORT");
         trade.PositionClose(_Symbol, InpSlippage);
         g_active=false; g_dir=0;
         hasPos = false;
      }
   }

   //--- New entries
   if(!g_active && !hasPos && riskDist > 0)
   {
      // ---- LONG ----
      if(longSig)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double slAtr  = ask - riskDist;
         double slWick = MathMin(L(S) - riskAtr*0.25, ask - riskAtr*0.5);
         double slL    = (InpSlMode==SL_ATR) ? slAtr : slWick;
         double riskL  = ask - slL;
         if(riskL > 0)
         {
            double tp1 = ask + riskL * tp1M;
            double tp2 = ask + riskL * tp2M;
            double tp3 = ask + riskL * tp3M;
            EnforceStopsLevel(ask, true, slL, tp3);

            if(trade.Buy(InpLotSize, _Symbol, ask, N(slL), N(tp3), "MHTS Long"))
            {
               g_active    = true;
               g_dir       = 1;
               g_entry     = ask;
               g_sl        = slL;
               g_tp1       = tp1;
               g_tp2       = tp2;
               g_tp3       = tp3;
               g_tp1Hit    = false;
               g_tp2Hit    = false;
               g_tp3Hit    = false;
               g_beActive  = false;
               g_entryTime = curTime;
               PrintFormat("LONG @ %.5f SL=%.5f TP1=%.5f TP2=%.5f TP3=%.5f",
                  ask, slL, tp1, tp2, tp3);
            }
            else Print("Long order failed: ", trade.ResultRetcodeDescription());
         }
      }
      // ---- SHORT ----
      else if(shortSig)
      {
         double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double slAtr   = bid + riskDist;
         double slWick  = MathMax(H(S) + riskAtr*0.25, bid + riskAtr*0.5);
         double slS     = (InpSlMode==SL_ATR) ? slAtr : slWick;
         double riskS   = slS - bid;
         if(riskS > 0)
         {
            double tp1 = bid - riskS * tp1M;
            double tp2 = bid - riskS * tp2M;
            double tp3 = bid - riskS * tp3M;
            EnforceStopsLevel(bid, false, slS, tp3);

            if(trade.Sell(InpLotSize, _Symbol, bid, N(slS), N(tp3), "MHTS Short"))
            {
               g_active    = true;
               g_dir       = -1;
               g_entry     = bid;
               g_sl        = slS;
               g_tp1       = tp1;
               g_tp2       = tp2;
               g_tp3       = tp3;
               g_tp1Hit    = false;
               g_tp2Hit    = false;
               g_tp3Hit    = false;
               g_beActive  = false;
               g_entryTime = curTime;
               PrintFormat("SHORT @ %.5f SL=%.5f TP1=%.5f TP2=%.5f TP3=%.5f",
                  bid, slS, tp1, tp2, tp3);
            }
            else Print("Short order failed: ", trade.ResultRetcodeDescription());
         }
      }
   }

   //==================================================================
   //=== [DEBUG 1] Bar-by-bar logic trace =============================
   //==================================================================
   if(InpDebugLogic)
   {
      static datetime lastLogicLog = 0;
      if(curTime != lastLogicLog)
      {
         lastLogicLog = curTime;
         PrintFormat("[LOGIC] %s | Trend=%s | Trail=%.5f | Base=%.5f | Close=%.5f | RSI=%.1f | MomDist=%.2f | Offset=%.5f | Vol=%.5f | HTF=%s | VolFilter=%s | Position=%s",
            TimeToString(curTime, TIME_DATE|TIME_MINUTES),
            (g_trendDir==1 ? "BULL" : g_trendDir==-1 ? "BEAR" : "---"),
            g_trail, baseMa, closeBar, rsiS, momDist, trailOffset, volMeasure,
            (InpUseHtf ? (htfBull?"Bull":htfBear?"Bear":"Flat") : "off"),
            (InpUseVol ? (volOk?"OK":"Fail") : "off"),
            (g_active ? (g_dir==1?"LONG":"SHORT") : "flat"));
      }
   }
   //=== [/DEBUG 1] ==================================================
}
//+------------------------------------------------------------------+