# ForeverGold

Addon di **analisi** della casa d'aste per **World of Warcraft: Forever**.
Individua occasioni economiche e spiega perché potrebbero convenire: prezzo
effettivo, quantità acquistabile, capitale, costi, profitto prudente,
freschezza dei dati, confidenza e vincoli. **Non compra, non mette all'asta e
non cancella nulla al posto tuo.**

> Stato: `0.1.0-alpha.1`, **alpha non verificata in gioco**. Le semantiche dei
> dati del client sono documentate in `docs/API-AUDIT.md` e restano marcate
> "non verificate" finché le prove di `docs/TESTING-IN-GAME.md` non sono fatte.

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
| `/fg demo` | dati fittizi etichettati DEMO |
| `/fg reset` | apre lo Storico per un azzeramento con conferma |

La tabella mostra sempre i denominatori (opportunità / candidati / chiavi
oggetto / righe / unità) e la copertura della scansione. Il punteggio di
confidenza è euristico ed etichettato: **non è una probabilità di guadagno**.
Un prezzo basso non garantisce una vendita futura.

## Limiti noti

- Nessuna voce API è ancora verificata su ForeverGold in gioco.
- La scansione completa usa `C_AuctionHouse.ReplicateItems`; il cooldown e la
  completezza non sono ancora misurati, quindi l'esito è sempre "osservazione
  parziale".
- Il buyout della replica è assunto come totale dello stack (da verificare).
- Commissione AH e depositi sono scenari dichiarati.
- Nessuna azione assistita (acquisto/vendita): fase successiva.

## Sviluppo

- Test offline: `lua5.1 tests/runner.lua` (Lua 5.1, nessuna dipendenza).
- Benchmark: `lua5.1 tests/bench.lua`.
- Pacchetto: `powershell -ExecutionPolicy Bypass -File scripts/build.ps1`
  → `release/ForeverGold-<versione>.zip` + `.sha256` + `manifest.json`.
- Icona texture: `scripts/make-icon.ps1` (TGA 64×64 dal PNG CurseForge).

Documenti: `docs/STATUS.md`, `docs/API-AUDIT.md`, `docs/DECISIONS.md`,
`docs/TESTING-IN-GAME.md` e la specifica di progetto in `docs/`.

## Licenza

Non ancora scelta dal proprietario: il pacchetto non è distribuibile finché
non viene aggiunto un file `LICENSE`.
