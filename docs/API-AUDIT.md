# ForeverGold — audit API

Stato al 2026-10-20. Nessuna voce è ancora `runtime_verified` su ForeverGold:
servono le sessioni descritte in `docs/TESTING-IN-GAME.md`.

<!-- verified: replicate=false replicateBuyoutIsTotal=false replicateIndexBase=false commoditySearch=false itemSearch=false itemSearchBuyoutIsTotal=false sellPrice=false persistence=false fee=false deposit=false -->

Il commento sopra è letto da `tests/test_package.lua`: ogni flag deve
coincidere con `Capabilities.VERIFIED` in `ForeverGold/Core/Capabilities.lua`
e diventa `true` solo insieme all'evidenza registrata qui.

Stati ammessi: `documented` (presente nella documentazione del client),
`present` (simbolo trovato da `/fg diagnostics` sul client target),
`runtime_verified` (comportamento osservato e registrato), `unsupported`,
`unknown`.

## Client target

| Voce | Valore | Stato | Evidenza |
| --- | --- | --- | --- |
| Prodotto | WoW Forever, flavor `wow_classic_beta`, cartella `_classic_beta_` | osservato sul disco | `C:\Program Files (x86)\World of Warcraft\.build.info` e `_classic_beta_\.flavor.info`, letti il 2026-10-20 |
| Build installata | 1.60.1.70450 | osservata sul disco, non da `GetBuildInfo` | `.build.info` (Version 1.60.1.70450) |
| Interface TOC | `16001` | verificata su build 1.60.1.70374 da un altro addon dello stesso proprietario; da riconfermare su 70450 | `forever-chatguard/docs/compatibility.md` (probe 2026-10-14: `GetBuildInfo()` → 16001, `WOW_PROJECT_ID` 18) |
| Runtime Lua | 5.1 (niente `goto`, `//`, bitwise) | verificato su 70374 (stessa fonte) | idem |
| Template UI usati | `UIPanelButtonTemplate`, `UICheckButtonTemplate`, `InputBoxTemplate`, `BasicFrameTemplateWithInset` | verificati su 70374 (stessa fonte) | idem |
| SavedVariables | scritte dal client in `WTF\Account\<account>\SavedVariables\` | verificato per altri addon; **non** per ForeverGold | file `ForeverChatGuard.lua`, `ForeverOneButton.lua` presenti |

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
| `C_AuctionHouse.GetReplicateItemLink` | `(index) → itemLink?` | variante (suffix) | documented | link disponibile con `hasAllInfo` falso? | variante sconosciuta → esclusa dalla rivendita |
| `C_AuctionHouse.IsThrottledMessageSystemReady` | `() → bool` | prontezza | documented | comportamento durante/dopo la replica | assente → si procede e si registra |
| `C_AuctionHouse.SendSearchQuery` | `(itemKey, sorts, separateOwnerItems, minLevel?, maxLevel?)`; 100 chiamate/minuto | solo "Aggiorna quotazione" su richiesta | documented | `sorts` vuoto accettato? evento di risposta | rifiuto con motivo |
| `C_AuctionHouse.MakeItemKey` | `(itemID, itemLevel?, itemSuffix?, battlePetSpeciesID?) → ItemKey` | chiave per la ricerca mirata | documented | suffix nel ruleset Forever | — |
| `C_AuctionHouse.GetCommoditySearchResultInfo` | `(itemID, index: luaIndex) → CommoditySearchResultInfo?` (quantity, unitPrice, auctionID, containsOwnerItem…) | osservazione passiva e quotazione | documented | esistono commodity su Forever? `unitPrice` per unità? | nessuna commodity → solo replica |
| `C_AuctionHouse.GetItemSearchResultInfo` | `(itemKey, index: luaIndex) → ItemSearchResultInfo?` (quantity, buyoutAmount?, auctionID…) | osservazione passiva e quotazione | documented | `buyoutAmount` totale o unitario per quantity > 1 | righe con quantity > 1 non acquistabili finché non verificato |
| `HasFull{Commodity,Item}SearchResults` | `(key) → bool` | completezza per oggetto | documented | — | nil → osservazione parziale |
| `CalculateItemDeposit` / `CalculateCommodityDeposit` | `(…, duration, quantity) → depositCost?` | non usate nel MVP (richiedono l'oggetto) | documented | durata, rimborso | deposito sconosciuto → escluso dal profitto e segnalato |
| `PlaceBid`, `StartCommoditiesPurchase`, `ConfirmCommoditiesPurchase` | — | **mai chiamate**: solo controllo di presenza | documented | in fase 6, con oggetto economico scelto dall'utente | — |
| `C_AuctionHouse.SupportsCopperValues` | `() → bool` | registrato in diagnostica | documented | significato su Forever | — |
| `C_Item.GetItemInfo` | 18 valori, `sellPrice` all'11ª posizione | prezzo vendor, nome, classe | documented | `sellPrice` coincide col vendor reale? cache fredda | nil → "prezzo vendor sconosciuto", nessuna opportunità |
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

1. Indice di `GetReplicateItemInfo`: 0 o 1? (rilevato a runtime; serve conferma nel trace)
2. `buyoutPrice` della replica: totale dello stack o per unità? → `/fg` Impostazioni → "Campiona prezzi stack" e confronto con la finestra AH.
3. Quanti `REPLICATE_ITEM_LIST_UPDATE` arrivano e dopo quanto? Esiste un cooldown osservabile?
4. Il client Forever usa commodity (ricerca per itemID) o solo aste individuali?
5. AH condivisa fra fazioni/realm? (finché ignoto la fazione resta nella `MarketKey`)
6. Commissione AH e depositi effettivi su una vendita reale (oggi scenario 5%).
7. `sellPrice` di `C_Item.GetItemInfo` uguale al prezzo pagato dal vendor?
8. Persistenza di `ForeverGoldDB` dopo `/reload`, logout/login, riavvio completo.
