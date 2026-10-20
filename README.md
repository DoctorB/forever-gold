# ForeverGold

Addon di **analisi** della casa d'aste per **World of Warcraft: Forever**.
Individua occasioni economiche e spiega perché potrebbero convenire: prezzo
effettivo, quantità acquistabile, capitale, costi, profitto prudente,
freschezza dei dati, confidenza e vincoli. **Non compra mai da solo**: l'acquisto
assistito, opzionale, richiede un tuo clic per ogni acquisto. Non mette
all'asta e non cancella aste.

> Stato: `0.1.0-alpha.2`, alpha provata in parte in gioco sulla build
> 1.60.1.70450 (persistenza, replica, indice, buyout, cooldown). Il dettaglio
> di cosa è verificato è in `docs/API-AUDIT.md`.

## Cosa fa

- **Vendor arbitrage**: oggetti in asta che il mercante paga più del buyout
  (`quantità × prezzo vendor − buyout`, nessuna commissione AH).
- **Rivendita AH**: lotti sotto il riferimento storico locale, con
  profondità reale (somma dei livelli, mai "prezzo minimo × quantità"),
  commissione (scenario 5% finché non verificata), depositi, buffer prudente
  e quantità limitata dalla liquidità osservata. Senza storico sufficiente
  mostra solo uno scenario.
- **Storico locale** per mercato e variante: un campione al giorno, finestre
  7/30 giorni; prezzi richiesti e profondità, mai "volume venduto".
- **Diagnostica** (`/fg diagnostics`): build, simboli API, eventi, persistenza.
- **Acquisto assistito** (sperimentale, da Impostazioni): dal dettaglio
  "1. Preventivo" chiede il prezzo al server senza spendere; "2. Compra:
  spendi X" si abilita solo se il preventivo rientra nel piano, nel tetto per
  acquisto e nel tuo oro. Dopo la vendita al mercante ForeverGold confronta
  l'oro incassato col previsto.
- **Compra tutto**: mette in coda le offerte vendor entro il limite di spesa
  e prepara da solo ogni acquisto; tu premi lo stesso pulsante una volta per
  ogni acquisto (il gioco richiede un clic per ogni spesa).
- Disenchant, crafting e conversioni: calcoli pronti, ranking **disattivato**
  finché non esistono dati verificati per Forever.

## Installazione

1. Estrai lo ZIP in `World of Warcraft\_classic_beta_\Interface\AddOns\`
   (deve risultare `AddOns\ForeverGold\ForeverGold.toc`).
2. Abilita ForeverGold nella lista addon.

Backup e rollback: copia `WTF\Account\<account>\SavedVariables\ForeverGold.lua`
prima di aggiornare; per tornare indietro cancella la cartella dell'addon e
ripristina il file.

## Uso

| Comando | Effetto |
| --- | --- |
| `/fg` | apre/chiude la finestra (Opportunità · Storico · Professioni · Portafoglio · Impostazioni) |
| `/fg scan` | scansione in sola lettura; richiede l'AH aperta |
| `/fg cancel` | annulla la scansione |
| `/fg diagnostics` | report delle capacità del client, salvato nei SavedVariables |
| `/fg demo` | dati fittizi etichettati DEMO (il pulsante della finestra è ora "Compra tutto") |
| `/fg reset` | apre lo Storico per un azzeramento con conferma |

La tabella mostra sempre i denominatori (opportunità / candidati / chiavi
oggetto / righe / unità) e la copertura della scansione. Il punteggio di
confidenza è euristico ed etichettato: **non è una probabilità di guadagno**.
Un prezzo basso non garantisce una vendita futura.

## Limiti noti

- La scansione completa usa `C_AuctionHouse.ReplicateItems`, disponibile
  circa ogni 15 minuti (misurato fra 13 min 34 s e 16 min); la completezza
  non è dichiarata, quindi l'esito resta "osservazione parziale".
- Commissione AH e depositi sono scenari dichiarati: la rivendita resta
  speculativa.
- L'acquisto assistito è sperimentale; vendita al mercante e rimessa
  all'asta restano manuali.

## Sviluppo

- Test offline: `lua5.1 tests/runner.lua` (Lua 5.1, nessuna dipendenza).
- Benchmark: `lua5.1 tests/bench.lua`.
- Pacchetto: `powershell -ExecutionPolicy Bypass -File scripts/build.ps1`
  → `release/ForeverGold-<versione>.zip` + `.sha256` + `manifest.json`.
- Icona texture: `scripts/make-icon.ps1` (TGA 64×64 dal PNG CurseForge).

Documenti: `docs/STATUS.md`, `docs/API-AUDIT.md`, `docs/DECISIONS.md`,
`docs/TESTING-IN-GAME.md`.

## Licenza

MIT, vedi `LICENSE`.
