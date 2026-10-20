# ForeverGold — registro delle decisioni

Decisioni reversibili prese durante lo sviluppo; ognuna indica il motivo e
come rivederla.

| # | Data | Decisione | Motivo | Revisione |
| --- | --- | --- | --- | --- |
| D1 | 2026-10-20 | Repository locale inizializzato con `git init -b main` e `origin` = `DoctorB/forever-gold` | Il remoto esiste, è pubblico e **vuoto** (`gh repo view`: `isEmpty: true`): nessuna storia concorrente; la cartella locale conteneva solo `docs/` | — |
| D2 | 2026-10-20 | Target: client `_classic_beta_` (build 1.60.1.70450), `## Interface: 16001` | Unico flavor Forever installato; 16001 verificato con `GetBuildInfo` su 70374 da un altro addon del proprietario | Riconfermare con `/fg diagnostics` sulla build corrente |
| D3 | 2026-10-20 | Struttura come nella specifica, con `Bootstrap.lua` in radice, `Core/App.lua` (wiring testabile), `Core/Init.lua` (colla client, ultimo nel TOC), `Services/Diagnostics.lua`, `Data/Exchange.lua`, `Data/Demo.lua`, `UI/Widgets.lua`, `UI/Panels.lua`, `UI/Commands.lua` | Stesso schema degli altri addon Forever del proprietario; la diagnostica e lo scambio dati meritano moduli propri | — |
| D4 | 2026-10-20 | Ordine TOC: namespace e localizzazione → core → **economia → adapter → dati** → strategie → servizi → app → UI → avvio | I moduli economici sono puri e servono a `Data/Schema` e `Data/History`; gli adapter non dipendono dai dati | La specifica suggeriva adapter prima di dati ed economia: differenza solo d'ordine di caricamento |
| D5 | 2026-10-20 | Lo scanner (`Services/Scanner.lua`) implementa la macchina a stati; l'adapter AH espone solo primitive di lettura ed eventi tradotti | Un solo punto con generazioni, timeout e retry; l'adapter resta sostituibile da un fake per i replay | Il contratto `AuctionAdapter:StartSnapshot` della specifica corrisponde a `Scanner:Start` |
| D6 | 2026-10-20 | `buyoutPrice` della replica **assunto come totale dello stack** finché non verificato; ogni opportunità che ne dipende ha la penalità `semanticsUnverified` e la classe vendor non diventa "confermata" | Coerente con l'API storica `GetAuctionItemInfo`, ma non dimostrato su Forever | Verifica con "Campiona prezzi stack" → flag `replicateBuyoutIsTotal` |
| D7 | 2026-10-20 | Righe di ricerca item con quantity > 1 non acquistabili finché `itemSearchBuyoutIsTotal` non è verificato | `buyoutAmount` potrebbe essere unitario o totale | Verifica in gioco |
| D8 | 2026-10-20 | Indice della replica rilevato a runtime (riga 0 valorizzata → base 0) | La documentazione indica `number`, non `luaIndex` | Conferma nel trace della diagnostica |
| D9 | 2026-10-20 | "Scansione completata" solo con `Capabilities.VERIFIED.replicate`; altrimenti stato "osservazione parziale" con copertura "lettura integrale, completezza non verificata" | Requisito della specifica (§6) | — |
| D10 | 2026-10-20 | Commissione AH di default **scenario 5%**, `feeVerified = false`: la rivendita resta "speculativa" finché non verificata | Nessuna tariffa Forever certificata | Misura su una vendita reale |
| D11 | 2026-10-20 | Depositi: senza valore noto il profitto li esclude e lo dichiara (`DEPOSIT_UNKNOWN`), la classe resta speculativa; scenario perdita depositi 50% quando noto | `CalculateItemDeposit` richiede l'oggetto in borsa | Fase 6 |
| D12 | 2026-10-20 | Algoritmo prezzo: peso per listing limitato a 5 unità, 30% più economico del peso, mediana pesata bassa; un campione al giorno (mediana bassa delle scansioni del giorno); riferimento 7 giorni con ≥3 giorni, altrimenti 30 giorni; prudente = min(riferimento, concorrente successivo) − buffer 5%; vendibile al massimo 20% della profondità tipica, il resto è inventario | Algoritmo originale iniziale (§7) | Calibrare con dati reali |
| D13 | 2026-10-20 | Rivendita: percorre il book ordinato una sola volta e si ferma al primo lotto con prezzo ≥ riferimento | Benchmark: da 6,5 s a 0,5 s per 3.000 chiavi | — |
| D14 | 2026-10-20 | Storico e valutazione eseguiti a passi con budget per frame (`frameBudgetMs`, default 2 ms) | 0,5 s per 3.000 chiavi non stanno in un frame | Misurare frame time in gioco |
| D15 | 2026-10-20 | Retention: dettagli 7 giorni, aggregati giornalieri 90 giorni, 10.000 chiavi per mercato, budget stimato 20 MB, LRU sulle chiavi non seguite; il ledger non viene mai potato | Politica iniziale della specifica | Misurare occupazione reale |
| D16 | 2026-10-20 | Import/export dello storico in formato a righe con validazione per pattern, limite 256 KB / 20.000 righe, nessun `loadstring`; l'import non sovrascrive giorni locali | §7 e §12 | — |
| D17 | 2026-10-20 | Disenchant, crafting e conversioni: funzioni pure testate, **ranking disattivato** (dataset DE vuoto, ricette non osservate) | §9.3–9.5: niente tabelle Retail/Vanilla come certe | Fasi 4–5 |
| D18 | 2026-10-20 | "Apri ricerca" non pilota la UI nativa: il dettaglio mostra il nome da cercare a mano, "Prepara" non spende, "Aggiorna quotazione" fa una ricerca mirata in sola lettura e rivaluta i lotti | Nessun aggancio non verificato alla UI Blizzard; nessun percorso verso una spesa | Fase 6 |
| D19 | 2026-10-20 | Modalità demo: dati fittizi "DEMO" in un mercato in memoria separato; pulsanti di preparazione disattivati | §16 punto 6 | — |
| D20 | 2026-10-20 | Build con `scripts/build.ps1` (PowerShell 5.1/7), ZIP creato con `System.IO.Compression` per avere separatori `/` | `Compress-Archive` di PowerShell 5.1 può scrivere `\` nei nomi | — |
| D21 | 2026-10-20 | Icona: `Media/ForeverGold.tga` 64×64 32 bit generata da `scripts/make-icon.ps1`, **non referenziata dal TOC** | §14: non presumere che la texture carichi | Provare `## IconTexture` in gioco |
| D22 | 2026-10-20 | Lint: controllo dei globali sul bytecode (`luac -l`) nei test; `.luacheckrc` pronto per luacheck in CI | luacheck non installato localmente | — |
| D23 | 2026-10-20 | Licenza MIT (`LICENSE`, `## X-License: MIT` nel TOC), inclusa nello ZIP | Scelta del proprietario, come per Forever ChatGuard | — |
