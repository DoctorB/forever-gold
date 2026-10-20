# ForeverGold — stato

Aggiornato: 2026-10-20 · versione `0.1.0-alpha.2` · **alpha provata in parte in gioco**

## Fase corrente

| Fase | Stato | Gate |
| --- | --- | --- |
| 0 — Scoperta | fatta (offline) | audit in `docs/API-AUDIT.md`, decisioni in `docs/DECISIONS.md`; nessuna API inventata. Le voci restano `documented` finché `/fg diagnostics` non gira sul client |
| 1 — Fondamenta | fatta | test economici e migrazioni verdi |
| 2 — Scanner | fatta su fake | replay robusti verdi; completezza dichiarata "non verificata" |
| 3 — MVP | alpha provata in gioco (scansione, storico, UI) | dati spiegabili; nessuna spesa automatica (test statico) |
| 6 — Assistenza | **anticipata, sperimentale** (alpha.2) | acquisto assistito un clic alla volta; da provare in gioco con budget piccolo |
| 4–7 | non iniziate | contratti e funzioni pure predisposti per DE, crafting, conversioni |

Sessioni in gioco del 2026-10-20 (build 1.60.1.70450): caricamento,
diagnostica (26/26 simboli, 8/8 eventi), UI e demo, **persistenza verificata**
(`/reload`, relog, riavvio), prima replica reale (2.081 chiavi, 29.449 aste,
204.636 unità in ~31 s), seconda scansione completa (31.058 righe, 0 scarti,
38 s), indice 0-based verificato, cooldown della replica misurato fra
13 min 34 s e 16 min, varianti come bonus ID, buyout della replica = totale
dello stack (verificato), AH moderna a commodity. Dettagli in
`docs/API-AUDIT.md`.

**Primo guadagno reale (2026-10-20 13:59–14:00):** 8 Pyrite comprate con
l'acquisto assistito per 6s 40c e vendute al mercante per 8s: +1s 60c,
prezzo vendor verificato. Le opportunità vendor complete ora risultano
"VERIFICATO".

Alpha.2: acquisto assistito sperimentale (un clic per acquisto, tetto e
controllo del preventivo), registro e controllo al mercante, commodity
riconosciute, banner del guadagno. Prossima prova: sessione 3 di
`docs/TESTING-IN-GAME.md` con un budget piccolo.

Gate precedente: una scansione con lo scanner aggiornato per leggere dal file
base dell'indice, conteggi, campioni di stack e link grezzi; confronto di 2–3
campioni con la finestra AH; misura del cooldown.

## Implementato

- `Economy/`: Money (copper interi, `nil` mai zero, range sicuro, arrotondamenti
  costi ↑ ricavi ↓), Depth (livelli divisibili e lotti interi), Costs (§8),
  MarketValue (prezzo robusto per intervallo, campione giornaliero, finestre
  1/7/30, prezzo prudente con liquidità), Risk (gate e punteggio etichettato).
- `Data/`: Schema (MarketKey, ItemKey con variante, Listing, Snapshot), Store
  (SavedVariables, modalità sessione), Migrations (su copia, recupero),
  History (a passi, retention, tetto dettagli, budget), Exchange (import/export
  validato), dataset DE/ricette vuoti e versionati, Demo.
- `Strategies/`: Vendor e Resale attive; Disenchant (EV, distribuzione,
  probabilità di perdita), Crafting (piano, costo monetario vs opportunità),
  Conversion (ricerca limitata su registro risorse, cicli bloccati) con ranking
  disattivato.
- `Compat/`: ClientAdapter (presenza simboli, build, mercato, eventi validati),
  AuctionHouse (sola lettura, nomi venditori scartati), Items (asincrono,
  coda limitata, timeout), Professions (solo presenza).
- `Services/`: Scanner (stati, generazioni, timeout, retry con backoff e
  jitter, lettura a blocchi, osservazione passiva deduplicata, ricerca mirata,
  sospensione su ricerca altrui), Opportunities (a passi, ranking, allocazione
  budget/riserva/tetti), Transactions (prepara e rivaluta, nessuna spesa),
  Diagnostics.
- `UI/`: finestra ridimensionabile a 5 schede, tabella con denominatori,
  copertura e motivi di esclusione, dettaglio con formula espansa, demo
  etichettata, impostazioni validate, storico con export/import e reset
  confermato, tooltip, `/fg`, enUS + itIT.

## Prove eseguite (2026-10-20, Windows, Lua 5.1.5)

- `lua5.1 tests/runner.lua` → **134 passed, 0 failed**: casi deterministici
  della §13 (vendor 300, unitario 500, profondità 600, esempio §8 900/11.053,
  prezzo assente, deposito, DE 100/50%, crafting 2 craft/4 output, storico non
  condiviso, ciclo di conversione, import malformato/oversize), proprietà
  (costo non decrescente in q, profitto non crescente con la commissione,
  vendor indipendente dalla fee, scansione parziale non aumenta la
  confidenza), replay scanner (duplicati, ritardi, mancanze, fuori ordine,
  throttle, AH chiusa in ricezione e in lettura, riapertura, cache fredda,
  ricerca altrui, timeout, annullamento), app end-to-end su client finto,
  UI su mock dei frame, locali, pacchetto (TOC, divieti, nessuna chiamata di
  spesa, lint dei globali sul bytecode, versioni, flag verificati ↔ audit).
- `lua5.1 tests/bench.lua` (ordine di grandezza su desktop, non in gioco):
  storico 0,29 s per snapshot da 30.000 righe; valutazione 0,30 s per 3.000
  chiavi → eseguite a passi con budget 2 ms/frame; storico stimato 11,8 MB
  dopo 10 giorni (budget 20 MB); picco heap +50 MB di garbage durante la
  valutazione (da misurare in gioco).
- `scripts/build.ps1` → `release/ForeverGold-0.1.0-alpha.2.zip`, 51 file,
  SHA-256 `c121e91e1896674d44e4b6403c9c328e1ba641c39e41e99223dc5d31e04987de`.

Nessuna prova in gioco è stata eseguita: i mock non dimostrano il
comportamento del server.

## Limiti

- Completezza della replica, commissione AH e depositi non verificati: esito
  delle scansioni "osservazione parziale"; rivendita sempre "speculativa".
- Righe della replica delle commodity trattate come lotti interi (acquisto
  parziale non ancora modellato).
- Nessuna azione assistita; "Prepara" produce solo un riepilogo.
- Grafico storico non ancora presente (la scheda Storico è testuale).
- Icona TGA generata ma non referenziata dal TOC.
- luacheck non disponibile in locale: in CI è informativo; il lint bloccante
  è il controllo dei globali sul bytecode.

## Blocker e dato minimo per sbloccarli

| Blocker | Dato o prova minima |
| --- | --- |
| Commodity nella replica | verifica di `C_AuctionHouse.GetItemKeyInfo` (`isCommodity`) su un oggetto noto |
| Indice e completezza della replica | trace di `/fg scan` (in `ForeverGold.lua` dopo `/reload`) con righe lette vs mostrate dall'AH |
| Cooldown della replica | > 76 s osservato; ritentare `/fg scan` dopo 5, 10, 15 minuti |
| Suffissi degli oggetti | i `links` salvati con la scansione (nessun suffisso visto su 2.081 chiavi) |
| Commodity su Forever | una ricerca manuale di un materiale con l'addon attivo |
| `sellPrice` | prezzo pagato dal mercante per un oggetto proposto |
| Commissione AH | una vendita reale qualsiasi del proprietario (importo e incasso) |
