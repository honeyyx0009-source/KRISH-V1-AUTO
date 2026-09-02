//+------------------------------------------------------------------+
//|                                               KRISH_V1_AUTO.mq5  |
//|                         GOLD (XAUUSD) adaptive probability robot  |
//|                                                                  |
//|  1) PREDICTION ENGINE (13 factors, 3 timeframes) decides the      |
//|     probability of UP vs DOWN. A cycle starts only when one side  |
//|     is above InpMinProbability.                                   |
//|     The very first trade of a cycle carries the comment           |
//|     "KV1-INITIAL-BUY" / "KV1-INITIAL-SELL".                        |
//|                                                                  |
//|  2) FAVOUR SIDE = ADD-ON PYRAMID                                  |
//|     base lot, +200 pts -> add-on with the same lot (leg is armed  |
//|     in advance), basket SL 100 pts behind the newest add-on and   |
//|     then step-wise trailing. Trail SL hit -> everything exits.    |
//|                                                                  |
//|  3) AGAINST SIDE = GRID + OPPOSITE PROTECTION LEGS                |
//|     - next main layer 800 pts against the grid edge, lot grows    |
//|       mildly (1.3x default)                                       |
//|     - protection leg 80 pts beyond that layer, and its lot is     |
//|       sized on the TOTAL open lot of the grid side (default mode  |
//|       keeps opposite total = grid total)                          |
//|     - leg fills -> next main layer is armed 800 pts beyond it,    |
//|       together with its own protection leg                        |
//|                                                                  |
//|  4) GROUP WEIGHTED TP (alternating)                                |
//|     Only ONE side owns the TP at a time (the "grid side").        |
//|     Its TP is the weighted price where THAT GROUP alone closes    |
//|     in profit (never in loss). When it is hit, every position of  |
//|     that side closes; the opposite positions that remain become   |
//|     the new grid side, the TP shifts to them, and the grid        |
//|     continues in that direction. TP keeps alternating like this   |
//|     until the cycle is completely flat.                           |
//+------------------------------------------------------------------+
#property copyright "KRISH V1 AUTO"
#property link      "https://github.com/honeyyx0009-source/KRISH-V1-AUTO"
#property version   "2.00"
#property description "Gold: probability engine + add-on pyramid + grid with protection legs + alternating group weighted TP"

#include <Trade\Trade.mqh>

//==================================================================
//  E N U M S
//==================================================================
enum ENUM_LEGLOT
  {
   LEGLOT_BALANCE=0,   // Balance: opposite total = grid total (default)
   LEGLOT_FULL=1,      // Full: every leg = full grid side total
   LEGLOT_LAYER=2      // Layer: only that single layer lot
  };

enum ENUM_GTPMODE
  {
   GTP_MONEY=0,        // Money target on the group
   GTP_POINTS=1        // Points beyond the group weighted average
  };

enum ENUM_EXITMODE
  {
   EXIT_SMART=0,       // Smart: whole basket first, flip only when cheap or unavoidable
   EXIT_GROUP_FLIP=1,  // Always flip the TP side (v2 behaviour)
   EXIT_BASKET=2       // Never flip: only close both sides together
  };

//==================================================================
//  I N P U T S
//==================================================================
input group "===== 1. GENERAL ====="
input long    InpMagic                 = 260901;   // Magic base (magic, magic+1, magic+2)
input bool    InpEnableTrading          = true;     // Allow new cycles
input bool    InpAutoPointAdjust        = true;     // Auto fix points on 3/5 digit brokers
input double  InpMaxSpreadPoints        = 60;       // Max spread (points) for new entries
input ulong   InpSlippagePoints         = 50;       // Slippage / deviation (points)
input bool    InpShowPanel              = true;     // Show info panel on chart

input group "===== 2. PREDICTION ENGINE ====="
input int     InpSignalMode             = 0;        // 0=engine, 1=force BUY, 2=force SELL
input ENUM_TIMEFRAMES InpSignalTF       = PERIOD_M15; // Working timeframe
input ENUM_TIMEFRAMES InpMidTF          = PERIOD_H1;  // Confirmation timeframe
input ENUM_TIMEFRAMES InpBigTF          = PERIOD_H4;  // Master trend timeframe
input double  InpMinProbability         = 60.0;     // Min probability % to open a cycle
input double  InpMinADX                 = 12.0;     // Min ADX (0 = off)
input int     InpCooldownBars           = 2;        // Wait bars after a cycle closes

input group "===== 3. LOT PROGRESSION ====="
input double  InpBaseLot                = 0.01;     // Base lot (initial trade + add-ons)
input double  InpLotMultiplier          = 1.3;      // Grid layer lot multiplier (mild)
input double  InpLotAddStep             = 0.00;     // Extra additive lot per layer
input double  InpMaxLot                 = 1.00;     // Single order lot cap (0 = broker max)

input group "===== 4. FAVOUR SIDE (ADD-ON PYRAMID) ====="
input bool    InpUseAddon               = true;     // Enable add-on pyramid
input double  InpAddonStepPoints        = 200;      // Points in favour for the next add-on
input double  InpAddonLot               = 0.00;     // Add-on lot (0 = same as base lot)
input int     InpMaxAddons              = 15;       // Max add-on positions
input double  InpAddonSLBufferPoints    = 100;      // SL this far behind the newest add-on
input bool    InpUseTrail               = true;     // Step-wise trailing after the 2nd position
input double  InpTrailDistancePoints    = 150;      // Trail distance from price
input double  InpTrailStepPoints        = 50;       // Trail step

input group "===== 5. AGAINST SIDE (GRID + PROTECTION LEGS) ====="
input bool    InpUseRecovery            = true;     // Enable grid recovery
input double  InpGridStepPoints         = 800;      // Distance to the next grid layer
input int     InpMaxLayers              = 8;        // Max positions on the grid side
input bool    InpUseProtectionLeg       = true;     // Place the opposite protection leg
input double  InpProtectOffsetPoints    = 80;       // Leg distance beyond the layer (50-100)
input ENUM_LEGLOT InpLegLotMode         = LEGLOT_BALANCE; // Protection leg lot rule
input bool    InpLegUseTrail            = false;    // Trail the protection legs (breaks the hedge)
input double  InpLegTrailStartPoints    = 300;      // Leg profit needed before trailing
input double  InpLegTrailDistPoints     = 250;      // Leg trail distance
input double  InpLegTrailStepPoints     = 100;      // Leg trail step
input double  InpLegFixedSLPoints       = 0;        // Leg fixed SL (0 = none)
input double  InpLegFixedTPPoints       = 0;        // Leg fixed TP (0 = none)

input group "===== 6. GROUP WEIGHTED TP (alternating) ====="
input ENUM_GTPMODE InpGroupTPMode       = GTP_MONEY;// How the group TP is measured
input double  InpGroupTargetMoney       = 0;        // Money target (0 = auto from base lot)
input double  InpAutoTargetPoints       = 300;      // Auto target: points on base lot
input double  InpGroupTPPoints          = 200;      // Points mode: pts beyond weighted average
input bool    InpPlaceHardTP            = true;     // Put a real TP order on the grid side
input bool    InpShowTPLine             = true;     // Draw TP / level lines

input group "===== 6b. NAKED SIDE PROTECTION (flip safety) ====="
input ENUM_EXITMODE InpExitMode         = EXIT_SMART; // How a cycle is allowed to exit
input double  InpLegHedgePct            = 100;      // Leg lot = this % of the grid side total
input double  InpBasketTargetMoney      = 0;        // Whole basket target (0 = same as group target)
input double  InpMaxNakedLossMoney      = 0;        // Max loss left naked by a flip (0 = 3x target)
input bool    InpGuardSnapToGrid         = true;    // Guard sits on the grid level nearest to price
input double  InpFlipProtectPoints      = 200;      // Max distance of the guard from price
input double  InpFlipGuardPct           = 100;      // Guard leg lot = this % of the naked total
input bool    InpReanchorGridOnGuard     = true;    // Restart the ladder from the guard level

input group "===== 7. SAFETY ====="
input double  InpMaxTotalLot            = 0;        // Stop adding above this total lot (0 = off)
input double  InpMaxBasketLossMoney     = 0;        // Emergency close on this floating loss (0 = off)
input double  InpEquityStopPct          = 0;        // Halt EA if equity drops this % (0 = off)
input bool    InpUseSessionFilter        = false;   // Only open cycles inside a session
input int     InpSessionStartHour        = 1;       // Session start hour (server)
input int     InpSessionEndHour          = 23;      // Session end hour (server)
input bool    InpCloseAllOnFriday        = false;   // Flat everything on Friday
input int     InpFridayCloseHour         = 21;      // Friday close hour (server)

//==================================================================
//  T Y P E S  /  G L O B A L S
//==================================================================
#define MAXREC 400

#define ROLE_MAIN   0     // initial trade + grid layers
#define ROLE_ADDON  1     // pyramid add-ons
#define ROLE_LEG    2     // opposite protection legs

#define MODE_IDLE      0
#define MODE_WAIT      1  // only the initial trade, both legs armed
#define MODE_PYRAMID   2  // add-on side engaged, trailing SL owns the exit
#define MODE_GRID      3  // grid engaged, alternating group weighted TP owns the exit

struct TradeRec
  {
   ulong             ticket;
   int               role;
   int               type;
   int               dir;       // +1 long, -1 short
   double            lot;
   double            price;
   double            sl;
   double            tp;
   double            profit;    // profit + swap (positions only)
   double            swap;
   datetime          time;
  };

CTrade   trade;
string   g_sym;
int      g_digits;
double   g_pt, g_padj, g_tickSize, g_vpu;
double   g_lotMin, g_lotMax, g_lotStep;
long     g_magMain, g_magAddon, g_magLeg;
double   g_stopsDist;

//--- everything we own
TradeRec g_pos[MAXREC];   int g_nPos;
TradeRec g_pend[MAXREC];  int g_nPend;

//--- per direction view (index 0 = long, 1 = short)
int      g_gpIdx[2][MAXREC]; int g_gn[2];      // position indexes
int      g_gqIdx[2][MAXREC]; int g_gqn[2];     // pending indexes
double   g_gLot[2], g_gW[2], g_gProfit[2], g_gSwap[2], g_gqLot[2];
double   g_gEdge[2], g_gEdgeLot[2];            // grid edge (extreme against the group)

//--- role counters
int      g_nMainPos, g_nAddPos, g_nLegPos, g_nAddPend;
int      g_idxOldestMain;

int      g_cycleDir;     // direction of the initial trade
int      g_gridDir;      // side that currently owns the TP
int      g_mode;
bool     g_gridEngaged;
double   g_bestFavour;   // best entry among cycle-direction main+addon
double   g_totalFloat;

int      g_prevPosTotal;
int      g_prevMode;

//--- cycle bookkeeping (persisted -> restart safe)
datetime g_cycleStart;
int      g_layerStep;    // layers armed in the current grid generation
int      g_legStep;      // legs armed in the current grid generation
bool     g_halted;
datetime g_lastCycleEnd;
double   g_startBalance;
double   g_realized;
datetime g_realizedStamp;
int      g_realizedCount;

datetime g_lastMktTry;
datetime g_lastPendFail;

//--- signal cache
double   g_probUp, g_adx;
int      g_sigDir;
string   g_sigNote;
datetime g_sigBar, g_lastEntryBar;

//--- indicator handles
int hEmaF, hEmaS, hEmaMF, hEmaMS, hEmaBF, hEmaBS;
int hAdx, hRsi, hMacd, hAtr, hBands, hStoch;

//--- guard level of the running grid generation (0 = none)
double   g_guardPrice;

//--- terminal global variable names
string gvCS, gvLS, gvGS, gvGD, gvEN, gvGP, gvHALT;

//==================================================================
//  S M A L L   H E L P E R S
//==================================================================
double Squash(const double x) { return(x/(1.0+MathAbs(x))); }
double P2P(const double points) { return(points*g_padj*g_pt); }
double Pts(const double priceDist) { return(priceDist/(g_padj*g_pt)); }
int    DI(const int dir) { return(dir>0?0:1); }

bool IsOurMagic(const long m) { return(m==g_magMain || m==g_magAddon || m==g_magLeg); }

int RoleOfMagic(const long m)
  {
   if(m==g_magMain)  return(ROLE_MAIN);
   if(m==g_magAddon) return(ROLE_ADDON);
   if(m==g_magLeg)   return(ROLE_LEG);
   return(-1);
  }

double Ask() { return(SymbolInfoDouble(g_sym,SYMBOL_ASK)); }
double Bid() { return(SymbolInfoDouble(g_sym,SYMBOL_BID)); }
double ClosePriceFor(const int d) { return(d>0 ? Bid() : Ask()); }
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

double NextLot(const double prev)
  {
   double l=prev*InpLotMultiplier+InpLotAddStep;
   l=NormLot(l);
   if(l<=prev) l=NormLot(prev+g_lotStep);
   return(l);
  }

//--- has price already traded through 'level' on the losing side of dir?
bool PricePassedAgainst(const double level,const int dir)
  { return(dir>0 ? Bid()<=level : Ask()>=level); }

//--- has price already traded through 'level' on the winning side of dir?
bool PricePassedFavour(const double level,const int dir)
  { return(dir>0 ? Ask()>=level : Bid()<=level); }

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
      case MODE_IDLE:    return("IDLE");
      case MODE_WAIT:    return("WAIT (both legs armed)");
      case MODE_PYRAMID: return("PYRAMID (add-on + trail)");
      case MODE_GRID:    return("GRID (layers + legs + group TP)");
     }
   return("?");
  }

void SaveSteps()
  {
   GlobalVariableSet(gvLS,(double)g_layerStep);
   GlobalVariableSet(gvGS,(double)g_legStep);
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
   gvLS  ="KV1_"+(string)InpMagic+"_LS";
   gvGS  ="KV1_"+(string)InpMagic+"_GS";
   gvGD  ="KV1_"+(string)InpMagic+"_GD";
   gvEN  ="KV1_"+(string)InpMagic+"_EN";
   gvGP  ="KV1_"+(string)InpMagic+"_GP";
   gvHALT="KV1_"+(string)InpMagic+"_HALT";

   g_cycleStart =(datetime)(long)GlobalVariableGet(gvCS);
   g_layerStep  =(int)GlobalVariableGet(gvLS);
   g_legStep    =(int)GlobalVariableGet(gvGS);
   g_gridDir    =(int)GlobalVariableGet(gvGD);
   g_guardPrice =GlobalVariableGet(gvGP);
   g_gridEngaged=(GlobalVariableCheck(gvEN) && GlobalVariableGet(gvEN)>0.0);
   g_halted     =(GlobalVariableCheck(gvHALT) && GlobalVariableGet(gvHALT)>0.0);
   g_startBalance=AccountInfoDouble(ACCOUNT_BALANCE);

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
      Print("KV1: indicator handle creation failed");
      return(INIT_FAILED);
     }

   PrintFormat("KV1 v2 started on %s | digits=%d point=%.5f adj=%.0f money per 1.0 price per 1 lot=%.2f",
               g_sym,g_digits,g_pt,g_padj,g_vpu);
   PrintFormat("KV1 distances -> add-on %.0f pts=%.2f | grid %.0f pts=%.2f | leg offset %.0f pts=%.2f",
               InpAddonStepPoints,P2P(InpAddonStepPoints),
               InpGridStepPoints,P2P(InpGridStepPoints),
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
   if(InpShowPanel) { ScanState(); DrawPanel(); }
  }

//==================================================================
//  S T A T E   S C A N N E R
//==================================================================
void ScanState()
  {
   g_nPos=0; g_nPend=0;
   g_nMainPos=0; g_nAddPos=0; g_nLegPos=0; g_nAddPend=0;
   g_idxOldestMain=-1;
   g_totalFloat=0;
   g_cycleDir=0; g_bestFavour=0;

   for(int k=0;k<2;k++)
     {
      g_gn[k]=0; g_gqn[k]=0; g_gqLot[k]=0;
      g_gLot[k]=0; g_gW[k]=0; g_gProfit[k]=0; g_gSwap[k]=0;
      g_gEdge[k]=0; g_gEdgeLot[k]=0;
     }

   g_stopsDist=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_STOPS_LEVEL)*g_pt;
   double frz=(double)SymbolInfoInteger(g_sym,SYMBOL_TRADE_FREEZE_LEVEL)*g_pt;
   if(frz>g_stopsDist) g_stopsDist=frz;
   if(g_stopsDist<=0.0) g_stopsDist=2.0*g_pt;

   //--- positions ---------------------------------------------------
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_sym) continue;
      int role=RoleOfMagic(PositionGetInteger(POSITION_MAGIC));
      if(role<0) continue;
      if(g_nPos>=MAXREC) break;

      TradeRec r;
      r.ticket=tk;
      r.role  =role;
      r.type  =(int)PositionGetInteger(POSITION_TYPE);
      r.dir   =(r.type==POSITION_TYPE_BUY?1:-1);
      r.lot   =PositionGetDouble(POSITION_VOLUME);
      r.price =PositionGetDouble(POSITION_PRICE_OPEN);
      r.sl    =PositionGetDouble(POSITION_SL);
      r.tp    =PositionGetDouble(POSITION_TP);
      r.swap  =PositionGetDouble(POSITION_SWAP);
      r.profit=PositionGetDouble(POSITION_PROFIT)+r.swap;
      r.time  =(datetime)PositionGetInteger(POSITION_TIME);

      int idx=g_nPos;
      g_pos[idx]=r;
      g_nPos++;

      int d=DI(r.dir);
      g_gpIdx[d][g_gn[d]]=idx;
      g_gn[d]++;
      g_gLot[d]   +=r.lot;
      g_gW[d]     +=r.lot*r.price;
      g_gProfit[d]+=r.profit;
      g_gSwap[d]  +=r.swap;
      //--- grid edge = extreme entry against that direction
      if(g_gEdge[d]==0.0 || (r.dir>0 ? r.price<g_gEdge[d] : r.price>g_gEdge[d]))
        { g_gEdge[d]=r.price; g_gEdgeLot[d]=r.lot; }

      g_totalFloat+=r.profit;

      if(role==ROLE_MAIN)
        {
         g_nMainPos++;
         if(g_idxOldestMain<0 || r.time<g_pos[g_idxOldestMain].time) g_idxOldestMain=idx;
        }
      if(role==ROLE_ADDON) g_nAddPos++;
      if(role==ROLE_LEG)   g_nLegPos++;
     }

   //--- pending orders ---------------------------------------------
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      ulong tk=OrderGetTicket(i);
      if(tk==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=g_sym) continue;
      int role=RoleOfMagic(OrderGetInteger(ORDER_MAGIC));
      if(role<0) continue;
      int ot=(int)OrderGetInteger(ORDER_TYPE);
      if(ot==ORDER_TYPE_BUY || ot==ORDER_TYPE_SELL) continue;
      if(g_nPend>=MAXREC) break;

      TradeRec r;
      r.ticket=tk;
      r.role  =role;
      r.type  =ot;
      r.dir   =((ot==ORDER_TYPE_BUY_STOP || ot==ORDER_TYPE_BUY_LIMIT)?1:-1);
      r.lot   =OrderGetDouble(ORDER_VOLUME_CURRENT);
      r.price =OrderGetDouble(ORDER_PRICE_OPEN);
      r.sl    =OrderGetDouble(ORDER_SL);
      r.tp    =OrderGetDouble(ORDER_TP);
      r.profit=0; r.swap=0;
      r.time  =(datetime)OrderGetInteger(ORDER_TIME_SETUP);

      int idx=g_nPend;
      g_pend[idx]=r;
      g_nPend++;

      if(role==ROLE_ADDON) g_nAddPend++;
      else
        {
         int d=DI(r.dir);
         g_gqIdx[d][g_gqn[d]]=idx;
         g_gqn[d]++;
         g_gqLot[d]+=r.lot;
        }
     }

   //--- cycle direction = direction of the oldest MAIN position ------
   if(g_idxOldestMain>=0) g_cycleDir=g_pos[g_idxOldestMain].dir;
   else if(g_nPos>0)      g_cycleDir=g_pos[0].dir;
   else if(g_nPend>0)     g_cycleDir=g_pend[0].dir;

   //--- best (most in favour) entry of the cycle side (pyramid SL) ---
   for(int i=0;i<g_nPos;i++)
     {
      if(g_pos[i].role==ROLE_LEG) continue;
      if(g_pos[i].dir!=g_cycleDir) continue;
      double p=g_pos[i].price;
      if(g_bestFavour==0.0 || (g_cycleDir>0 ? p>g_bestFavour : p<g_bestFavour)) g_bestFavour=p;
     }

   //--- which side owns the TP right now ----------------------------
   int derived=0;
   if(g_gn[0]>0 && g_gn[1]==0)      derived=1;
   else if(g_gn[1]>0 && g_gn[0]==0) derived=-1;
   else if(g_gn[0]>0 && g_gn[1]>0)
     {
      derived=g_gridDir;
      if(derived==0) derived=(g_cycleDir!=0?g_cycleDir:(g_gLot[0]>=g_gLot[1]?1:-1));
     }

   if(derived!=0 && derived!=g_gridDir)
     {
      bool flip=(g_gridDir!=0);
      g_gridDir=derived;
      GlobalVariableSet(gvGD,(double)g_gridDir);
      if(flip)
        {
         //--- the old grid side is gone: start a fresh generation
         g_layerStep=0; g_legStep=0; SaveSteps();
         SetGuardPrice(0.0);
         DeleteAllOurPendings("TP shifted to the other side");
         PrintFormat("KV1: >>> TP side shifted to %s <<<",DirName(g_gridDir));
        }
     }

   //--- mode --------------------------------------------------------
   int totalPos=g_nPos;
   bool gridNow=(g_nLegPos>0 || g_nMainPos>=2 || (g_gn[0]>0 && g_gn[1]>0));
   if(gridNow && !g_gridEngaged && totalPos>0)
     {
      g_gridEngaged=true;
      GlobalVariableSet(gvEN,1.0);
     }

   if(totalPos==0 && g_nPend==0)     g_mode=MODE_IDLE;
   else if(totalPos==0)              g_mode=MODE_IDLE;
   else if(g_gridEngaged || gridNow) g_mode=MODE_GRID;
   else if(g_nAddPos>0)              g_mode=MODE_PYRAMID;
   else                              g_mode=MODE_WAIT;

   RefreshRealized(totalPos);
  }

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
      if(HistoryDealGetInteger(dl,DEAL_ENTRY)==DEAL_ENTRY_IN)
        { g_realized+=HistoryDealGetDouble(dl,DEAL_COMMISSION); continue; }
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

   g_adx=adxM[2];
   double trendW=(g_adx-15.0)/20.0;
   if(trendW<0.0) trendW=0.0;
   if(trendW>1.0) trendW=1.0;
   double rangeW=1.0-trendW;

   double f1=Squash((emaF[4]-emaS[4])/A);                       // working TF trend
   score+=f1*(1.6*(0.4+0.6*trendW)); wsum+=1.6*(0.4+0.6*trendW);

   double f2=Squash((emaMF[2]-emaMS[2])/(A*1.5));               // mid TF trend
   score+=f2*1.3; wsum+=1.3;

   double f3=Squash((emaBF[2]-emaBS[2])/(A*2.5));               // big TF trend
   score+=f3*1.5; wsum+=1.5;

   double f4=Squash((emaF[4]-emaF[1])/A);                       // fast EMA slope
   score+=f4*1.0; wsum+=1.0;

   double diSum=adxP[2]+adxN[2];                                // DI balance
   double f5=(diSum>0.0 ? (adxP[2]-adxN[2])/diSum : 0.0);
   score+=f5*(1.2*(0.3+0.7*trendW)); wsum+=1.2*(0.3+0.7*trendW);

   double h0=macM[3]-macS[3];                                   // MACD hist + slope
   double h1=macM[1]-macS[1];
   double f6=0.6*Squash(h0/(A*0.30))+0.4*Squash((h0-h1)/(A*0.15));
   score+=f6*1.2; wsum+=1.2;

   double f7=(rsi[2]-50.0)/50.0;                                // RSI momentum
   score+=f7*(0.9*trendW); wsum+=0.9*trendW;

   double f8=0.0;                                               // RSI mean reversion
   if(rsi[2]>65.0 || rsi[2]<35.0) f8=-(rsi[2]-50.0)/50.0;
   score+=f8*(1.0*rangeW); wsum+=1.0*rangeW;

   double halfBand=MathMax(bbU[1]-bbM[1],g_pt);                 // Bollinger position
   double pctB=(cl-bbM[1])/halfBand;
   double f9=(-Squash(pctB)*rangeW)+(Squash(pctB*0.7)*trendW);
   score+=f9*0.9; wsum+=0.9;

   double f10=0.5*((stK[2]-50.0)/50.0)+0.5*Squash((stK[2]-stD[2])/10.0);
   score+=f10*0.6; wsum+=0.6;

   double f11=Squash((cl-rt[last-10].close)/(A*3.0));           // raw momentum
   score+=f11*1.0; wsum+=1.0;

   double hh=rt[last].high, ll=rt[last].low;                    // breakout position
   for(int i=last-19;i<=last;i++)
     { hh=MathMax(hh,rt[i].high); ll=MathMin(ll,rt[i].low); }
   double rng=MathMax(hh-ll,g_pt);
   double f12=Squash(((cl-ll)/rng-0.5)*2.5);
   score+=f12*(0.9*(0.3+0.7*trendW)); wsum+=0.9*(0.3+0.7*trendW);

   double body=0.0;                                             // candle structure
   for(int i=last-2;i<=last;i++)
     {
      double rr=MathMax(rt[i].high-rt[i].low,g_pt);
      body+=(rt[i].close-rt[i].open)/rr;
     }
   double f13=Squash(body/1.5);
   score+=f13*0.7; wsum+=0.7;

   if(wsum<=0.0) return(false);
   double total=score/wsum;
   g_probUp=50.0+50.0*total;
   if(g_probUp<1.0)  g_probUp=1.0;
   if(g_probUp>99.0) g_probUp=99.0;

   double probDn=100.0-g_probUp;
   g_sigDir=0;
   if(InpMinADX<=0.0 || g_adx>=InpMinADX)
     {
      if(g_probUp>=InpMinProbability)    g_sigDir=1;
      else if(probDn>=InpMinProbability) g_sigDir=-1;
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
      PrintFormat("KV1: pending %s %.2f @ %s FAILED ret=%d %s",
                  EnumToString(ot),lot,DoubleToString(price,g_digits),
                  trade.ResultRetcode(),trade.ResultRetcodeDescription());
     }
   else
      PrintFormat("KV1: pending %s %.2f @ %s [%s]",
                  EnumToString(ot),lot,DoubleToString(price,g_digits),tag);
   return(ok);
  }

double g_lastFillPrice=0;

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
   g_lastFillPrice=(ok?trade.ResultPrice():0.0);
   if(g_lastFillPrice<=0.0) g_lastFillPrice=px;
   if(!ok)
      PrintFormat("KV1: market %s %.2f FAILED ret=%d %s",DirName(dir),lot,
                  trade.ResultRetcode(),trade.ResultRetcodeDescription());
   else
      PrintFormat("KV1: market %s %.2f @ %s [%s]",DirName(dir),lot,
                  DoubleToString(g_lastFillPrice,g_digits),tag);
   return(ok);
  }

void DeleteAllOurPendings(const string why)
  {
   for(int i=0;i<g_nPend;i++)
      if(trade.OrderDelete(g_pend[i].ticket))
         PrintFormat("KV1: pending #%I64u deleted (%s)",g_pend[i].ticket,why);
  }

void DeletePendingsByRole(const int role,const string why)
  {
   for(int i=0;i<g_nPend;i++)
      if(g_pend[i].role==role && trade.OrderDelete(g_pend[i].ticket))
         PrintFormat("KV1: pending #%I64u deleted (%s)",g_pend[i].ticket,why);
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

int CloseDirection(const int dir,const string why)
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
         int d=(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY?1:-1);
         if(d!=dir) continue;
         if(trade.PositionClose(tk,InpSlippagePoints)) closed++;
         else all=false;
        }
      if(all) break;
      Sleep(150);
     }
   if(closed>0) PrintFormat("KV1: closed %d %s position(s) - %s",closed,DirName(dir),why);
   return(closed);
  }

//==================================================================
//  C Y C L E   B O O K K E E P I N G
//==================================================================
void StartCycle(const bool adopt=false)
  {
   if(adopt)
     {
      datetime t0=TimeCurrent();
      for(int i=0;i<g_nPos;i++) if(g_pos[i].time<t0) t0=g_pos[i].time;
      g_cycleStart=t0;
      if(g_gridDir==0) g_gridDir=(g_cycleDir!=0?g_cycleDir:1);
      g_layerStep=0; g_legStep=0;
      g_gridEngaged=(g_nLegPos>0 || g_nMainPos>=2 || (g_gn[0]>0 && g_gn[1]>0));
      PrintFormat("KV1: adopted a running basket (long=%d short=%d) start=%s",
                  g_gn[0],g_gn[1],TimeToString(t0));
     }
   else
     {
      g_cycleStart=TimeCurrent();
      g_layerStep=0; g_legStep=0;
      g_gridDir=g_cycleDir;
      g_gridEngaged=false;
      SetGuardPrice(0.0);
      PrintFormat("KV1: ===== new cycle started (%s) =====",DirName(g_cycleDir));
     }
   GlobalVariableSet(gvCS,(double)(long)g_cycleStart);
   GlobalVariableSet(gvGD,(double)g_gridDir);
   GlobalVariableSet(gvEN,(g_gridEngaged?1.0:0.0));
   SaveSteps();
   g_realizedStamp=0; g_realizedCount=-1;
  }

void EndCycle(const string why)
  {
   RefreshRealized(-1);
   PrintFormat("KV1: ===== cycle finished (%s) cycle result=%.2f =====",why,g_realized);
   g_cycleStart=0;
   g_layerStep=0; g_legStep=0;
   g_gridDir=0;
   g_gridEngaged=false;
   g_realized=0;
   g_lastCycleEnd=TimeCurrent();
   SetGuardPrice(0.0);
   GlobalVariableDel(gvCS);
   GlobalVariableDel(gvLS);
   GlobalVariableDel(gvGS);
   GlobalVariableDel(gvGD);
   GlobalVariableDel(gvEN);
   ObjectsDeleteAll(0,"KV1_lvl");
  }

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
   if(g_cycleDir==0 || g_bestFavour<=0.0) return;
   if(g_nAddPos>=InpMaxAddons) return;
   if(g_nAddPend>0) return;

   double lot=(InpAddonLot>0.0?InpAddonLot:InpBaseLot);
   double price=g_bestFavour+g_cycleDir*P2P(InpAddonStepPoints);
   string tag=StringFormat("KV1-ADDON-%d",g_nAddPos+1);

   if(PricePassedFavour(price,g_cycleDir))
     {
      if(MktTryOk()) OpenMarket(g_cycleDir,lot,g_magAddon,tag);
      return;
     }
   PlacePending(g_cycleDir,price,lot,g_magAddon,tag);
  }

void ManagePyramidStop()
  {
   if(g_nPos<2 || g_bestFavour<=0.0 || g_cycleDir==0) return;

   double want=g_bestFavour-g_cycleDir*P2P(InpAddonSLBufferPoints);
   if(InpUseTrail)
     {
      double cand=ClosePriceFor(g_cycleDir)-g_cycleDir*P2P(InpTrailDistancePoints);
      if((cand-want)*g_cycleDir>0.0) want=cand;
     }
   want=NormPrice(want);

   double step=P2P(InpTrailStepPoints);
   if(step<=0.0) step=g_tickSize;

   for(int i=0;i<g_nPos;i++)
     {
      if(g_pos[i].role==ROLE_LEG) continue;
      double cur=g_pos[i].sl;
      if(cur==0.0 || (want-cur)*g_cycleDir>=step-g_tickSize*0.5)
         ModifySL(g_pos[i],want);
     }
  }

//==================================================================
//  A G A I N S T   S I D E   ( G R I D  +  P R O T E C T I O N )
//==================================================================
//--- lot of the protection leg that belongs to a grid layer
double LegLotFor(const double layerLot,const bool layerAlreadyOpen)
  {
   int ai=DI(g_gridDir), oi=DI(-g_gridDir);
   double activeTotal=g_gLot[ai]+(layerAlreadyOpen?0.0:layerLot);
   //--- cover that is already open OR already armed (guard, older legs) counts,
   //--- otherwise the next leg would hedge the same lot twice
   double coverTotal=g_gLot[oi]+g_gqLot[oi];
   double pct=InpLegHedgePct/100.0;
   if(pct<=0.0) pct=1.0;
   double lot;
   switch(InpLegLotMode)
     {
      case LEGLOT_FULL:  lot=activeTotal*pct;                break;
      case LEGLOT_LAYER: lot=layerLot;                       break;
      default:           lot=activeTotal*pct-coverTotal;     break;  // BALANCE
     }
   if(lot<g_lotMin) lot=g_lotMin;
   return(NormLot(lot));
  }

void ArmLeg(const double layerPrice,const double layerLot,const bool layerAlreadyOpen)
  {
   if(!InpUseProtectionLeg) { g_legStep=g_layerStep; SaveSteps(); return; }

   int A=g_gridDir, O=-A;
   double price=layerPrice-A*P2P(InpProtectOffsetPoints);
   double lot=LegLotFor(layerLot,layerAlreadyOpen);

   //--- price is already far beyond this leg level -> skip it
   if(PricePassedAgainst(price-A*P2P(InpGridStepPoints*0.5),A))
     { g_legStep=g_layerStep; SaveSteps(); return; }

   double sl=0.0,tp=0.0;
   if(InpLegFixedSLPoints>0.0) sl=price-O*P2P(InpLegFixedSLPoints);
   if(InpLegFixedTPPoints>0.0) tp=price+O*P2P(InpLegFixedTPPoints);

   string tag=StringFormat("KV1-LEG-%d",g_layerStep);

   if(PricePassedAgainst(price,A))
     {
      if(MktTryOk() && OpenMarket(O,lot,g_magLeg,tag,sl,tp))
        { g_legStep=g_layerStep; SaveSteps(); }
      return;
     }
   if(PlacePending(O,price,lot,g_magLeg,tag,sl,tp))
     { g_legStep=g_layerStep; SaveSteps(); }
  }

void EnsureGridStructure()
  {
   if(!InpUseRecovery) return;
   int A=g_gridDir;
   if(A==0) return;
   int ai=DI(A), oi=DI(-A);
   if(g_gn[ai]==0) return;                       // grid side is empty (flip in progress)

   //--- a layer is armed and waiting -> just make sure its leg is armed
   if(g_gqn[ai]>0)
     {
      int qi=g_gqIdx[ai][0];
      if(g_legStep<g_layerStep) ArmLeg(g_pend[qi].price,g_pend[qi].lot,false);
      return;
     }

   //--- layer already filled but its leg was never armed
   if(g_legStep<g_layerStep)
     { ArmLeg(g_gEdge[ai],g_gEdgeLot[ai],true); return; }

   if(g_gn[ai]>=InpMaxLayers) return;
   if(InpMaxTotalLot>0.0 && (g_gLot[0]+g_gLot[1])>=InpMaxTotalLot) return;

   double LP;
   if(g_layerStep<=0 && InpReanchorGridOnGuard && g_guardPrice>0.0)
     {
      //--- after a TP flip the ladder restarts from the guard level, so the new
      //--- layer/leg pair sits close to the market instead of a full step away
      LP=g_guardPrice-A*P2P(InpGridStepPoints);
     }
   else if(g_layerStep<=0 || !InpUseProtectionLeg)
      LP=g_gEdge[ai]-A*P2P(InpGridStepPoints);
   else
     {
      //--- next layer sits one grid step beyond the previous protection leg
      double legLevel=g_gEdge[ai]-A*P2P(InpProtectOffsetPoints);
      if(g_gqn[oi]>0) return;                        // leg still pending -> wait for it
      if(!PricePassedAgainst(legLevel,A)) return;    // leg level not reached yet
      LP=legLevel-A*P2P(InpGridStepPoints);
     }

   double lot=NextLot(g_gEdgeLot[ai]>0.0?g_gEdgeLot[ai]:InpBaseLot);
   string tag=StringFormat("KV1-GRID-%d",g_gn[ai]+1);

   if(PricePassedAgainst(LP,A))
     {
      if(MktTryOk() && OpenMarket(A,lot,g_magMain,tag))
        {
         g_layerStep++; SaveSteps();
         //--- the fresh fill is not in the scanned totals yet -> count it as "not open"
         ArmLeg(g_lastFillPrice,lot,false);
        }
      return;
     }

   if(PlacePending(A,LP,lot,g_magMain,tag))
     {
      g_layerStep++; SaveSteps();
      ArmLeg(LP,lot,false);
     }
  }

//--- optional: legs may trail and bank profit (off by default, it breaks the hedge)
void ManageLegTrail()
  {
   if(!InpLegUseTrail) return;
   int oi=DI(-g_gridDir);
   for(int k=0;k<g_gn[oi];k++)
     {
      int i=g_gpIdx[oi][k];
      int d=g_pos[i].dir;
      double px=ClosePriceFor(d);
      double gain=Pts((px-g_pos[i].price)*d);
      if(gain<InpLegTrailStartPoints) continue;

      double want=NormPrice(px-d*P2P(InpLegTrailDistPoints));
      double cur=g_pos[i].sl;
      double step=P2P(InpLegTrailStepPoints);
      if(step<=0.0) step=g_tickSize;
      if(!(cur==0.0 || (want-cur)*d>=step-g_tickSize*0.5)) continue;
      if((want-g_pos[i].price)*d<0.0) continue;      // never trail into a loss
      ModifySL(g_pos[i],want);
     }
  }

//==================================================================
//  G R O U P   W E I G H T E D   T P   ( A L T E R N A T I N G )
//==================================================================
double GroupTargetMoney(const int gi)
  {
   if(InpGroupTPMode==GTP_POINTS)
      return(P2P(InpGroupTPPoints)*g_gLot[gi]*g_vpu);
   double t=InpGroupTargetMoney;
   if(t<=0.0) t=P2P(InpAutoTargetPoints)*InpBaseLot*g_vpu;
   return(t);
  }

//--- weighted price where THIS group alone reaches the target (always a profit)
double GroupTPPrice(const int gi,const int dir,const double target)
  {
   if(g_gLot[gi]<=0.0) return(0.0);
   double wavg=g_gW[gi]/g_gLot[gi];
   if(InpGroupTPMode==GTP_POINTS)
      return(NormPrice(wavg+dir*P2P(InpGroupTPPoints)));
   double need=target-g_gSwap[gi];                 // swap already paid is covered too
   if(need<0.0) need=0.0;
   return(NormPrice(wavg+dir*(need/(g_vpu*g_gLot[gi]))));
  }

//------------------------------------------------------------------
//  WHOLE BASKET EXIT (both sides together, nothing is left naked)
//------------------------------------------------------------------
double BasketTargetMoney()
  {
   double t=InpBasketTargetMoney;
   if(t<=0.0) t=InpGroupTargetMoney;
   if(t<=0.0) t=P2P(InpAutoTargetPoints)*InpBaseLot*g_vpu;
   return(t);
  }

//--- price where floating(all) + realized == target. 0 if the basket is hedged flat
double BasketTPPrice(const double target)
  {
   double net=g_gLot[0]-g_gLot[1];
   if(MathAbs(net)<g_lotMin*0.5) return(0.0);          // fully hedged -> PnL is frozen
   double w   =g_gW[0]-g_gW[1];
   double swap=g_gSwap[0]+g_gSwap[1];
   return(NormPrice((w+(target-g_realized-swap)/g_vpu)/net));
  }

bool BasketFrozen()
  {
   double net=MathAbs(g_gLot[0]-g_gLot[1]);
   double big=MathMax(g_gLot[0],g_gLot[1]);
   if(big<=0.0) return(false);
   return(net<big*0.10 || net<g_lotMin*0.5);
  }

//--- money the opposite (soon to be naked) side will show at 'price'
double SideMoneyAtPrice(const int gi,const double price)
  {
   if(g_gn[gi]==0) return(0.0);
   int d=(gi==0?1:-1);
   return((price*g_gLot[gi]-g_gW[gi])*d*g_vpu+g_gSwap[gi]);
  }

double g_flipCost=0;
bool   g_flipAllowed=true;
double g_basketTP=0;

bool FlipAllowed(const int ai,const int oi,const double tpPrice)
  {
   g_flipCost=(tpPrice>0.0?SideMoneyAtPrice(oi,tpPrice):0.0);

   if(InpExitMode==EXIT_GROUP_FLIP) return(true);
   if(g_gn[oi]==0)                  return(true);   // nothing is left behind
   if(InpExitMode==EXIT_BASKET)     return(false);

   //--- SMART: a fully hedged basket can never reach a basket target,
   //--- so there the flip is the only way out and must stay allowed.
   if(BasketFrozen()) return(true);

   double limit=InpMaxNakedLossMoney;
   if(limit<=0.0) limit=3.0*GroupTargetMoney(ai);
   return(g_flipCost>=-limit);
  }

void ManageBasketExit()
  {
   if(InpExitMode==EXIT_GROUP_FLIP) return;
   if(g_nPos==0) return;
   double target=BasketTargetMoney();
   g_basketTP=BasketTPPrice(target);
   double money=g_totalFloat+g_realized;
   if(money>=target)
     {
      DeleteAllOurPendings("whole basket target");
      CloseAllPositions(StringFormat("whole basket closed in profit: %.2f >= %.2f",money,target));
     }
  }

void ManageGroupTP()
  {
   int A=g_gridDir;
   if(A==0) return;
   int ai=DI(A), oi=DI(-A);
   if(g_gn[ai]==0) return;

   double target =GroupTargetMoney(ai);
   double tpPrice=GroupTPPrice(ai,A,target);
   g_flipAllowed =FlipAllowed(ai,oi,tpPrice);

   //--- the whole grid side closes together, in profit, never in loss
   if(g_flipAllowed && g_gProfit[ai]>=target)
     {
      DeleteAllOurPendings("grid side reached its weighted TP");
      CloseDirection(A,StringFormat("%s group weighted TP: %.2f >= %.2f (naked cost %.2f)",
                                    DirName(A),g_gProfit[ai],target,g_flipCost));
      return;
     }

   //--- flip would leave too much loss naked -> pull the hard TP and let the
   //--- whole basket exit do the job instead
   bool hard=(InpPlaceHardTP && g_flipAllowed && tpPrice>0.0);

   for(int k=0;k<g_gn[ai];k++)
      ModifyTP(g_pos[g_gpIdx[ai][k]],hard?tpPrice:0.0);

   //--- the opposite side waits for its turn: no TP until it becomes the grid side
   if(InpLegFixedTPPoints<=0.0)
      for(int k=0;k<g_gn[oi];k++)
         ModifyTP(g_pos[g_gpIdx[oi][k]],0.0);
  }

//------------------------------------------------------------------
//  FLIP GUARD: a naked grid side is re-covered close to price
//  instead of waiting a full grid step for the next layer/leg pair
//------------------------------------------------------------------
void SetGuardPrice(const double p)
  {
   g_guardPrice=p;
   if(p>0.0) GlobalVariableSet(gvGP,p);
   else      GlobalVariableDel(gvGP);
  }

//--- where the guard order must sit: the grid level of the naked side that is
//--- nearest to the current price on the side that hurts it, capped so the
//--- naked side can never bleed more than InpFlipProtectPoints
double GuardLevel(const int A,const int ai)
  {
   double px=ClosePriceFor(A);
   double cap=(InpFlipProtectPoints>0.0?P2P(InpFlipProtectPoints):0.0);
   double capped=(cap>0.0?px-A*cap:0.0);
   double best=0.0;

   if(InpGuardSnapToGrid)
     {
      //--- nearest naked side entry that lies on the losing side of it
      for(int k=0;k<g_gn[ai];k++)
        {
         double e=g_pos[g_gpIdx[ai][k]].price;
         if((e-px)*(-A)<=0.0) continue;                 // not beyond price -> skip
         if(best==0.0 || MathAbs(e-px)<MathAbs(best-px)) best=e;
        }
     }

   if(best==0.0)                            return(capped>0.0?capped:px-A*P2P(200));
   if(cap>0.0 && MathAbs(best-px)>cap)      return(capped);   // too far -> use the cap
   return(best);
  }

void EnsureFlipGuard()
  {
   if(!InpUseProtectionLeg) return;
   if(InpFlipProtectPoints<=0.0 && !InpGuardSnapToGrid) return;
   if(!g_gridEngaged) return;
   int A=g_gridDir;
   if(A==0) return;
   int ai=DI(A), oi=DI(-A);
   if(g_gn[ai]==0) return;
   if(g_gn[oi]>0 || g_gqn[oi]>0) return;      // already covered, or cover is armed
   if(g_gProfit[ai]>=0.0) return;             // grid side is not losing -> no need

   double pct=InpFlipGuardPct/100.0;
   if(pct<=0.0) pct=1.0;
   double lot=NormLot(g_gLot[ai]*pct);
   double price=NormPrice(GuardLevel(A,ai));

   //--- remember the level even if the send fails: the ladder is re-anchored here
   SetGuardPrice(price);

   double sl=0.0,tp=0.0;
   int O=-A;
   if(InpLegFixedSLPoints>0.0) sl=price-O*P2P(InpLegFixedSLPoints);
   if(InpLegFixedTPPoints>0.0) tp=price+O*P2P(InpLegFixedTPPoints);

   //--- level already reached, or too close to be a pending order:
   //--- freeze the bleeding right now at market
   if(PricePassedAgainst(price,A) || !PendingPriceOk(O,price))
     {
      if(MktTryOk())
        {
         if(OpenMarket(O,lot,g_magLeg,"KV1-GUARD",sl,tp))
            PrintFormat("KV1: naked %s side frozen with a %.2f guard at market",DirName(A),lot);
        }
      return;
     }
   if(PlacePending(O,price,lot,g_magLeg,"KV1-GUARD",sl,tp))
      PrintFormat("KV1: guard armed %.0f pts from price (naked %s side, level %s)",
                  Pts(MathAbs(price-ClosePriceFor(A))),DirName(A),DoubleToString(price,g_digits));
  }

//==================================================================
//  M O D E   H A N D L E R S
//==================================================================
void HandleWait()
  {
   EnsureAddonLeg();
   EnsureGridStructure();
  }

void HandlePyramid()
  {
   //--- price went our way first: pyramid + trailing owns this cycle
   for(int i=0;i<g_nPend;i++)
      if(g_pend[i].role!=ROLE_ADDON)
         trade.OrderDelete(g_pend[i].ticket);
   EnsureAddonLeg();
   ManagePyramidStop();
  }

void HandleGrid()
  {
   //--- price went against us: grid + legs + alternating group TP owns this cycle
   DeletePendingsByRole(ROLE_ADDON,"grid engaged");

   //--- pyramid stops must not cut the grid
   for(int i=0;i<g_nPos;i++)
      if(g_pos[i].role!=ROLE_LEG && g_pos[i].sl!=0.0)
         trade.PositionModify(g_pos[i].ticket,0.0,g_pos[i].tp);

   EnsureFlipGuard();      // naked side gets covered close to price
   EnsureGridStructure();
   ManageLegTrail();
   ManageBasketExit();     // best case: both sides close together in profit
   ManageGroupTP();        // otherwise the grid side closes at its weighted TP
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

   if(g_lastCycleEnd>0 && InpCooldownBars>0)
     {
      int secs=PeriodSeconds(InpSignalTF)*InpCooldownBars;
      if(TimeCurrent()-g_lastCycleEnd<secs) return(false);
     }
   if(iTime(g_sym,InpSignalTF,0)==g_lastEntryBar) return(false);
   return(true);
  }

void TryOpenNewCycle()
  {
   if(!EntryFiltersOk()) return;
   int dir=EntryDirection();
   if(dir==0) return;

   string tag=(dir>0?"KV1-INITIAL-BUY":"KV1-INITIAL-SELL");
   if(OpenMarket(dir,InpBaseLot,g_magMain,tag))
     {
      g_lastEntryBar=iTime(g_sym,InpSignalTF,0);
      ScanState();
      StartCycle(false);
      EnsureAddonLeg();
      EnsureGridStructure();
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
         DeleteAllOurPendings("equity stop");
         CloseAllPositions("equity stop");
         Halt(StringFormat("equity %.2f below %.1f%% of %.2f",eq,InpEquityStopPct,bal));
         return(false);
        }
     }

   if(InpMaxBasketLossMoney>0.0 && g_nPos>0 &&
      (g_totalFloat+g_realized)<=-InpMaxBasketLossMoney)
     {
      DeleteAllOurPendings("max loss");
      CloseAllPositions(StringFormat("emergency: cycle money %.2f",g_totalFloat+g_realized));
      return(false);
     }

   if(InpCloseAllOnFriday)
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
      if(dt.day_of_week==5 && dt.hour>=InpFridayCloseHour && (g_nPos+g_nPend)>0)
        {
         DeleteAllOurPendings("friday flat");
         CloseAllPositions("friday flat");
         return(false);
        }
     }
   return(true);
  }

//--- pyramid positions share one SL: if one got stopped, flatten the rest
void PyramidStopGuard()
  {
   if(g_prevMode==MODE_PYRAMID && g_nPos>0 && g_nPos<g_prevPosTotal && g_mode!=MODE_GRID)
     {
      DeleteAllOurPendings("trail SL hit");
      CloseAllPositions("trail SL hit - flatten cycle");
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

string GroupLine(const int gi,const string label)
  {
   if(g_gn[gi]==0) return(StringFormat("%-6s -\n",label));
   double wavg=g_gW[gi]/g_gLot[gi];
   return(StringFormat("%-6s n=%d lot=%.2f avg=%s float=%.2f\n",
                       label,g_gn[gi],g_gLot[gi],DoubleToString(wavg,g_digits),g_gProfit[gi]));
  }

void DrawPanel()
  {
   if(!InpShowPanel) { Comment(""); return; }

   int A=g_gridDir;
   int ai=(A!=0?DI(A):0);
   if(g_nPos>0) g_basketTP=BasketTPPrice(BasketTargetMoney());
   else         g_basketTP=0;
   double target=(A!=0 && g_gn[ai]>0 ? GroupTargetMoney(ai) : 0.0);
   double tpPrice=(A!=0 && g_gn[ai]>0 ? GroupTPPrice(ai,A,target) : 0.0);

   double nextLayerPrice=0, nextLayerLot=0, nextLegPrice=0, nextLegLot=0, nextAddPrice=0;
   for(int i=0;i<g_nPend;i++)
     {
      if(g_pend[i].role==ROLE_ADDON) { nextAddPrice=g_pend[i].price; continue; }
      if(A!=0 && g_pend[i].dir==A)   { nextLayerPrice=g_pend[i].price; nextLayerLot=g_pend[i].lot; }
      else                           { nextLegPrice=g_pend[i].price;   nextLegLot=g_pend[i].lot;   }
     }

   double slShown=(g_idxOldestMain>=0?g_pos[g_idxOldestMain].sl:0.0);

   string s="";
   s+="========== KRISH V1 AUTO v2 ==========\n";
   s+=StringFormat("%s  spread %.0f pts  digits %d  adj %.0f\n",g_sym,SpreadPoints(),g_digits,g_padj);
   s+=StringFormat("PROB  UP %.1f%% | DOWN %.1f%%   ADX %.1f   signal %s\n",
                   g_probUp,100.0-g_probUp,g_adx,DirName(EntryDirection()));
   s+=StringFormat("factors: %s\n",g_sigNote);
   s+="--------------------------------------\n";
   s+=StringFormat("MODE %s\n",ModeName(g_mode));
   s+=StringFormat("cycle dir %s   TP side now: %s\n",DirName(g_cycleDir),DirName(A));
   s+=GroupLine(0,"LONG");
   s+=GroupLine(1,"SHORT");
   s+=StringFormat("layers %d/%d  add-ons %d/%d  legs %d  step L%d/G%d\n",
                   (A!=0?g_gn[ai]:0),InpMaxLayers,g_nAddPos,InpMaxAddons,g_nLegPos,
                   g_layerStep,g_legStep);
   s+=StringFormat("money float %.2f + realized %.2f = %.2f\n",
                   g_totalFloat,g_realized,g_totalFloat+g_realized);
   if(g_mode==MODE_GRID)
     {
      s+=StringFormat("net lot %+.2f  hedge %.0f%%  %s\n",
                      g_gLot[0]-g_gLot[1],InpLegHedgePct,
                      (BasketFrozen()?"BASKET FROZEN (net ~0)":"basket can close together"));
      s+=StringFormat("group TP %s   (needs %.2f on the %s side)\n",
                      (tpPrice>0.0?DoubleToString(tpPrice,g_digits):"-"),target,DirName(A));
      s+=StringFormat("flip: %s   cost if it fires now %.2f\n",
                      (g_flipAllowed?"ALLOWED":"BLOCKED (too much naked loss)"),g_flipCost);
      s+=StringFormat("basket TP %s   target %.2f\n",
                      (g_basketTP>0.0?DoubleToString(g_basketTP,g_digits):"n/a"),BasketTargetMoney());
      if(g_guardPrice>0.0)
         s+=StringFormat("guard level %s (ladder restarts from here)\n",
                         DoubleToString(g_guardPrice,g_digits));
     }
   if(g_mode==MODE_PYRAMID || g_mode==MODE_WAIT)
      s+=StringFormat("pyramid SL %s\n",(slShown>0.0?DoubleToString(slShown,g_digits):"none yet"));
   s+=StringFormat("next add-on %s\n",(nextAddPrice>0.0?DoubleToString(nextAddPrice,g_digits):"-"));
   s+=StringFormat("next layer  %s  lot %.2f\n",
                   (nextLayerPrice>0.0?DoubleToString(nextLayerPrice,g_digits):"-"),nextLayerLot);
   s+=StringFormat("next leg    %s  lot %.2f\n",
                   (nextLegPrice>0.0?DoubleToString(nextLegPrice,g_digits):"-"),nextLegLot);
   if(g_halted) s+="*** HALTED (safety) ***\n";
   s+="======================================";
   Comment(s);

   if(InpShowTPLine)
     {
      DrawLevel("KV1_lvlTP"   ,tpPrice       ,clrDodgerBlue,STYLE_SOLID  ,"group TP");
      DrawLevel("KV1_lvlBTP" ,(g_mode==MODE_GRID?g_basketTP:0.0),clrAqua,STYLE_SOLID,"whole basket TP");
      DrawLevel("KV1_lvlLayer",nextLayerPrice,clrOrange    ,STYLE_DASH   ,"next layer");
      DrawLevel("KV1_lvlLeg"  ,nextLegPrice  ,clrRed       ,STYLE_DOT    ,"protection leg");
      DrawLevel("KV1_lvlAdd"  ,nextAddPrice  ,clrLime      ,STYLE_DASH   ,"next add-on");
      DrawLevel("KV1_lvlSL"   ,slShown       ,clrMagenta   ,STYLE_DASHDOT,"trail SL");
      DrawLevel("KV1_lvlGuard",(g_mode==MODE_GRID?g_guardPrice:0.0),clrYellow,STYLE_DOT,"guard level");
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

   if(g_nPos==0)
     {
      if(g_nPend>0) DeleteAllOurPendings("no position left");
      if(g_cycleStart>0) { EndCycle("flat"); ScanState(); }
      TryOpenNewCycle();
     }
   else
     {
      if(g_cycleStart<=0) { StartCycle(true); ScanState(); }

      switch(g_mode)
        {
         case MODE_WAIT:    HandleWait();    break;
         case MODE_PYRAMID: HandlePyramid(); break;
         case MODE_GRID:    HandleGrid();    break;
        }
     }

   g_prevPosTotal=g_nPos;
   g_prevMode=g_mode;
   DrawPanel();
  }
