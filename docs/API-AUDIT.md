# ForeverGold — audit API

Stato al 2026-10-20, dopo la sessione 1. Tutti i simboli della matrice sono
`present` sulla build 70450; nessuna semantica è ancora `runtime_verified`
(servono le prove AH di `docs/TESTING-IN-GAME.md`).

<!-- verified: replicate=false replicateBuyoutIsTotal=true replicateIndexBase=true commoditySearch=false itemSearch=false itemSearchBuyoutIsTotal=false sellPrice=true persistence=true fee=false deposit=false -->

Il commento sopra è letto da `tests/test_package.lua`: ogni flag deve
coincidere con `Capabilities.VERIFIED` in `ForeverGold/Core/Capabilities.lua`
e diventa `true` solo insieme all'evidenza registrata qui.

Stati ammessi: `documented` (presente nella documentazione del client),
`present` (simbolo trovato da `/fg diagnostics` sul client target),
`runtime_verified` (comportamento osservato e registrato), `unsupported`,
`unknown`.

## Sessioni di verifica

| Data | Build | Metodo | Esito |
| --- | --- | --- | --- |
| 2026-10-20 (1) | 1.60.1.70450 (`GetBuildInfo`, compilata il 15 ottobre 2026) | ForeverGold 0.1.0-alpha.1, `/fg diagnostics`, realm `ClassicBetaPvE`, fazione Alliance; file `ForeverGold.lua` scritto dal client alle 12:51 | addon caricato con `Interface 16001`; 26/26 simboli presenti; 8/8 eventi accettati da `C_EventUtils.IsEventValid` e registrati; `SupportsCopperValues()` → `true`; `GetCurrentRegion()` → 110; SavedVariables **scritte** (rilettura non ancora provata: `loads = 1`) |
| 2026-10-20 (2) | 1.60.1.70450 | `/reload` + `/fg diagnostics`; file riscritto alle 12:53 | `loads = 2`, `previousLoad` = primo caricamento (12:47:54), `created` invariato: dati **riletti dopo `/reload`** e non azzerati. Mancano logout/login e riavvio completo |
| 2026-10-20 (3) | 1.60.1.70450 | relog e riavvio completo del client | `loads` 3 (relog 12:53:12), 4 (12:54:16), 5 dopo il riavvio (12:56:55, `previousLoad` = 12:54:16): **persistenza verificata** nei tre passaggi |
| 2026-10-20 (4) | 1.60.1.70450 | AH aperta, `/fg scan` alle 12:57:19, secondo `/fg scan` alle 12:58:09, AH chiusa alle 12:59:25 | prima replica letta in ~31 s: 2.081 chiavi oggetto, 29.449 aste acquistabili, 204.636 unità; esito parziale `rows_incomplete`. Durante la lettura il client ha inviato **centinaia di `REPLICATE_ITEM_LIST_UPDATE`** (≥ 190 in ~1 s). La seconda richiesta, 19 s dopo la fine della prima, **non ha ricevuto risposta per 76 s** (retry incluso): cooldown della replica > 76 s, durata ignota. Nessuna chiave con suffisso diverso da 0 su 2.081. Base dell'indice e conteggio righe persi perché il trace era saturato |
| 2026-10-20 (5) | 1.60.1.70450 | ForeverGold con feedback; `/fg scan` alle 13:03:29 (+2 retry automatici), 13:06:19 (+1 retry) | **nessuna risposta** a nessuna delle 7 richieste fra 12:58:09 e 13:07:25: cooldown della replica **≥ 10 min 6 s** dall'ultima scansione riuscita (12:57:19). Non sappiamo se le richieste durante il cooldown lo prolunghino: da ora nessun retry automatico e pausa di 5 min dopo ogni richiesta senza risposta. `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` arriva durante l'attesa (non indica la fine del cooldown). Una ricerca manuale (itemID 2516, commodity) ha prodotto `COMMODITY_SEARCH_RESULTS_UPDATED` |
| 2026-10-20 (6) | 1.60.1.70450 | ForeverGold con richieste non ripetute; `/fg scan` alle 13:13:19, AH chiusa alle 13:14:23 | **risposta** dopo 6 s (13:13:25); 31.058 righe lette con base indice **0**, 0 scartate, 0 incomplete dopo 2 riletture; 2.575 chiavi, 210.676 unità; scansione completa in 38 s; 3.084 `REPLICATE_ITEM_LIST_UPDATE` durante la lettura. Cooldown: silenzio a +13 min 34 s, risposta a +16 min dall'ultima scansione riuscita; una richiesta 4 min 11 s dopo una silenziosa è rimasta silenziosa, quindi le richieste senza risposta **non** fanno ripartire il cooldown. Link: il campo suffisso è vuoto, le varianti arrivano come **bonus ID** (`item:15268::::::::20:1486::1:1:12730:1:28:5256`) |
| 2026-10-20 (7) | 1.60.1.70450 | Confronto dei campioni della replica (13:13) con la finestra AH nativa (screenshot 13:20 e 13:21) | La UI AH di Forever è quella **moderna a commodity** ("Browse Auctions": prezzo minimo per unità, quantità disponibile aggregata). Campioni letti come totale dello stack → prezzo unitario coerente col minimo mostrato: Goretusk Liver 7 × 3s 98c (minimo 2s 99c), Goretusk Liver Pie 5 × 1s (minimo 79c), Murloc Eye 6 × 39c (minimo 16c); letti come unitari sarebbero 6–15 volte il minimo. Inoltre **8/8 campioni sono multipli esatti della quantità** (2786 = 7 × 398, 234 = 6 × 39, 3995 = 5 × 799…). → `replicateBuyoutIsTotal` **verificato** |
| 2026-10-20 (8) | 1.60.1.70450 | ForeverGold 0.1.0-alpha.2, acquisto assistito: scansione 13:55, dettaglio Pyrite (commodity), "1. Preventivo", "2. Compra", vendita al mercante | `GetItemKeyInfo().isCommodity` = vero per Pyrite; `StartCommoditiesPurchase` → `COMMODITY_PRICE_UPDATED`; `ConfirmCommoditiesPurchase` chiamato dal clic del pulsante **accettato** → `COMMODITY_PURCHASE_SUCCEEDED` (13:59:17): 8 Pyrite, oro speso 640 = preventivo. Al mercante (14:00:12): 8 vendute, attesi 800, incassati 800 → **`sellPrice` verificato**, guadagno realizzato 160 rame. `GetMoney` e `GetItemCount` funzionano |

## Client target

| Voce | Valore | Stato | Evidenza |
| --- | --- | --- | --- |
| Prodotto | WoW Forever, flavor `wow_classic_beta`, cartella `_classic_beta_`, `WOW_PROJECT_ID` 18 | verificato | `.build.info`, `.flavor.info`; diagnostica 2026-10-20 |
| Build | 1.60.1.70450 | verificata | `GetBuildInfo()` → `"1.60.1", "70450", "Oct 15 2026", 16001` |
| Interface TOC | `16001` | verificata | `GetBuildInfo()` su 70450; ForeverGold caricato con quel valore |
| Mercato | product `p18`, region `110`, realm `ClassicBetaPvE`, faction `Alliance` | osservato | diagnostica; la regione 110 non è uno dei codici Retail 1–5: resta solo parte della chiave |
| Runtime Lua | 5.1 (niente `goto`, `//`, bitwise) | verificato su 70374 (stessa fonte) | idem |
| Template UI usati | `UIPanelButtonTemplate`, `UICheckButtonTemplate`, `InputBoxTemplate`, `BasicFrameTemplateWithInset` | verificati su 70374 (stessa fonte) | idem |
| SavedVariables | scritte dal client in `WTF\Account\<account>\SavedVariables\` | **verificata** (flag `persistence`) | `ForeverGold.lua`: `loads` 1 → 5 dopo `/reload`, relog e riavvio, 2026-10-20 |

## Fonti documentali

| Fonte | Riferimento immutabile | Uso |
| --- | --- | --- |
| Estrazione API Forever (Atraeau/WoW-Addons) | commit `d8c9be3635e756fd90284e02b5a800c796b337a0` (2026-10-03), build 70170, interface 16001 | firme, tipi, eventi; esempi autogenerati **ignorati** |
| `docs/api/Auction-Mail-Trade/C_AuctionHouse.md` | stesso commit | AH |
| `docs/api/Items-Inventory/C_Item.md` | stesso commit | item, `sellPrice` |
| Mirror Blizzard Retail (Gethe/wow-ui-source, branch `live`) | branch mobile: solo confronto | non usato come prova |

## Funzioni

Unità monetaria attesa: copper. I campi `BigUInteger` sono trattati come
`number` solo se arrivano come numeri finiti, interi e ≤ 2^53−1; altrimenti la
riga è scartata con motivo (`Money.Normalize`), mai convertita con perdita.

| Funzione | Firma documentata (70170) | Uso in ForeverGold | Stato | Da verificare in gioco | Fallback |
| --- | --- | --- | --- | --- | --- |
| `GetBuildInfo` | `() → version, build, date, interface` | diagnostica, `MarketKey` | documented | valori reali su 70450 | campo sconosciuto = partizione isolata |
| `C_AuctionHouse.ReplicateItems` | `()`; "da usare al posto della query allItem" | scansione su richiesta utente | documented | evento successivo, ritardo, cooldown, dati con AH chiusa | stato FAILED `no_response` dopo retry limitati; osservazione passiva |
| `C_AuctionHouse.GetNumReplicateItems` | `() → number` | conteggio righe | documented | valore prima/dopo l'evento | FAILED `count_unavailable` |
| `C_AuctionHouse.GetReplicateItemInfo` | `(index: number)` → 18 valori: name, texture, count, qualityID, usable, level, levelType, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo | righe asta | documented | **base dell'indice** (0 o 1: rilevata leggendo l'indice 0), **buyoutPrice totale dello stack o unitario**, valore 0 senza buyout, `hasAllInfo` | indice: rilevamento automatico; buyout: assunto totale, confidenza penalizzata (`semanticsUnverified`) |
| `C_AuctionHouse.GetReplicateItemLink` | `(index) → itemLink?` | variante (bonus ID; suffisso vuoto su Forever) | runtime_verified (formato) | link disponibile con `hasAllInfo` falso? | variante sconosciuta → esclusa dalla rivendita |
| `C_AuctionHouse.IsThrottledMessageSystemReady` | `() → bool` | prontezza | documented | comportamento durante/dopo la replica | assente → si procede e si registra |
| `C_AuctionHouse.SendSearchQuery` | `(itemKey, sorts, separateOwnerItems, minLevel?, maxLevel?)`; 100 chiamate/minuto | solo "Aggiorna quotazione" su richiesta | documented | `sorts` vuoto accettato? evento di risposta | rifiuto con motivo |
| `C_AuctionHouse.MakeItemKey` | `(itemID, itemLevel?, itemSuffix?, battlePetSpeciesID?) → ItemKey` | chiave per la ricerca mirata | documented | suffix nel ruleset Forever | — |
| `C_AuctionHouse.GetCommoditySearchResultInfo` | `(itemID, index: luaIndex) → CommoditySearchResultInfo?` (quantity, unitPrice, auctionID, containsOwnerItem…) | osservazione passiva e quotazione | documented | esistono commodity su Forever? `unitPrice` per unità? | nessuna commodity → solo replica |
| `C_AuctionHouse.GetItemSearchResultInfo` | `(itemKey, index: luaIndex) → ItemSearchResultInfo?` (quantity, buyoutAmount?, auctionID…) | osservazione passiva e quotazione | documented | `buyoutAmount` totale o unitario per quantity > 1 | righe con quantity > 1 non acquistabili finché non verificato |
| `HasFull{Commodity,Item}SearchResults` | `(key) → bool` | completezza per oggetto | documented | — | nil → osservazione parziale |
| `CalculateItemDeposit` / `CalculateCommodityDeposit` | `(…, duration, quantity) → depositCost?` | non usate nel MVP (richiedono l'oggetto) | documented | durata, rimborso | deposito sconosciuto → escluso dal profitto e segnalato |
| `StartCommoditiesPurchase(itemID, quantity)` | preventivo → `COMMODITY_PRICE_UPDATED(unit, total)` / `COMMODITY_PRICE_UNAVAILABLE` | acquisto assistito, passo 1 (non spende) | **runtime_verified** (sessione 8) | evento e valori del preventivo | preventivo assente in 10 s → interrotto |
| `ConfirmCommoditiesPurchase(itemID, quantity)` | → `COMMODITY_PURCHASE_SUCCEEDED` / `_FAILED` | acquisto assistito, passo 2, solo da clic | **runtime_verified** da clic (sessione 8) | richiede evento hardware? esito | nessuna risposta in 20 s → "incerto", mai ritentato |
| `PlaceBid(auctionID, bidAmount)` | → `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` / `ITEM_PURCHASED(itemID)` | acquisto assistito di un'asta individuale, solo da clic, al buyout | present | esito ed errori | idem |
| `CancelCommoditiesPurchase`, `GetQuoteDurationRemaining` | — | annulla un preventivo rifiutato; scadenza del preventivo | present (da diagnostica alpha.2) | durata del preventivo | preventivo scaduto → nuovo preventivo |
| `GetItemKeyInfo(itemKey)` | → `ItemKeyInfo.isCommodity`; può arrivare dopo `ITEM_KEY_ITEM_INFO_RECEIVED` | riconoscimento commodity | **runtime_verified** (Pyrite) | valore per un materiale noto | ignoto → righe trattate come lotti interi |
| `GetMoney`, `GetItemCount` | — | oro e borse per tetto e controllo al mercante | **runtime_verified** | — | ignoto → acquisto non pianificato |
| `C_AuctionHouse.SupportsCopperValues` | `() → bool` | registrato in diagnostica | documented | significato su Forever | — |
| `C_Item.GetItemInfo` | 18 valori, `sellPrice` all'11ª posizione | prezzo vendor, nome, classe | **runtime_verified** (`sellPrice` = prezzo del mercante, sessione 8) | cache fredda | nil → "prezzo vendor sconosciuto", nessuna opportunità |
| `C_Item.RequestLoadItemDataByID` + `GET_ITEM_INFO_RECEIVED` | — | caricamento asincrono | documented | evento e argomenti | timeout 5 s, coda limitata a 200 |
| `C_TradeSkillUI.GetRecipeInfo`, `GetRecipeSchematic` | `GetRecipeSchematic(recipeSpellID, isRecraft, recipeLevel?)` | solo presenza (fase 4) | documented | contesto richiesto | professioni disattivate |
| `C_EventUtils.IsEventValid` | — | registra solo eventi validi | non nella tabella AH | presenza | senza, `RegisterEvent` in `pcall` |

## Eventi candidati

Registrati solo se `C_EventUtils.IsEventValid` non li rifiuta; gli esiti
finiscono in `ForeverGoldDB.diagnostics.report.events`.

| Evento | Payload documentato | Uso |
| --- | --- | --- |
| `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED` | — | apertura/chiusura; la chiusura annulla timer e invalida i preventivi |
| `REPLICATE_ITEM_LIST_UPDATE` | — | ricezione replica (attesa di 2 s senza nuovi eventi prima di leggere) |
| `COMMODITY_SEARCH_RESULTS_UPDATED` | `itemID` | osservazione passiva / quotazione |
| `ITEM_SEARCH_RESULTS_UPDATED` | `itemKey`, `newAuctionID?` | osservazione passiva / quotazione |
| `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED` | — | ripresa dopo throttle; tracciati |
| `GET_ITEM_INFO_RECEIVED` | `itemID`, `success` | cache item |

## Domande aperte (bloccano la promozione a "verificato")

1. Indice di `GetReplicateItemInfo`: 0 o 1? Dalla 2ª scansione il valore è salvato con lo snapshot (`indexBase`).
2. `buyoutPrice` della replica: **totale dello stack**, verificato (sessione 7).
3. Cooldown della replica: ≥ 10 min 6 s osservato; lo scanner salva ora in `ForeverGoldDB.scanner` i limiti misurati (`lowerBound`, `upperBound`) a ogni tentativo. Gli aggiornamenti durante la lettura sono ora contati (`lateUpdates`) e le righe incomplete rilette fino a 4 volte.
9. Formato dei link: risolto. Suffisso vuoto, varianti nei bonus ID (campo 13 = numero, poi gli ID); la chiave oggetto include ora i bonus ID ordinati (`i:15268:0:b12730`). Resta da capire il modificatore `28:5256`.
10. Significato del buyout della replica: ogni scansione salva ora `buyoutVotes` (stack confrontati con le aste singole dello stesso oggetto) come evidenza statistica, da confermare con 2–3 confronti nella finestra AH.
4. Commodity: **sì**, la UI AH è quella moderna a commodity. Da fare: riconoscere quali oggetti sono commodity (es. `GetItemKeyInfo().isCommodity`) per trattare le loro righe della replica come divisibili (acquisto parziale al prezzo unitario).
5. AH condivisa fra fazioni/realm? (finché ignoto la fazione resta nella `MarketKey`)
6. Commissione AH e depositi effettivi su una vendita reale (oggi scenario 5%).
7. `sellPrice` di `C_Item.GetItemInfo` uguale al prezzo pagato dal vendor?
8. Persistenza di `ForeverGoldDB` dopo `/reload`, logout/login, riavvio completo.
