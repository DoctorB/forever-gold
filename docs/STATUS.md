# ForeverGold — stato

Aggiornato: 2026-10-20 · versione `0.1.0-alpha.1` · **alpha non verificata in gioco**

## Fase corrente

| Fase | Stato | Gate |
| --- | --- | --- |
| 0 — Scoperta | fatta (offline) | audit in `docs/API-AUDIT.md`, decisioni in `docs/DECISIONS.md`; nessuna API inventata. Le voci restano `documented` finché `/fg diagnostics` non gira sul client |
| 1 — Fondamenta | fatta | test economici e migrazioni verdi |
| 2 — Scanner | fatta su fake | replay robusti verdi; completezza dichiarata "non verificata" |
| 3 — MVP | **alpha pronta, in attesa delle prove in gioco** | ZIP alpha costruito; dati spiegabili; zero spese (verificato da test statico) |
| 4–7 | non iniziate | contratti e funzioni pure predisposti per DE, crafting, conversioni |

Sessioni in gioco del 2026-10-20 (build 1.60.1.70450): caricamento,
diagnostica (26/26 simboli, 8/8 eventi), UI e demo, **persistenza verificata**
(`/reload`, relog, riavvio), prima replica reale (2.081 chiavi, 29.449 aste,
204.636 unità in ~31 s), cooldown della replica ≥ 10 min. Dettagli in
`docs/API-AUDIT.md`.

Prossimo gate: una scansione con lo scanner aggiornato per leggere dal file
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

- `lua5.1 tests/runner.lua` → **103 passed, 0 failed**: casi deterministici
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
- `scripts/build.ps1` → `release/ForeverGold-0.1.0-alpha.1.zip`, 47 file,
  SHA-256 `377f4e49b8967bb524c39946aa878abe67c093d2458c5caef6ed2fdd745c9c86`.

Nessuna prova in gioco è stata eseguita: i mock non dimostrano il
comportamento del server.

## Limiti

- Nessuna semantica del client verificata (`Capabilities.VERIFIED` tutto
  `false`): esito delle scansioni sempre "osservazione parziale"; vendor mai
  "confermato"; rivendita sempre "speculativa" (commissione scenario).
- Buyout della replica assunto come totale dello stack.
- Nessuna azione assistita; "Prepara" produce solo un riepilogo.
- Grafico storico non ancora presente (la scheda Storico è testuale).
- Icona TGA generata ma non referenziata dal TOC.
- luacheck non disponibile in locale: in CI è informativo; il lint bloccante
  è il controllo dei globali sul bytecode.

## Blocker e dato minimo per sbloccarli

| Blocker | Dato o prova minima |
| --- | --- |
| Semantica `buyoutPrice` della replica | 2–3 dei `samples` salvati con la scansione confrontati con la finestra AH |
| Indice e completezza della replica | trace di `/fg scan` (in `ForeverGold.lua` dopo `/reload`) con righe lette vs mostrate dall'AH |
| Cooldown della replica | > 76 s osservato; ritentare `/fg scan` dopo 5, 10, 15 minuti |
| Suffissi degli oggetti | i `links` salvati con la scansione (nessun suffisso visto su 2.081 chiavi) |
| Commodity su Forever | una ricerca manuale di un materiale con l'addon attivo |
| `sellPrice` | prezzo pagato dal mercante per un oggetto proposto |
| Commissione AH | una vendita reale qualsiasi del proprietario (importo e incasso) |
