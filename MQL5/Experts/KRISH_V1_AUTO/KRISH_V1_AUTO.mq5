//+------------------------------------------------------------------+
//|                                               KRISH_V1_AUTO.mq5  |
//|                        GOLD (XAUUSD) adaptive probability robot   |
//|                                                                  |
//|  LOGIC SUMMARY                                                   |
//|  1) PREDICTION ENGINE (multi factor, multi timeframe) decides     |
//|     probability of UP vs DOWN. Trade opens only when probability  |
//|     of one side >= InpMinProbability.                             |
//|                                                                  |
//|  2) FAVOUR SIDE (price goes in our direction) = ADD-ON PYRAMID    |
//|     - initial trade with base lot (0.01)                         |
//|     - every +InpAddonStepPoints (200) a new ADD-ON with SAME lot  |
//|       is triggered from a pre-placed pending stop leg             |
//|     - as soon as the 2nd position exists, SL for the WHOLE basket |
//|       is placed InpAddonSLBufferPoints (100) behind the newest    |
//|       add-on, then it trails STEP-WISE                           |
//|     - when the trail SL is hit, every position of the cycle exits |
//|     - next add-on pending leg is always pre-armed (one fills ->   |
//|       next one gets placed)                                       |
//|                                                                  |
//|  3) AGAINST SIDE (price reverses) = LAYERED RECOVERY GRID         |
//|     - main-direction layer pending at InpGridStepPoints (800)     |
//|       against the deepest layer, lot increased mildly             |
//|       (multiplier default 1.3, NOT aggressive)                    |
//|     - just InpProtectOffsetPoints (50-100) beyond that layer, an  |
//|       OPPOSITE protection leg is pending, and its lot = lot of    |
//|       the last (deepest) grid layer                               |
//|     - when the protection leg triggers, the NEXT main layer is    |
//|       armed InpGridStepPoints beyond it (bigger lot) together     |
//|       with its own opposite protection leg of the same lot        |
//|     - the whole basket has a WEIGHTED TP that is recalculated on  |
//|       every fill / every banked profit, so that closing there     |
//|       gives recovery + target profit                              |
//|                                                                  |
//|  4) Everything is mirrored if the first signal is SELL.           |
//+------------------------------------------------------------------+
#property copyright "KRISH V1 AUTO"
#property link      "https://github.com/honeyyx0009-source/KRISH-V1-AUTO"
#property version   "1.00"
#property description "Gold probability engine + add-on pyramid + layered recovery grid with protection legs"

#include <Trade\Trade.mqh>

//==================================================================
//  I N P U T S
//==================================================================
input group "===== 1. GENERAL ====="
input long    InpMagic                 = 260901;   // Magic base (uses magic, magic+1, magic+2)
input bool    InpEnableTrading         = true;     // Allow new cycles
input bool    InpAutoPointAdjust       = true;     // Auto fix points for 3/5 digit brokers
input double  InpMaxSpreadPoints       = 60;       // Max spread (points) for new entries
input ulong   InpSlippagePoints        = 50;       // Slippage / deviation (points)
input bool    InpShowPanel             = true;     // Show info panel on chart

input group "===== 2. PREDICTION ENGINE ====="
input int     InpSignalMode            = 0;        // 0=engine, 1=force BUY, 2=force SELL
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_M15; // Working timeframe
input ENUM_TIMEFRAMES InpMidTF         = PERIOD_H1;  // Confirmation timeframe
input ENUM_TIMEFRAMES InpBigTF         = PERIOD_H4;  // Master trend timeframe
input double  InpMinProbability        = 60.0;     // Min probability % to open a cycle
input double  InpMinADX                = 12.0;     // Min ADX (0 = off)
input int     InpCooldownBars          = 2;        // Wait bars after a cycle closes

input group "===== 3. LOT PROGRESSION ====="
input double  InpBaseLot               = 0.01;     // Base lot (initial trade + add-ons)
input double  InpLotMultiplier         = 1.3;      // Grid lot multiplier (mild)
input double  InpLotAddStep            = 0.00;     // Extra additive lot per layer
input double  InpMaxLot                = 1.00;     // Hard lot cap (0 = broker max)

input group "===== 4. FAVOUR SIDE (ADD-ON PYRAMID) ====="
input bool    InpUseAddon              = true;     // Enable add-on pyramid
input double  InpAddonStepPoints       = 200;      // Points in favour for next add-on
input double  InpAddonLot              = 0.00;     // Add-on lot (0 = same as base lot)
input int     InpMaxAddons             = 15;       // Max add-on positions
input double  InpAddonSLBufferPoints   = 100;      // SL this many points behind newest add-on
input bool    InpUseTrail              = true;     // Step-wise trailing after 2nd position
input double  InpTrailDistancePoints   = 150;      // Trail distance from price
input double  InpTrailStepPoints       = 50;       // Trail step (SL moves in these steps)

input group "===== 5. AGAINST SIDE (RECOVERY GRID) ====="
input bool    InpUseRecovery           = true;     // Enable recovery grid
input double  InpGridStepPoints        = 800;      // Distance to next main layer
input int     InpMaxLayers             = 8;        // Max main-direction layers (incl. initial)
input bool    InpUseProtectionLeg      = true;     // Place opposite protection leg
input double  InpProtectOffsetPoints   = 80;       // Leg distance beyond the layer (50-100)
input bool    InpLegUseTrail           = true;     // Trail the protection leg
input double  InpLegTrailStartPoints   = 200;      // Leg profit needed to start trailing
input double  InpLegTrailDistPoints    = 250;      // Leg trail distance
input double  InpLegTrailStepPoints    = 100;      // Leg trail step
input double  InpLegFixedSLPoints      = 0;        // Leg fixed SL (0 = none)
input double  InpLegFixedTPPoints      = 0;        // Leg fixed TP (0 = none)

input group "===== 6. WEIGHTED BASKET TP ====="
input double  InpBasketTargetMoney     = 0;        // Basket target in money (0 = auto)
input double  InpAutoTargetPoints      = 300;      // Auto target: points on base lot
input double  InpTargetGrowthPerLayer  = 0;        // % target growth per extra layer
input bool    InpPlaceHardTP           = true;     // Put real TP when no leg is open
input bool    InpShowTPLine            = true;     // Draw basket TP / next level lines

input group "===== 7. SAFETY ====="
input double  InpMaxBasketLossMoney    = 0;        // Emergency close of basket loss (0 = off)
input double  InpEquityStopPct         = 0;        // Stop EA if equity drops this % (0 = off)
input bool    InpUseSessionFilter      = false;    // Only open cycles inside session
input int     InpSessionStartHour      = 1;        // Session start hour (server)
input int     InpSessionEndHour        = 23;       // Session end hour (server)
input bool    InpCloseAllOnFriday      = false;    // Flat everything on Friday
input int     InpFridayCloseHour       = 21;       // Friday close hour (server)

//==================================================================
//  T Y P E S  /  G L O B A L S
//==================================================================
#define MAXREC 300

#define ROLE_MAIN   0
#define ROLE_ADDON  1
#define ROLE_LEG    2

#define MODE_IDLE      0
#define MODE_WAIT      1   // only initial trade, both legs armed
#define MODE_PYRAMID   2   // add-on side engaged, trailing SL manages exit
#define MODE_RECOVERY  3   // grid engaged, weighted basket TP manages exit

struct TradeRec
  {
   ulong             ticket;
   int               type;      // ORDER_TYPE_* / POSITION_TYPE_*
   int               dir;       // +1 long, -1 short
   double            lot;
   double            price;
   double            sl;
   double            tp;
   double            profit;    // money (positions only)
   datetime          time;
  };

CTrade   trade;
string   g_sym;
int      g_digits;
double   g_pt;            // symbol point
double   g_padj;          // point adjust factor (1 or 10)
double   g_tickSize;
double   g_vpu;           // money value of 1.0 price unit for 1.0 lot
double   g_lotMin, g_lotMax, g_lotStep;
long     g_magMain, g_magAddon, g_magLeg;
double   g_stopsDist;     // broker min stop distance in price

//--- live state
TradeRec g_mainPos[MAXREC];  int g_nMainPos;
TradeRec g_addPos[MAXREC];   int g_nAddPos;
TradeRec g_legPos[MAXREC];   int g_nLegPos;
TradeRec g_mainPend[MAXREC]; int g_nMainPend;
TradeRec g_addPend[MAXREC];  int g_nAddPend;
TradeRec g_legPend[MAXREC];  int g_nLegPend;

int      g_dir;            // cycle direction (+1 buy, -1 sell, 0 none)
double   g_worstMain;      // deepest main layer entry price
double   g_worstMainLot;   // lot of the deepest main layer
double   g_bestFavour;     // best (most in profit) entry among main+addons
double   g_floating;       // floating money of all our positions
double   g_netLot;         // sum(dir*lot)
double   g_wSum;           // sum(dir*lot*entry)
double   g_sumMainLot, g_sumLegLot;
int      g_mode;
int      g_prevPosTotal;
int      g_prevMode;

//--- realized pnl cache
double   g_realized;
datetime g_realizedStamp;
int      g_realizedCount;

//--- cycle bookkeeping (persisted so restart is safe)
datetime g_cycleStart;
int      g_layerArmed;     // highest main layer index that was armed
int      g_legArmed;       // highest protection leg index that was armed
bool     g_halted;
datetime g_lastCycleEnd;
double   g_startBalance;

//--- throttle for market fallback fills (level already passed)
datetime g_lastMktTry;

//--- signal cache
double   g_probUp;
double   g_adx;
int      g_sigDir;
string   g_sigNote;
datetime g_sigBar;
datetime g_lastEntryBar;

//--- indicator handles
int hEmaF, hEmaS, hEmaMF, hEmaMS, hEmaBF, hEmaBS;
int hAdx, hRsi, hMacd, hAtr, hBands, hStoch;

//--- global variable names (terminal globals -> restart safe)
string gvCS, gvLA, gvLG, gvHALT;

//==================================================================
//  S M A L L   H E L P E R S
//==================================================================
double Squash(const double x) { return(x/(1.0+MathAbs(x))); }

double P2P(const double points) { return(points*g_padj*g_pt); }          // points -> price distance
double Pts(const double priceDist) { return(priceDist/(g_padj*g_pt)); }  // price distance -> points

bool IsOurMagic(const long m)
  { return(m==g_magMain || m==g_magAddon || m==g_magLeg); }

int RoleOfMagic(const long m)
  {
   if(m==g_magMain)  return(ROLE_MAIN);
   if(m==g_magAddon) return(ROLE_ADDON);
   if(m==g_magLeg)   return(ROLE_LEG);
   return(-1);
  }

double Ask() { return(SymbolInfoDouble(g_sym,SYMBOL_ASK)); }
double Bid() { return(SymbolInfoDouble(g_sym,SYMBOL_BID)); }

//--- price used to close a position of direction d
double ClosePriceFor(const int d) { return(d>0 ? Bid() : Ask()); }
//--- price used to open a position of direction d
double OpenPriceFor(const int d)  { return(d>0 ? Ask() : Bid()); }

double SpreadPoints() { return(Pts(Ask()-Bid())); }

double NormPrice(double p)
  {
   if(g_tickSize>0.0) p=MathRound(p/g_tickSize)*g_tickSize;
   return(NormalizeDouble(p,g_digits));
  }

double NormLot(double l)
  {
   if(g_lotStep<=0.0) g_lotStep=0.01;
   l=MathRound(l/g_lotStep)*g_lotStep;
   double cap=g_lotMax;
   if(InpMaxLot>0.0) cap=MathMin(cap,InpMaxLot);
   l=MathMax(g_lotMin,MathMin(cap,l));
   return(NormalizeDouble(l,2));
  }

//--- mild, non aggressive progression
double NextLot(const double prev)
  {
   double l=prev*InpLotMultiplier+InpLotAddStep;
   l=NormLot(l);
   if(l<=prev) l=NormLot(prev+g_lotStep);
   return(l);
  }

//--- has price already traded through 'level' on the losing side of dir?
bool PricePassedAgainst(const double level,const int dir)
  {
   if(dir>0) return(Bid()<=level);
   return(Ask()>=level);
  }

//--- has price already traded through 'level' on the favour side of dir?
bool PricePassedFavour(const double level,const int dir)
  {
   if(dir>0) return(Ask()>=level);
   return(Bid()<=level);
  }

void SortByTime(TradeRec &arr[],const int n)
  {
   for(int i=1;i<n;i++)
     {
      TradeRec key=arr[i];
      int j=i-1;
      while(j>=0 && (arr[j].time>key.time || (arr[j].time==key.time && arr[j].ticket>key.ticket)))
        { arr[j+1]=arr[j]; j--; }
      arr[j+1]=key;
     }
  }

//--- don't hammer the server when a market fallback keeps failing
bool MktTryOk()
  {
   if(TimeCurrent()-g_lastMktTry<2) return(false);
   g_lastMktTry=TimeCurrent();
   return(true);
  }

string DirName(const int d) { return(d>0?"BUY":(d<0?"SELL":"-")); }

string ModeName(const int m)
  {
   switch(m)
     {
      case MODE_IDLE:     return("IDLE");
      case MODE_WAIT:     return("WAIT (both legs armed)");
      case MODE_PYRAMID:  return("PYRAMID (add-on + trail)");
      case MODE_RECOVERY: return("RECOVERY (grid + legs)");
     }
   return("?");
  }

//==================================================================
//  I N I T
//==================================================================
int OnInit()
  {
   g_sym=_Symbol;
   g_digits=(int)SymbolInfoInteger(g_sym,SYMBOL_DIGITS);
   g_pt=SymbolInfoDouble(g_sym,SYMBOL_POINT);
   g_tickSize=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize<=0.0) g_tickSize=g_pt;

   g_padj=1.0;
   if(InpAutoPointAdjust && (g_digits==3 || g_digits==5)) g_padj=10.0;

   double tv=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_VALUE);
   if(tv<=0.0) tv=SymbolInfoDouble(g_sym,SYMBOL_TRADE_TICK_VALUE_PROFIT);
   g_vpu=(g_tickSize>0.0 ? tv/g_tickSize : 1.0);
   if(g_vpu<=0.0) g_vpu=1.0;

   g_lotMin =SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MIN);
   g_lotMax =SymbolInfoDouble(g_sym,SYMBOL_VOLUME_MAX);
   g_lotStep=SymbolInfoDouble(g_sym,SYMBOL_VOLUME_STEP);

   g_magMain =InpMagic;
   g_magAddon=InpMagic+1;
   g_magLeg  =InpMagic+2;

   trade.SetExpertMagicNumber(g_magMain);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(g_sym);
   trade.SetAsyncMode(false);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   gvCS  ="KV1_"+(string)InpMagic+"_CS";
   gvLA  ="KV1_"+(string)InpMagic+"_LA";
   gvLG  ="KV1_"+(string)InpMagic+"_LG";
   gvHALT="KV1_"+(string)InpMagic+"_HALT";

   g_cycleStart=(datetime)(long)GlobalVariableGet(gvCS);
   g_layerArmed=(int)GlobalVariableGet(gvLA);
   g_legArmed  =(int)GlobalVariableGet(gvLG);
   g_halted    =(GlobalVariableCheck(gvHALT) && GlobalVariableGet(gvHALT)>0.0);
   g_startBalance=AccountInfoDouble(ACCOUNT_BALANCE);

   //--- indicators
   hEmaF =iMA(g_sym,InpSignalTF,20,0,MODE_EMA,PRICE_CLOSE);
   hEmaS =iMA(g_sym,InpSignalTF,50,0,MODE_EMA,PRICE_CLOSE);
   hEmaMF=iMA(g_sym,InpMidTF   ,20,0,MODE_EMA,PRICE_CLOSE);
   hEmaMS=iMA(g_sym,InpMidTF   ,50,0,MODE_EMA,PRICE_CLOSE);
   hEmaBF=iMA(g_sym,InpBigTF   ,20,0,MODE_EMA,PRICE_CLOSE);
   hEmaBS=iMA(g_sym,InpBigTF   ,50,0,MODE_EMA,PRICE_CLOSE);
   hAdx  =iADX(g_sym,InpSignalTF,14);
   hRsi  =iRSI(g_sym,InpSignalTF,14,PRICE_CLOSE);
   hMacd =iMACD(g_sym,InpSignalTF,12,26,9,PRICE_CLOSE);
   hAtr  =iATR(g_sym,InpSignalTF,14);
   hBands=iBands(g_sym,InpSignalTF,20,0,2.0,PRICE_CLOSE);
   hStoch=iStochastic(g_sym,InpSignalTF,14,3,3,MODE_SMA,STO_LOWHIGH);

   if(hEmaF==INVALID_HANDLE || hEmaS==INVALID_HANDLE || hEmaMF==INVALID_HANDLE ||
      hEmaMS==INVALID_HANDLE || hEmaBF==INVALID_HANDLE || hEmaBS==INVALID_HANDLE ||
      hAdx==INVALID_HANDLE || hRsi==INVALID_HANDLE || hMacd==INVALID_HANDLE ||
      hAtr==INVALID_HANDLE || hBands==INVALID_HANDLE || hStoch==INVALID_HANDLE)
     {
      Print("KRISH V1: indicator handle creation failed");
      return(INIT_FAILED);
     }

   PrintFormat("KRISH V1 AUTO started on %s | digits=%d point=%.5f pointAdj=%.1f valuePerUnitPerLot=%.2f",
               g_sym,g_digits,g_pt,g_padj,g_vpu);
   PrintFormat("Distances -> addon %.0f pts = %.2f price | grid %.0f pts = %.2f price | leg offset %.0f pts = %.2f price",
               InpAddonStepPoints,P2P(InpAddonStepPoints),
               InpGridStepPoints ,P2P(InpGridStepPoints),
               InpProtectOffsetPoints,P2P(InpProtectOffsetPoints));

   EventSetTimer(2);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0,"KV1_");
   Comment("");
  }

void OnTimer()
  {
   //--- keeps panel alive on a quiet market
   if(InpShowPanel) { ScanState(); DrawPanel(); }
  }

//==================================================================
//  S T A T E   S C A N N E R
//==================================================================
void ScanState()
  {
   g_nMainPos=0; g_nAddPos=0; g_nLegPos=0;
   g_nMainPend=0; g_nAddPend=0; g_nLegPend=0;
   g_floating=0; g_netLot=0; g_wSum=0;
   g_sumMainLot=0; g_sumLegLot=0;
   g_dir=0; g_worstMain=0; g_worstMainLot=0; g_bestFavour=0;

   g_stopsDist=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_pt;
   double frz=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_FREEZE_LEVEL)*g_pt;
   if(frz>g_stopsDist) g_stopsDist=frz;
   if(g_stopsDist<=0.0) g_stopsDist=2.0*g_pt;

   //--- positions
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      long mg=PositionGetInteger(POSITION_MAGIC);
      int role=RoleOfMagic(mg);
      if(role<0) continue;

      TradeRec r;
      r.ticket=tk;
      r.type  =(int)PositionGetInteger(POSITION_TYPE);
      r.dir   =(r.type==POSITION_TYPE_BUY?1:-1);
      r.lot   =PositionGetDouble(POSITION_VOLUME);
      r.price =PositionGetDouble(POSITION_PRICE_OPEN);
      r.sl    =PositionGetDouble(POSITION_SL);
      r.tp    =PositionGetDouble(POSITION_TP);
      r.profit=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      r.time  =(datetime)PositionGetInteger(POSITION_TIME);

      g_floating+=r.profit;
      g_netLot  +=r.dir*r.lot;
      g_wSum    +=r.dir*r.lot*r.price;

      if(role==ROLE_MAIN  && g_nMainPos<MAXREC) g_mainPos[g_nMainPos++]=r;
      if(role==ROLE_ADDON && g_nAddPos <MAXREC) g_addPos [g_nAddPos ++]=r;
      if(role==ROLE_LEG   && g_nLegPos <MAXREC) g_legPos [g_nLegPos ++]=r;
     }

   //--- pending orders
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_sym) continue;
      long mg=OrderGetInteger(ORDER_MAGIC);
      int role=RoleOfMagic(mg);
      if(role<0) continue;

      int tp=(int)OrderGetInteger(ORDER_TYPE);
      if(tp==ORDER_TYPE_BUY || tp==ORDER_TYPE_SELL) continue;

      TradeRec r;
      r.ticket=tk;
      r.type  =tp;
      r.dir   =((tp==ORDER_TYPE_BUY_STOP || tp==ORDER_TYPE_BUY_LIMIT)?1:-1);
      r.lot   =OrderGetDouble(ORDER_VOLUME_CURRENT);
      r.price =OrderGetDouble(ORDER_PRICE_OPEN);
      r.sl    =OrderGetDouble(ORDER_SL);
      r.tp    =OrderGetDouble(ORDER_TP);
      r.profit=0;
      r.time  =(datetime)OrderGetInteger(ORDER_TIME_SETUP);

      if(role==ROLE_MAIN  && g_nMainPend<MAXREC) g_mainPend[g_nMainPend++]=r;
      if(role==ROLE_ADDON && g_nAddPend <MAXREC) g_addPend [g_nAddPend ++]=r;
      if(role==ROLE_LEG   && g_nLegPend <MAXREC) g_legPend [g_nLegPend ++]=r;
     }

   SortByTime(g_mainPos,g_nMainPos);
   SortByTime(g_addPos ,g_nAddPos);
   SortByTime(g_legPos ,g_nLegPos);

   //--- direction of the running cycle
   if(g_nMainPos>0)      g_dir=g_mainPos[0].dir;
   else if(g_nAddPos>0)  g_dir=g_addPos[0].dir;
   else if(g_nLegPos>0)  g_dir=-g_legPos[0].dir;
   else if(g_nMainPend>0)g_dir=g_mainPend[0].dir;
   else                  g_dir=0;

   //--- extremes
   for(int i=0;i<g_nMainPos;i++)
     {
      g_sumMainLot+=g_mainPos[i].lot;
      double p=g_mainPos[i].price;
      if(g_worstMain==0.0 || (g_dir>0 ? p<g_worstMain : p>g_worstMain))
        { g_worstMain=p; g_worstMainLot=g_mainPos[i].lot; }
      if(g_bestFavour==0.0 || (g_dir>0 ? p>g_bestFavour : p<g_bestFavour))
         g_bestFavour=p;
     }
   for(int i=0;i<g_nAddPos;i++)
     {
      g_sumMainLot+=g_addPos[i].lot;
      double p=g_addPos[i].price;
      if(g_bestFavour==0.0 || (g_dir>0 ? p>g_bestFavour : p<g_bestFavour))
         g_bestFavour=p;
     }
   for(int i=0;i<g_nLegPos;i++) g_sumLegLot+=g_legPos[i].lot;

   //--- mode
   int totalPos=g_nMainPos+g_nAddPos+g_nLegPos;
   if(totalPos==0 && g_nMainPend+g_nAddPend+g_nLegPend==0) g_mode=MODE_IDLE;
   else if(g_nMainPos>=2 || g_nLegPos>0)                   g_mode=MODE_RECOVERY;
   else if(g_nAddPos>0)                                    g_mode=MODE_PYRAMID;
   else if(totalPos>0)                                     g_mode=MODE_WAIT;
   else                                                    g_mode=MODE_IDLE;

   RefreshRealized(totalPos);
  }

//--- realized money of the current cycle (closed legs, stopped add-ons...)
void RefreshRealized(const int posCount)
  {
   if(g_cycleStart<=0) { g_realized=0; return; }
   if(posCount==g_realizedCount && TimeCurrent()-g_realizedStamp<2) return;

   g_realizedStamp=TimeCurrent();
   g_realizedCount=posCount;
   g_realized=0;

   if(!HistorySelect(g_cycleStart-1,TimeCurrent()+60)) return;
   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
     {
      ulong dl=HistoryDealGetTicket(i);
      if(dl==0) continue;
      if(HistoryDealGetString(dl,DEAL_SYMBOL)!=g_sym) continue;
      if(!IsOurMagic(HistoryDealGetInteger(dl,DEAL_MAGIC))) continue;
      long entry=HistoryDealGetInteger(dl,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN) 
        {
         //--- entry deals only carry commission
         g_realized+=HistoryDealGetDouble(dl,DEAL_COMMISSION);
         continue;
        }
      g_realized+=HistoryDealGetDouble(dl,DEAL_PROFIT)
                 +HistoryDealGetDouble(dl,DEAL_SWAP)
                 +HistoryDealGetDouble(dl,DEAL_COMMISSION);
     }
  }

//==================================================================
//  P R E D I C T I O N   E N G I N E
//==================================================================
bool Buf(const int handle,const int bufIdx,const int shift,const int count,double &out[])
  {
   ArrayResize(out,count);
   return(CopyBuffer(handle,bufIdx,shift,count,out)==count);
  }

//--- weighted multi factor probability of the UP side
bool ComputeSignal()
  {
   double emaF[],emaS[],emaMF[],emaMS[],emaBF[],emaBS[];
   double adxM[],adxP[],adxN[],rsi[],macM[],macS[],atr[];
   double bbU[],bbL[],bbM[],stK[],stD[];

   if(!Buf(hEmaF ,0,1,5,emaF))  return(false);
   if(!Buf(hEmaS ,0,1,5,emaS))  return(false);
   if(!Buf(hEmaMF,0,1,3,emaMF)) return(false);
   if(!Buf(hEmaMS,0,1,3,emaMS)) return(false);
   if(!Buf(hEmaBF,0,1,3,emaBF)) return(false);
   if(!Buf(hEmaBS,0,1,3,emaBS)) return(false);
   if(!Buf(hAdx  ,0,1,3,adxM))  return(false);
   if(!Buf(hAdx  ,1,1,3,adxP))  return(false);
   if(!Buf(hAdx  ,2,1,3,adxN))  return(false);
   if(!Buf(hRsi  ,0,1,3,rsi))   return(false);
   if(!Buf(hMacd ,0,1,4,macM))  return(false);
   if(!Buf(hMacd ,1,1,4,macS))  return(false);
   if(!Buf(hAtr  ,0,1,3,atr))   return(false);
   if(!Buf(hBands,1,1,2,bbU))   return(false);
   if(!Buf(hBands,2,1,2,bbL))   return(false);
   if(!Buf(hBands,0,1,2,bbM))   return(false);
   if(!Buf(hStoch,0,1,3,stK))   return(false);
   if(!Buf(hStoch,1,1,3,stD))   return(false);

   MqlRates rt[];
   ArraySetAsSeries(rt,false);
   if(CopyRates(g_sym,InpSignalTF,1,25,rt)<25) return(false);
   int last=24;

   double A=atr[2];
   if(A<=0.0) return(false);
   double cl=rt[last].close;

   double score=0.0, wsum=0.0;

   //--- regime weights: strong ADX -> trend factors, weak ADX -> mean reversion
   g_adx=adxM[2];
   double trendW=(g_adx-15.0)/20.0;
   if(trendW<0.0) trendW=0.0;
   if(trendW>1.0) trendW=1.0;
   double rangeW=1.0-trendW;

   //--- F1 working TF trend
   double f1=Squash((emaF[4]-emaS[4])/A);
   score+=f1*(1.6*(0.4+0.6*trendW)); wsum+=1.6*(0.4+0.6*trendW);

   //--- F2 mid TF trend
   double f2=Squash((emaMF[2]-emaMS[2])/(A*1.5));
   score+=f2*1.3; wsum+=1.3;

   //--- F3 big TF master trend
   double f3=Squash((emaBF[2]-emaBS[2])/(A*2.5));
   score+=f3*1.5; wsum+=1.5;

   //--- F4 slope of fast ema
   double f4=Squash((emaF[4]-emaF[1])/A);
   score+=f4*1.0; wsum+=1.0;

   //--- F5 DI balance
   double diSum=adxP[2]+adxN[2];
   double f5=(diSum>0.0 ? (adxP[2]-adxN[2])/diSum : 0.0);
   score+=f5*(1.2*(0.3+0.7*trendW)); wsum+=1.2*(0.3+0.7*trendW);

   //--- F6 MACD histogram + its slope
   double h0=macM[3]-macS[3];
   double h1=macM[1]-macS[1];
   double f6=0.6*Squash(h0/(A*0.30))+0.4*Squash((h0-h1)/(A*0.15));
   score+=f6*1.2; wsum+=1.2;

   //--- F7 RSI momentum (trend regime)
   double f7=(rsi[2]-50.0)/50.0;
   score+=f7*(0.9*trendW); wsum+=0.9*trendW;

   //--- F8 RSI mean reversion (range regime)
   double f8=0.0;
   if(rsi[2]>65.0 || rsi[2]<35.0) f8=-(rsi[2]-50.0)/50.0;
   score+=f8*(1.0*rangeW); wsum+=1.0*rangeW;

   //--- F9 Bollinger position (fade the band in range, ride it in trend)
   double halfBand=MathMax(bbU[1]-bbM[1],g_pt);
   double pctB=(cl-bbM[1])/halfBand;
   double f9=(-Squash(pctB)*rangeW)+(Squash(pctB*0.7)*trendW);
   score+=f9*0.9; wsum+=0.9;

   //--- F10 stochastic
   double f10=0.5*((stK[2]-50.0)/50.0)+0.5*Squash((stK[2]-stD[2])/10.0);
   score+=f10*0.6; wsum+=0.6;

   //--- F11 raw momentum over 10 bars
   double f11=Squash((cl-rt[last-10].close)/(A*3.0));
   score+=f11*1.0; wsum+=1.0;

   //--- F12 20 bar breakout position
   double hh=rt[last].high, ll=rt[last].low;
   for(int i=last-19;i<=last;i++)
     { hh=MathMax(hh,rt[i].high); ll=MathMin(ll,rt[i].low); }
   double rng=MathMax(hh-ll,g_pt);
   double f12=Squash(((cl-ll)/rng-0.5)*2.5);
   score+=f12*(0.9*(0.3+0.7*trendW)); wsum+=0.9*(0.3+0.7*trendW);

   //--- F13 candle structure of last 3 bars
   double body=0.0;
   for(int i=last-2;i<=last;i++)
     {
      double rr=MathMax(rt[i].high-rt[i].low,g_pt);
      body+=(rt[i].close-rt[i].open)/rr;
     }
   double f13=Squash(body/1.5);
   score+=f13*0.7; wsum+=0.7;

   if(wsum<=0.0) return(false);
   double total=score/wsum;              // -1 .. +1
   g_probUp=50.0+50.0*total;
   if(g_probUp<1.0) g_probUp=1.0;
   if(g_probUp>99.0) g_probUp=99.0;

   double probDn=100.0-g_probUp;
   g_sigDir=0;
   if(InpMinADX<=0.0 || g_adx>=InpMinADX)
     {
      if(g_probUp>=InpMinProbability)      g_sigDir=1;
      else if(probDn>=InpMinProbability)   g_sigDir=-1;
     }

   g_sigNote=StringFormat("trend%.2f mid%.2f big%.2f di%.2f macd%.2f mom%.2f",f1,f2,f3,f5,f6,f11);
   return(true);
  }

void UpdateSignalOnNewBar()
  {
   datetime bt=iTime(g_sym,InpSignalTF,0);
   if(bt==g_sigBar && g_sigBar>0) return;
   if(ComputeSignal()) g_sigBar=bt;
  }

int EntryDirection()
  {
   if(InpSignalMode==1) return(1);
   if(InpSignalMode==2) return(-1);
   return(g_sigDir);
  }

//==================================================================
//  O R D E R   H E L P E R S
//==================================================================
ENUM_ORDER_TYPE PendingTypeFor(const int dir,const double price)
  {
   if(dir>0) return(price>Ask() ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_BUY_LIMIT);
   return(price<Bid() ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_SELL_LIMIT);
  }

bool PendingPriceOk(const int dir,const double price)
  {
   double d=(dir>0 ? MathAbs(price-Ask()) : MathAbs(price-Bid()));
   return(d>g_stopsDist+2.0*g_pt);
  }

datetime g_lastPendFail=0;

bool PlacePending(const int dir,double price,double lot,const long magic,
                  const string tag,const double sl=0.0,const double tp=0.0)
  {
   price=NormPrice(price);
   lot=NormLot(lot);
   if(!PendingPriceOk(dir,price)) return(false);
   if(g_lastPendFail>0 && TimeCurrent()-g_lastPendFail<3) return(false);

   ENUM_ORDER_TYPE ot=PendingTypeFor(dir,price);
   trade.SetExpertMagicNumber(magic);
   bool ok=trade.OrderOpen(g_sym,ot,lot,0.0,price,
                           (sl>0.0?NormPrice(sl):0.0),
                           (tp>0.0?NormPrice(tp):0.0),
                           ORDER_TIME_GTC,0,tag);
   trade.SetExpertMagicNumber(g_magMain);
   if(!ok)
     {
      g_lastPendFail=TimeCurrent();
      PrintFormat("KV1: pending %s %.2f @ %s failed, ret=%d %s",
                  EnumToString(ot),lot,DoubleToString(price,g_digits),
                  trade.ResultRetcode(),trade.ResultRetcodeDescription());
     }
   else
      PrintFormat("KV1: pending %s %.2f @ %s placed [%s]",
                  EnumToString(ot),lot,DoubleToString(price,g_digits),tag);
   return(ok);
  }

bool OpenMarket(const int dir,double lot,const long magic,const string tag,
                const double sl=0.0,const double tp=0.0)
  {
   lot=NormLot(lot);
   trade.SetExpertMagicNumber(magic);
   ENUM_ORDER_TYPE ot=(dir>0?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   double px=OpenPriceFor(dir);
   bool ok=trade.PositionOpen(g_sym,ot,lot,px,
                              (sl>0.0?NormPrice(sl):0.0),
                              (tp>0.0?NormPrice(tp):0.0),tag);
   trade.SetExpertMagicNumber(g_magMain);
   if(!ok)
      PrintFormat("KV1: market %s %.2f failed, ret=%d %s",DirName(dir),lot,
                  trade.ResultRetcode(),trade.ResultRetcodeDescription());
   else
      PrintFormat("KV1: market %s %.2f opened [%s]",DirName(dir),lot,tag);
   return(ok);
  }

void DeletePendings(TradeRec &arr[],const int n,const string why)
  {
   for(int i=0;i<n;i++)
     {
      if(trade.OrderDelete(arr[i].ticket))
         PrintFormat("KV1: pending #%I64u deleted (%s)",arr[i].ticket,why);
     }
  }

void DeleteAllOurPendings(const string why)
  {
   DeletePendings(g_mainPend,g_nMainPend,why);
   DeletePendings(g_addPend ,g_nAddPend ,why);
   DeletePendings(g_legPend ,g_nLegPend ,why);
  }

bool SlAllowed(const int dir,const double sl)
  {
   double px=ClosePriceFor(dir);
   if(dir>0) return(sl<px-g_stopsDist);
   return(sl>px+g_stopsDist);
  }

void ModifySL(TradeRec &r,const double sl)
  {
   if(!SlAllowed(r.dir,sl)) return;
   if(MathAbs(r.sl-NormPrice(sl))<g_tickSize*0.5) return;
   if(!trade.PositionModify(r.ticket,NormPrice(sl),r.tp))
      PrintFormat("KV1: SL modify #%I64u -> %s failed ret=%d",
                  r.ticket,DoubleToString(sl,g_digits),trade.ResultRetcode());
  }

void ModifyTP(TradeRec &r,const double tp)
  {
   double want=(tp>0.0?NormPrice(tp):0.0);
   if(MathAbs(r.tp-want)<g_tickSize*0.5) return;
   if(want>0.0)
     {
      double px=ClosePriceFor(r.dir);
      if(r.dir>0 && want<px+g_stopsDist) return;
      if(r.dir<0 && want>px-g_stopsDist) return;
     }
   trade.PositionModify(r.ticket,r.sl,want);
  }

int CloseAllPositions(const string why)
  {
   int closed=0;
   for(int attempt=0;attempt<4;attempt++)
     {
      bool all=true;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong tk=PositionGetTicket(i);
         if(tk==0) continue;
         if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
         if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
         if(trade.PositionClose(tk,InpSlippagePoints)) closed++;
         else all=false;
        }
      if(all) break;
      Sleep(150);
     }
   if(closed>0) PrintFormat("KV1: closed %d position(s) - %s",closed,why);
   return(closed);
  }

//==================================================================
//  C Y C L E   B O O K K E E P I N G
//==================================================================
void StartCycle(const bool adopt=false)
  {
   if(adopt)
     {
      //--- terminal restarted / EA re-attached on a live basket
      datetime t0=TimeCurrent();
      if(g_nMainPos>0) t0=g_mainPos[0].time;
      if(g_nAddPos>0 && g_addPos[0].time<t0) t0=g_addPos[0].time;
      if(g_nLegPos>0 && g_legPos[0].time<t0) t0=g_legPos[0].time;
      g_cycleStart=t0;
      int la=g_nMainPos+(g_nMainPend>0?1:0);
      if(la<1) la=1;
      g_layerArmed=la;
      g_legArmed=((g_nLegPend>0 || g_nLegPos>0)?la:(int)MathMax(1,la-1));
      PrintFormat("KV1: adopted running basket (layers=%d legs=%d) cycleStart=%s",
                  g_nMainPos,g_nLegPos,TimeToString(t0));
     }
   else
     {
      g_cycleStart=TimeCurrent();
      g_layerArmed=1;   // initial trade = layer 1
      g_legArmed=1;     // layer 1 has no protection leg
      PrintFormat("KV1: ===== new cycle started =====");
     }
   GlobalVariableSet(gvCS,(double)(long)g_cycleStart);
   GlobalVariableSet(gvLA,(double)g_layerArmed);
   GlobalVariableSet(gvLG,(double)g_legArmed);
   g_realizedStamp=0; g_realizedCount=-1;
  }

void EndCycle(const string why)
  {
   RefreshRealized(-1);
   PrintFormat("KV1: ===== cycle finished (%s) realized=%.2f =====",why,g_realized);
   g_cycleStart=0;
   g_layerArmed=0;
   g_legArmed=0;
   g_realized=0;
   g_lastCycleEnd=TimeCurrent();
   GlobalVariableDel(gvCS);
   GlobalVariableDel(gvLA);
   GlobalVariableDel(gvLG);
   ObjectsDeleteAll(0,"KV1_lvl");
  }

void SetLayerArmed(const int idx)
  { g_layerArmed=idx; GlobalVariableSet(gvLA,(double)idx); }

void SetLegArmed(const int idx)
  { g_legArmed=idx; GlobalVariableSet(gvLG,(double)idx); }

void Halt(const string why)
  {
   g_halted=true;
   GlobalVariableSet(gvHALT,1.0);
   PrintFormat("KV1: TRADING HALTED - %s",why);
  }

//==================================================================
//  F A V O U R   S I D E   ( A D D - O N   P Y R A M I D )
//==================================================================
void EnsureAddonLeg()
  {
   if(!InpUseAddon) return;
   if(g_dir==0) return;
   if(g_nAddPos>=InpMaxAddons) return;
   if(g_nAddPend>0) return;
   if(g_bestFavour<=0.0) return;

   double lot=(InpAddonLot>0.0?InpAddonLot:InpBaseLot);
   double price=g_bestFavour+g_dir*P2P(InpAddonStepPoints);
   string tag=StringFormat("KV1|A|%d",g_nAddPos+1);

   //--- level already passed by a fast move -> take it at market
   if(PricePassedFavour(price,g_dir))
     {
      if(MktTryOk()) OpenMarket(g_dir,lot,g_magAddon,tag);
      return;
     }

   PlacePending(g_dir,price,lot,g_magAddon,tag);
  }

//--- SL of the whole pyramid: behind newest add-on, then step-wise trail
void ManagePyramidStop()
  {
   int n=g_nMainPos+g_nAddPos;
   if(n<2) return;
   if(g_bestFavour<=0.0) return;

   double base=g_bestFavour-g_dir*P2P(InpAddonSLBufferPoints);
   double want=base;

   if(InpUseTrail)
     {
      double cand=ClosePriceFor(g_dir)-g_dir*P2P(InpTrailDistancePoints);
      if((cand-want)*g_dir>0.0) want=cand;
     }
   want=NormPrice(want);

   double step=P2P(InpTrailStepPoints);
   if(step<=0.0) step=g_tickSize;

   for(int i=0;i<g_nMainPos;i++)
     {
      double cur=g_mainPos[i].sl;
      if(cur==0.0 || (want-cur)*g_dir>=step-g_tickSize*0.5)
         ModifySL(g_mainPos[i],want);
     }
   for(int i=0;i<g_nAddPos;i++)
     {
      double cur=g_addPos[i].sl;
      if(cur==0.0 || (want-cur)*g_dir>=step-g_tickSize*0.5)
         ModifySL(g_addPos[i],want);
     }
  }

//==================================================================
//  A G A I N S T   S I D E   ( G R I D  +  P R O T E C T I O N )
//==================================================================
//--- price of the protection leg that belongs to layer with entry 'layerPrice'
double LegPriceForLayer(const double layerPrice)
  { return(layerPrice-g_dir*P2P(InpProtectOffsetPoints)); }

void EnsureProtectionLeg(const int layerIdx,const double layerPrice,const double lot)
  {
   if(!InpUseProtectionLeg) return;
   if(layerIdx<2) return;
   if(g_legArmed>=layerIdx) return;          // already armed once, never re-arm

   double price=LegPriceForLayer(layerPrice);

   //--- price is already far beyond the leg level -> skip this leg
   if(PricePassedAgainst(price-g_dir*P2P(InpGridStepPoints*0.5),g_dir))
     { SetLegArmed(layerIdx); return; }

   double sl=0.0,tp=0.0;
   int legDir=-g_dir;
   if(InpLegFixedSLPoints>0.0) sl=price-legDir*P2P(InpLegFixedSLPoints);
   if(InpLegFixedTPPoints>0.0) tp=price+legDir*P2P(InpLegFixedTPPoints);

   string tag=StringFormat("KV1|L|%d",layerIdx);

   if(PricePassedAgainst(price,g_dir))
     {
      if(MktTryOk() && OpenMarket(legDir,lot,g_magLeg,tag,sl,tp)) SetLegArmed(layerIdx);
      return;
     }
   if(PlacePending(legDir,price,lot,g_magLeg,tag,sl,tp)) SetLegArmed(layerIdx);
  }

void EnsureGridLayer()
  {
   if(!InpUseRecovery) return;
   if(g_dir==0 || g_worstMain<=0.0) return;

   //--- a layer is already armed and waiting -> only make sure its leg exists
   if(g_nMainPend>0)
     {
      int idx=g_nMainPos+1;
      EnsureProtectionLeg(idx,g_mainPend[0].price,g_mainPend[0].lot);
      return;
     }

   if(g_nMainPos>=InpMaxLayers) return;

   int nextIdx=g_nMainPos+1;
   double layerPrice;

   if(nextIdx<=2)
     {
      //--- 2nd layer sits one grid step against the initial trade
      layerPrice=g_worstMain-g_dir*P2P(InpGridStepPoints);
     }
   else
     {
      //--- deeper layers sit one grid step beyond the previous protection leg
      double prevLegPrice=LegPriceForLayer(g_worstMain);
      bool legDone=false;
      if(!InpUseProtectionLeg) legDone=true;                          // pure grid mode
      if(g_nLegPend==0 && g_legArmed>=nextIdx-1) legDone=true;        // armed leg already filled
      if(PricePassedAgainst(prevLegPrice,g_dir)) legDone=true;        // price traded through it
      if(!legDone) return;                                            // wait for the leg first
      layerPrice=prevLegPrice-g_dir*P2P(InpGridStepPoints);
     }

   double lot=NextLot(g_worstMainLot>0.0?g_worstMainLot:InpBaseLot);
   string tag=StringFormat("KV1|M|%d",nextIdx);

   if(PricePassedAgainst(layerPrice,g_dir))
     {
      if(MktTryOk() && OpenMarket(g_dir,lot,g_magMain,tag)) SetLayerArmed(nextIdx);
      EnsureProtectionLeg(nextIdx,layerPrice,lot);
      return;
     }

   if(PlacePending(g_dir,layerPrice,lot,g_magMain,tag))
     {
      SetLayerArmed(nextIdx);
      EnsureProtectionLeg(nextIdx,layerPrice,lot);
     }
  }

//--- protection legs are runners: they trail and bank profit while price keeps going
void ManageLegTrail()
  {
   if(!InpLegUseTrail) return;
   for(int i=0;i<g_nLegPos;i++)
     {
      int d=g_legPos[i].dir;
      double px=ClosePriceFor(d);
      double gain=Pts((px-g_legPos[i].price)*d);
      if(gain<InpLegTrailStartPoints) continue;

      double want=NormPrice(px-d*P2P(InpLegTrailDistPoints));
      double cur=g_legPos[i].sl;
      double step=P2P(InpLegTrailStepPoints);
      if(step<=0.0) step=g_tickSize;

      bool better=(cur==0.0 || (want-cur)*d>=step-g_tickSize*0.5);
      if(!better) continue;
      //--- never trail into a loss
      if((want-g_legPos[i].price)*d<0.0) continue;
      ModifySL(g_legPos[i],want);
     }
  }

//==================================================================
//  W E I G H T E D   B A S K E T   T P
//==================================================================
double BasketTargetMoney()
  {
   double t=InpBasketTargetMoney;
   if(t<=0.0) t=P2P(InpAutoTargetPoints)*InpBaseLot*g_vpu;
   if(InpTargetGrowthPerLayer>0.0 && g_nMainPos>1)
      t*=(1.0+InpTargetGrowthPerLayer/100.0*(g_nMainPos-1));
   return(t);
  }

//--- price where (floating + already realized) == target money
double BasketTPPrice(const double target)
  {
   if(MathAbs(g_netLot)<g_lotMin*0.5) return(0.0);
   double x=(g_wSum+(target-g_realized)/g_vpu)/g_netLot;
   return(NormPrice(x));
  }

void ManageBasketExit()
  {
   double target=BasketTargetMoney();
   double money=g_floating+g_realized;

   if(money>=target && (g_nMainPos+g_nAddPos+g_nLegPos)>0)
     {
      CloseAllPositions(StringFormat("basket target hit %.2f >= %.2f",money,target));
      DeleteAllOurPendings("basket closed");
      return;
     }

   if(InpMaxBasketLossMoney>0.0 && money<=-InpMaxBasketLossMoney)
     {
      CloseAllPositions(StringFormat("emergency basket loss %.2f",money));
      DeleteAllOurPendings("emergency close");
      return;
     }

   double tpPrice=BasketTPPrice(target);

   //--- a real TP can only be exact while no opposite leg is open
   bool hard=(InpPlaceHardTP && g_nLegPos==0 && tpPrice>0.0);
   for(int i=0;i<g_nMainPos;i++) ModifyTP(g_mainPos[i],hard?tpPrice:0.0);
   for(int i=0;i<g_nAddPos;i++)  ModifyTP(g_addPos[i] ,hard?tpPrice:0.0);

   if(InpShowTPLine) DrawLevel("KV1_lvlTP",tpPrice,clrDodgerBlue,STYLE_SOLID,"basket TP");
  }

//==================================================================
//  M O D E   H A N D L E R S
//==================================================================
void HandleWait()
  {
   //--- initial trade only: favour leg AND recovery leg are both armed
   EnsureAddonLeg();
   EnsureGridLayer();
  }

void HandlePyramid()
  {
   //--- price went our way first -> pyramid + trailing owns the cycle
   DeletePendings(g_mainPend,g_nMainPend,"pyramid engaged");
   DeletePendings(g_legPend ,g_nLegPend ,"pyramid engaged");
   EnsureAddonLeg();
   ManagePyramidStop();
  }

void HandleRecovery()
  {
   //--- price went against us -> grid + protection legs + weighted TP own the cycle
   DeletePendings(g_addPend,g_nAddPend,"recovery engaged");

   //--- pyramid stops must not cut the basket
   for(int i=0;i<g_nMainPos;i++) if(g_mainPos[i].sl!=0.0) trade.PositionModify(g_mainPos[i].ticket,0.0,g_mainPos[i].tp);
   for(int i=0;i<g_nAddPos;i++)  if(g_addPos[i].sl !=0.0) trade.PositionModify(g_addPos[i].ticket ,0.0,g_addPos[i].tp);

   EnsureGridLayer();
   ManageLegTrail();
   ManageBasketExit();
  }

//==================================================================
//  E N T R Y
//==================================================================
bool EntryFiltersOk()
  {
   if(!InpEnableTrading || g_halted) return(false);
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)==0) return(false);
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)==0) return(false);
   if(MQLInfoInteger(MQL_TRADE_ALLOWED)==0) return(false);
   if(SpreadPoints()>InpMaxSpreadPoints) return(false);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(),dt);
   if(InpUseSessionFilter)
     {
      if(InpSessionStartHour<=InpSessionEndHour)
        { if(dt.hour<InpSessionStartHour || dt.hour>=InpSessionEndHour) return(false); }
      else
        { if(dt.hour<InpSessionStartHour && dt.hour>=InpSessionEndHour) return(false); }
     }
   if(InpCloseAllOnFriday && dt.day_of_week==5 && dt.hour>=InpFridayCloseHour) return(false);

   //--- cooldown after the previous cycle
   if(g_lastCycleEnd>0 && InpCooldownBars>0)
     {
      int secs=PeriodSeconds(InpSignalTF)*InpCooldownBars;
      if(TimeCurrent()-g_lastCycleEnd<secs) return(false);
     }
   //--- one entry per bar maximum
   datetime bt=iTime(g_sym,InpSignalTF,0);
   if(bt==g_lastEntryBar) return(false);
   return(true);
  }

void TryOpenNewCycle()
  {
   if(!EntryFiltersOk()) return;
   int dir=EntryDirection();
   if(dir==0) return;

   if(OpenMarket(dir,InpBaseLot,g_magMain,"KV1|M|1"))
     {
      g_lastEntryBar=iTime(g_sym,InpSignalTF,0);
      StartCycle();
      ScanState();
      EnsureAddonLeg();
      EnsureGridLayer();
     }
  }

//==================================================================
//  S A F E T Y
//==================================================================
bool SafetyChecks()
  {
   if(InpEquityStopPct>0.0)
     {
      double bal=MathMax(g_startBalance,AccountInfoDouble(ACCOUNT_BALANCE));
      double eq=AccountInfoDouble(ACCOUNT_EQUITY);
      if(bal>0.0 && eq<bal*(1.0-InpEquityStopPct/100.0))
        {
         CloseAllPositions("equity stop");
         DeleteAllOurPendings("equity stop");
         Halt(StringFormat("equity %.2f below %.1f%% of %.2f",eq,InpEquityStopPct,bal));
         return(false);
        }
     }

   if(InpCloseAllOnFriday)
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      if(dt.day_of_week==5 && dt.hour>=InpFridayCloseHour &&
         (g_nMainPos+g_nAddPos+g_nLegPos+g_nMainPend+g_nAddPend+g_nLegPend)>0)
        {
         CloseAllPositions("friday flat");
         DeleteAllOurPendings("friday flat");
         return(false);
        }
     }
   return(true);
  }

//--- in pyramid mode all positions carry the same SL: if one got stopped, flatten the rest
void PyramidStopGuard()
  {
   int total=g_nMainPos+g_nAddPos+g_nLegPos;
   if(g_prevMode==MODE_PYRAMID && total>0 && total<g_prevPosTotal && g_mode!=MODE_RECOVERY)
     {
      CloseAllPositions("trail SL hit - flatten cycle");
      DeleteAllOurPendings("trail SL hit");
      ScanState();
     }
  }

//==================================================================
//  P A N E L
//==================================================================
void DrawLevel(const string name,const double price,const color clr,
               const int style,const string txt)
  {
   if(price<=0.0) { ObjectDelete(0,name); return; }
   if(ObjectFind(0,name)<0)
     {
      ObjectCreate(0,name,OBJ_HLINE,0,0,price);
      ObjectSetInteger(0,name,OBJPROP_WIDTH,1);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
     }
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetString(0,name,OBJPROP_TEXT,txt);
  }

void DrawPanel()
  {
   if(!InpShowPanel) { Comment(""); return; }

   double target=BasketTargetMoney();
   double money=g_floating+g_realized;
   double tpPrice=(g_mode==MODE_RECOVERY?BasketTPPrice(target):0.0);

   string nextLayer="-";
   if(g_nMainPend>0)
      nextLayer=StringFormat("%s (%.2f lot)",DoubleToString(g_mainPend[0].price,g_digits),g_mainPend[0].lot);
   string nextLeg="-";
   if(g_nLegPend>0)
      nextLeg=StringFormat("%s (%.2f lot)",DoubleToString(g_legPend[0].price,g_digits),g_legPend[0].lot);
   string nextAdd="-";
   if(g_nAddPend>0)
      nextAdd=StringFormat("%s (%.2f lot)",DoubleToString(g_addPend[0].price,g_digits),g_addPend[0].lot);

   double slShown=0.0;
   if(g_nMainPos>0) slShown=g_mainPos[0].sl;

   string s="";
   s+="============ KRISH V1 AUTO ============\n";
   s+=StringFormat("%s  spread %.0f pts  digits %d  pointAdj %.0f\n",
                   g_sym,SpreadPoints(),g_digits,g_padj);
   s+=StringFormat("PROB  UP %.1f%%  |  DOWN %.1f%%   ADX %.1f   signal %s\n",
                   g_probUp,100.0-g_probUp,g_adx,DirName(EntryDirection()));
   s+=StringFormat("factors: %s\n",g_sigNote);
   s+="---------------------------------------\n";
   s+=StringFormat("MODE  %s   dir %s\n",ModeName(g_mode),DirName(g_dir));
   s+=StringFormat("layers %d/%d   add-ons %d/%d   legs %d\n",
                   g_nMainPos,InpMaxLayers,g_nAddPos,InpMaxAddons,g_nLegPos);
   s+=StringFormat("lots  main %.2f   legs %.2f   net %.2f   deepest layer %.2f\n",
                   g_sumMainLot,g_sumLegLot,g_netLot,g_worstMainLot);
   s+=StringFormat("money floating %.2f + realized %.2f = %.2f   target %.2f\n",
                   g_floating,g_realized,money,target);
   if(g_mode==MODE_RECOVERY)
      s+=StringFormat("weighted basket TP  %s\n",(tpPrice>0.0?DoubleToString(tpPrice,g_digits):"n/a (fully hedged)"));
   if(g_mode==MODE_PYRAMID || g_mode==MODE_WAIT)
      s+=StringFormat("pyramid SL  %s\n",(slShown>0.0?DoubleToString(slShown,g_digits):"none yet"));
   s+=StringFormat("next add-on   %s\n",nextAdd);
   s+=StringFormat("next layer    %s\n",nextLayer);
   s+=StringFormat("next leg      %s\n",nextLeg);
   if(g_halted) s+="*** HALTED (safety) ***\n";
   s+="=======================================";
   Comment(s);

   if(InpShowTPLine)
     {
      DrawLevel("KV1_lvlTP",tpPrice,clrDodgerBlue,STYLE_SOLID,"basket TP");
      DrawLevel("KV1_lvlLayer",(g_nMainPend>0?g_mainPend[0].price:0.0),clrOrange,STYLE_DASH,"next layer");
      DrawLevel("KV1_lvlLeg",(g_nLegPend>0?g_legPend[0].price:0.0),clrRed,STYLE_DOT,"protection leg");
      DrawLevel("KV1_lvlAdd",(g_nAddPend>0?g_addPend[0].price:0.0),clrLime,STYLE_DASH,"next add-on");
      DrawLevel("KV1_lvlSL",slShown,clrMagenta,STYLE_DASHDOT,"trail SL");
     }
  }

//==================================================================
//  M A I N   T I C K
//==================================================================
void OnTick()
  {
   UpdateSignalOnNewBar();
   ScanState();

   if(!SafetyChecks()) { DrawPanel(); return; }

   PyramidStopGuard();

   int total=g_nMainPos+g_nAddPos+g_nLegPos;

   if(total==0)
     {
      if(g_nMainPend+g_nAddPend+g_nLegPend>0)
         DeleteAllOurPendings("no position left");
      if(g_cycleStart>0)
        {
         EndCycle("flat");
         ScanState();
        }
      TryOpenNewCycle();
     }
   else
     {
      if(g_cycleStart<=0) StartCycle(true);   // restart safety: adopt the live basket

      switch(g_mode)
        {
         case MODE_WAIT:     HandleWait();     break;
         case MODE_PYRAMID:  HandlePyramid();  break;
         case MODE_RECOVERY: HandleRecovery(); break;
        }
     }

   g_prevPosTotal=g_nMainPos+g_nAddPos+g_nLegPos;
   g_prevMode=g_mode;

   DrawPanel();
  }
