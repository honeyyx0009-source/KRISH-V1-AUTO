# KRISH V1 AUTO — MT5 Gold Robot

Gold (XAUUSD) ke liye MT5 Expert Advisor. 4 hisse hain:

1. **Prediction engine** — 13 factor ka weighted score (3 timeframe) se nikalta hai ki UP ki probability zyada hai ya DOWN ki. Jab tak kisi ek side ki probability `InpMinProbability` (default 60%) se upar nahi jaati, koi trade open nahi hota. Cycle ka **pehla order comment me `KV1-INITIAL-BUY` / `KV1-INITIAL-SELL`** likha rehta hai, to terminal me turant pata chalta hai ki initial order kaunsa hai.
2. **Favour side (add-on pyramid)** — trade profit me gaya to har +200 point pe same lot ka add-on, aur poore basket ka step-wise trailing SL.
3. **Against side (grid + opposite protection legs)** — trade ulta gaya to 800 point pe next layer (thoda bada lot) + uske 80 point aage opposite protection leg, jiska **lot grid side ke TOTAL open lot par** based hota hai.
4. **Alternating group weighted TP** — ek time pe sirf **ek side** ke paas TP hota hai. Us side ka TP wahi price hai jahan **wo group akela profit me** band ho (loss me kabhi nahi). TP hit hua → us side ke saare orders close → jo opposite orders bache wo naya "grid side" ban jaate hain, TP unpe shift ho jaata hai aur grid us direction me continue hota hai. Aise hi TP idhar-udhar shift hota rehta hai jab tak cycle poora flat na ho jaye.

Files:
- EA: `MQL5/Experts/KRISH_V1_AUTO/KRISH_V1_AUTO.mq5`
- Preset: `MQL5/Presets/KRISH_V1_AUTO_gold.set`

---

## 1. Install kaise karein

1. MT5 me `File → Open Data Folder` → `MQL5/Experts/` me `KRISH_V1_AUTO` folder copy karein.
2. MetaEditor kholein → `KRISH_V1_AUTO.mq5` open karein → **F7** (Compile).
3. Navigator refresh → XAUUSD chart (M15 recommended) pe EA drag karein, `Allow Algo Trading` on.
4. Pehle **Strategy Tester** aur **demo** pe chalayein, phir live.

---

## 2. Favour side ka flow (trade profit me gaya)

```
initial BUY 0.01 @ P1        comment: KV1-INITIAL-BUY
   |-- pending BUY  @ P1 + 200 pts (0.01)   <- add-on leg pehle se armed
   |-- pending BUY  @ P1 - 800 pts (0.02)   <- grid leg bhi pehle se armed
   |-- pending SELL @ (P1-800) - 80 pts (0.03)  <- protection leg
   |
add-on #1 fill (P1+200)
   -> grid + protection pendings delete (ab PYRAMID mode)
   -> SL sabhi trades pe = newest add-on - 100 pts  => P1 + 100
   -> step-wise trailing (distance 150, step 50)
   -> next add-on pending @ P1 + 400
   |
add-on #2 fill (P1+400)  ->  SL = P1 + 300,  next pending @ P1 + 600
   |
trail SL hit -> cycle ke SAARE trades ek sath exit, cycle khatam
```

Initial trade always overall profit me nikalta hai — sirf last add-on −100 pts par band hota hai.

## 3. Against side ka flow (trade ulta gaya)

```
BUY 0.01 @ P1                                    grid side = BUY
layer2  BUY  0.02 @ P1 - 800
leg2    SELL 0.03 @ layer2 - 80        <- lot = 0.01 + 0.02 = TOTAL buy lot
   |                                      (BUY total 0.03  =  SELL total 0.03)
leg2 fill -> layer3 BUY 0.03 @ leg2 - 800
             leg3   SELL 0.03 @ layer3 - 80   (buy total 0.06 = sell total 0.06)
   |
layer4 / leg4 ... max InpMaxLayers
```

### Protection leg ka lot (`InpLegLotMode`)

| Mode | Rule |
|---|---|
| `LEGLOT_BALANCE` **(default)** | leg lot = grid side ka total lot − opposite side ka total lot → dono side ka total barabar ho jaata hai (aapka rule) |
| `LEGLOT_FULL` | har leg = grid side ka poora total (opposite side accumulate hota hai) |
| `LEGLOT_LAYER` | sirf us layer ka lot (purana v1 behaviour) |

### TP kaise shift hota hai

```
grid side = BUY (4 buy layers + 3 sell legs)
   |
   |  BUY group ka weighted TP = wo price jahan SIRF buy group +target profit me ho
   |  (SELL legs ka koi TP nahi — unki turn baad me aayegi)
   |
market wapas upar aaya -> BUY group ka TP hit
   -> saare BUY close (profit me, loss me nahi)
   -> ab sirf SELL bache  =>  grid side = SELL
   -> TP ab SELL group pe calculate hota hai (unke weighted average se neeche)
   -> grid bhi SELL side ka continue hota hai: next SELL layer 800 pts upar,
      aur uske 80 pts upar BUY protection leg
   |
SELL group ka TP hit -> saare SELL close -> TP wapas BUY pe shift
   ... aise hi chalta rehta hai jab tak sab flat na ho
```

Group TP ka maths (single direction group, isliye exact):

```
wavg = Σ(lot × entry) / Σlot
TP   = wavg + dir × (target − group_swap) / (valuePerPricePerLot × Σlot)
```

- `InpGroupTPMode = GTP_MONEY` (default): `target` = `InpGroupTargetMoney`, ya 0 hone par auto = `InpAutoTargetPoints` (300) × base lot ka money value ≈ **$3** (0.01 lot gold).
- `InpGroupTPMode = GTP_POINTS`: TP = weighted average se `InpGroupTPPoints` (200) points aage. Group jitna bada, profit bhi utna bada.
- Dono mode me TP **hamesha** weighted average se profit wali side pe hota hai → group loss me band nahi hoga.
- Grid side pe real (hard) TP order bhi lagta hai (`InpPlaceHardTP`), kyunki group single-direction hai to price exact valid hoti hai. Isliye terminal band ho jaye to bhi grid side ka TP broker ke paas rehta hai.

## 4. Prediction engine ke factors

| Factor | Kya dekhta hai |
|---|---|
| F1 | EMA20 vs EMA50 (working TF, ATR se normalise) |
| F2 | EMA20 vs EMA50 (H1 confirmation) |
| F3 | EMA20 vs EMA50 (H4 master trend) |
| F4 | Fast EMA ka slope |
| F5 | ADX ka +DI / −DI balance |
| F6 | MACD histogram + uska slope |
| F7 | RSI momentum (trend regime) |
| F8 | RSI mean-reversion (range regime) |
| F9 | Bollinger %B (range me fade, trend me ride) |
| F10 | Stochastic level + K/D cross |
| F11 | 10 bar raw momentum |
| F12 | 20 bar breakout position |
| F13 | Last 3 candle ka body structure |

ADX se **regime weight** banta hai: ADX high → trend factors bhaari, ADX low → mean-reversion factors bhaari. Final score −1..+1 → `probUp = 50 + 50 × score`. Testing ke liye `InpSignalMode` = 1 (force BUY) / 2 (force SELL).

## 5. Main inputs

| Input | Default | Matlab |
|---|---|---|
| `InpBaseLot` | 0.01 | Initial + add-on lot |
| `InpLotMultiplier` | 1.3 | Grid layer lot multiplier (mild) |
| `InpMaxLot` | 1.00 | Ek order ka lot cap |
| `InpAddonStepPoints` | 200 | Favour me itne point pe next add-on |
| `InpAddonSLBufferPoints` | 100 | Newest add-on se itna peeche SL |
| `InpTrailDistancePoints` / `InpTrailStepPoints` | 150 / 50 | Step-wise trailing |
| `InpGridStepPoints` | 800 | Against me next layer ki distance |
| `InpProtectOffsetPoints` | 80 | Layer ke aage protection leg (50–100) |
| `InpLegLotMode` | BALANCE | Protection leg ka lot rule |
| `InpMaxLayers` | 8 | Grid side pe max positions |
| `InpGroupTPMode` | MONEY | Group TP money ya points me |
| `InpGroupTargetMoney` / `InpAutoTargetPoints` | 0 / 300 | Group ka profit target |
| `InpGroupTPPoints` | 200 | Points mode me weighted avg se distance |
| `InpLegUseTrail` | false | Legs ko trail karna (hedge todta hai) |
| `InpMaxTotalLot` | 0 | Total lot itna hone par naye layer band (0 = off) |
| `InpMaxBasketLossMoney` | 0 | Cycle loss cap (money), 0 = off |
| `InpEquityStopPct` | 0 | Equity itna % gira to sab band + EA halt |

**Points note (gold):** 2-digit gold (point = 0.01) pe 200 points = $2.00 move, 800 points = $8.00. 3-digit broker pe EA khud ×10 adjust karta hai (`InpAutoPointAdjust`).

## 6. Zaroori baatein / risk

- **TP shift hone par exposure badhta hai.** BALANCE mode me jab grid side close hota hai to opposite side ka total cover karne ke liye next protection leg bada hota hai. Example: 0.01 → 0.02/0.03 → 0.03/0.03 … TP shift ke baad naya leg 0.10 tak ja sakta hai. `InpMaxTotalLot`, `InpMaxLot`, `InpMaxLayers` aur `InpEquityStopPct` se limit lagana zaroori hai.
- 0.01 base ke liye kam se kam **$300–500** balance rakhein (BALANCE leg mode me thoda zyada rakhna behtar).
- **Hedging account chahiye** (protection leg opposite direction me hota hai). Netting account pe ye logic kaam nahi karega.
- Market ke neeche BUY = MT5 me **BUY LIMIT** (stop nahi). EA khud sahi type (STOP/LIMIT) choose karta hai, logic aapka wahi rehta hai.
- Ek chart pe ek instance. Doosra instance chahiye to `InpMagic` alag rakhein.
- Restart safe: EA running basket ko adopt kar leta hai, aur cycle state terminal global variables (`KV1_<magic>_*`) me save rehti hai.

## 7. Testing

- Strategy Tester → XAUUSD, M15, **Every tick based on real ticks**, 3–6 mahine.
- Pehle `InpSignalMode=1` (force BUY) se flow verify karein: layers, legs, TP shift, trailing.
- Journal me har action print hota hai (`KV1: ...`). TP side shift hone par `>>> TP side shifted to SELL <<<` jaisa log aata hai.
- Chart lines: neeli = active group TP, orange = next layer, laal = protection leg, hari = next add-on, magenta = trail SL. Panel me LONG/SHORT dono group ka lot, weighted average, floating aur "TP side now" dikhta hai.
