# KRISH V1 AUTO — MT5 Gold Robot

Gold (XAUUSD) ke liye MT5 Expert Advisor. 3 hisse hain:

1. **Prediction engine** — 13 factor ka weighted score (multi timeframe) se nikalta hai ki UP ki probability zyada hai ya DOWN ki. Jab tak kisi ek side ki probability `InpMinProbability` (default 60%) se upar nahi jaati, koi trade open nahi hota.
2. **Favour side (add-on pyramid)** — trade profit me gaya to har +200 point pe same lot ka add-on, aur poore basket ka step-wise trailing SL.
3. **Against side (recovery grid + protection legs)** — trade ulta gaya to 800 point pe next layer (thoda bada lot) + uske 50-100 point neeche opposite protection leg, aur poore basket ka **weighted TP** jo recovery + profit dono cover karta hai.

File: `MQL5/Experts/KRISH_V1_AUTO/KRISH_V1_AUTO.mq5`
Preset: `MQL5/Presets/KRISH_V1_AUTO_gold.set`

---

## 1. Install kaise karein

1. MT5 me `File → Open Data Folder` → `MQL5/Experts/` me `KRISH_V1_AUTO` folder copy karein.
2. MetaEditor kholein → `KRISH_V1_AUTO.mq5` open karein → **F7** (Compile).
3. MT5 restart / Navigator refresh → XAUUSD chart (M15 recommended) pe EA drag karein.
4. `Allow Algo Trading` on rakhein. Panel chart pe dikhega (probability, mode, layers, TP, SL sab).
5. Pehle **Strategy Tester** aur **demo** pe chalayein, phir live.

---

## 2. Favour side ka flow (trade profit me gaya)

```
initial BUY 0.01  @ P1                      <- probability engine ne signal diya
   |
   |-- pending BUY STOP  @ P1 + 200 pts  (0.01)   <- add-on leg pehle se armed
   |-- pending BUY layer @ P1 - 800 pts  (0.02)   <- recovery leg bhi pehle se armed
   |
add-on #1 fill hua (P1+200)
   -> recovery pendings delete (ab pyramid mode)
   -> SL SABHI trades pe = (newest add-on entry) - 100 pts   => P1 + 100
   -> step-wise trailing start (distance 150 pts, step 50 pts)
   -> next add-on pending @ (P1+200) + 200 pts, same lot
   |
add-on #2 fill hua (P1+400)
   -> SL sabhi trades pe = P1 + 300
   -> next add-on pending @ P1 + 600
   |
... aise hi chalta rehta hai (max InpMaxAddons)
   |
trail SL hit  ->  cycle ke SAARE trades ek sath exit, cycle khatam
```

- Add-on ka lot base lot hi rehta hai (0.01), badhta nahi.
- SL sabhi positions pe same hota hai, isliye trail hit hone pe sab ek sath band. Agar broker ne kisi ek ko pehle band kiya to EA baaki ko turant close kar deta hai (`PyramidStopGuard`).
- Initial trade always overall profit me hi nikalta hai — sirf last add-on -100 pts loss me jaata hai, jaise aapne bola tha.

## 3. Against side ka flow (trade ulta gaya)

```
initial BUY 0.01 @ P1
   |
   |-- layer2 pending  BUY  @ P1 - 800 pts        lot 0.02  (1.3x, mild)
   |-- leg2   pending  SELL @ layer2 - 80 pts     lot 0.02  (= last grid layer ka lot)
   |
layer2 fill  ->  add-on pending delete (ab recovery mode), pyramid SL hata diya jaata hai
                 weighted basket TP calculate hone lagta hai
   |
leg2 (SELL) fill  ->  layer3 pending BUY @ leg2price - 800 pts   lot 0.03
                      leg3 pending  SELL @ layer3 - 80 pts       lot 0.03
   |
layer3 fill -> leg3 fill -> layer4 (0.04) + leg4 (0.04) ... max InpMaxLayers
   |
har fill / har banked profit pe weighted TP dobara calculate
   |
basket target hit -> saari positions (buy layers + sell legs) ek sath close, cycle khatam
```

- **Protection leg (opposite order)** ka lot = us waqt ke deepest grid layer ka lot — exactly jaisa aapne bola.
- Protection leg ek "runner" hai: `InpLegTrailStartPoints` (200) profit ke baad wo bhi step-wise trail karta hai, aur bounce pe profit lock karke band ho jaata hai. Ye realized profit basket ke TP ko **neeche** le aata hai (recovery fast hoti hai).
- SELL first signal aaya to sab kuch mirror: main layers SELL neeche-neeche… sorry, upar-upar (800 pts against), protection legs BUY.

## 4. Weighted TP ka maths

TP wo price hai jahan **floating + is cycle ka realized (band ho chuke legs ka profit/loss, commission, swap)** = target ban jaaye:

```
netLot = Σ(dir × lot)              (buy = +, sell = −)
wSum   = Σ(dir × lot × entry)
TP     = ( wSum + (target − realized) / valuePerPricePerLot ) / netLot
```

- `target` default = `InpAutoTargetPoints` (300 pts) × base lot ka money value → 0.01 lot gold pe ≈ **$3**. Chahein to `InpBasketTargetMoney` se fix money de sakte hain.
- Jab tak koi opposite leg open hai, real TP order nahi lagta (kyunki ek hi price dono taraf valid nahi hota) — EA khud tick pe monitor karke sab close karta hai, aur chart pe neeli line pe TP dikhata hai. Jab koi leg open nahi hota, EA asli TP order bhi laga deta hai (`InpPlaceHardTP`).
- Isliye recovery mode me terminal/VPS chalu rehna chahiye.

## 5. Prediction engine ke factors

| Factor | Kya dekhta hai |
|---|---|
| F1 | EMA20 vs EMA50 (working TF, ATR se normalise) |
| F2 | EMA20 vs EMA50 (H1 confirmation) |
| F3 | EMA20 vs EMA50 (H4 master trend) |
| F4 | Fast EMA ka slope |
| F5 | ADX ka +DI / −DI balance |
| F6 | MACD histogram + uska slope |
| F7 | RSI momentum (trend regime me) |
| F8 | RSI mean-reversion (range regime me) |
| F9 | Bollinger %B (range me fade, trend me ride) |
| F10 | Stochastic level + K/D cross |
| F11 | 10 bar raw momentum |
| F12 | 20 bar breakout position |
| F13 | Last 3 candles ka body structure |

- ADX se **regime weight** banta hai: ADX high (trend) → trend factors ka weight zyada, ADX low (range) → mean-reversion factors ka weight zyada.
- Final score −1..+1 → `probUp = 50 + 50 × score`. Panel pe UP% / DOWN% dono dikhte hain.
- Testing ke liye `InpSignalMode` = 1 (force BUY) ya 2 (force SELL) kar sakte hain.

## 6. Main inputs

| Input | Default | Matlab |
|---|---|---|
| `InpBaseLot` | 0.01 | Initial + add-on lot |
| `InpLotMultiplier` | 1.3 | Grid layer lot multiplier (aggressive nahi) |
| `InpMaxLot` | 1.00 | Lot cap |
| `InpAddonStepPoints` | 200 | Favour me itne point pe next add-on |
| `InpAddonSLBufferPoints` | 100 | Newest add-on se itna peeche SL |
| `InpTrailDistancePoints` / `InpTrailStepPoints` | 150 / 50 | Step-wise trailing |
| `InpGridStepPoints` | 800 | Against me next layer ki distance |
| `InpProtectOffsetPoints` | 80 | Layer ke aage protection leg (50–100) |
| `InpMaxLayers` | 8 | Max main layers |
| `InpAutoTargetPoints` | 300 | Auto basket target (base lot pe points) |
| `InpMinProbability` | 60 | Entry ke liye minimum probability % |
| `InpMaxSpreadPoints` | 60 | Isse zyada spread me entry nahi |
| `InpEquityStopPct` | 0 | Equity itna % gira to sab band + EA halt |
| `InpMaxBasketLossMoney` | 0 | Basket loss cap (money), 0 = off |

**Points note (gold):** 2-digit gold (0.01 point) pe 200 points = $2.00 move, 800 points = $8.00. 3-digit broker pe EA khud ×10 adjust kar leta hai (`InpAutoPointAdjust`), to numbers badalne ki zarurat nahi.

## 7. Zaroori baatein / risk

- Ye grid + lot-increase system hai. 1.3x mild hai, phir bhi 8 layers tak jaane pe lot 0.01 → 0.02 → 0.03 → 0.04 → 0.05 → 0.07 → 0.09 → 0.12 (~0.43 total) ho jaata hai. 0.01 base ke liye **kam se kam $300–500 balance** rakhein, aur `InpEquityStopPct` set karke chalayein.
- Broker "buy stop neeche" allow nahi karta — jo order market ke neeche BUY hota hai wo MT5 me **BUY LIMIT** hota hai. EA khud sahi type (STOP/LIMIT) choose karta hai, logic aapka wahi hai.
- Hedging account chahiye (protection leg opposite direction me hota hai). Netting account pe ye logic kaam nahi karega.
- Ek chart pe ek hi instance. Do instance chahiye to `InpMagic` alag rakhein.
- Terminal restart safe hai: EA running basket ko adopt kar leta hai (cycle info terminal global variables me save hoti hai).

## 8. Testing

- Strategy Tester → XAUUSD, M15, **Every tick based on real ticks**, 3–6 mahine ka data.
- Pehle `InpSignalMode=1` (force BUY) pe dekhein ki flow theek chal raha hai (layers, legs, TP, trailing), phir engine on karein.
- Journal me har action print hota hai (`KV1: ...`), aur chart pe lines: neeli = basket TP, orange = next layer, laal = protection leg, hari = next add-on, magenta = trail SL.
