# ForeverGold — prove in gioco

Le prove offline usano mock e **non** dimostrano il comportamento del server.
Questa checklist trasforma le voci di `docs/API-AUDIT.md` in evidenze. Nessuna
prova richiede acquisti reali: ForeverGold 0.1.0-alpha.1 è in sola analisi.

## Installazione della alpha

1. Chiudi il gioco o resta alla schermata dei personaggi.
2. Fai un backup di `World of Warcraft\_classic_beta_\WTF\Account\<account>\SavedVariables\ForeverGold.lua` se esiste.
3. Estrai `release\ForeverGold-0.1.0-alpha.1.zip` in
   `World of Warcraft\_classic_beta_\Interface\AddOns\` (deve risultare
   `AddOns\ForeverGold\ForeverGold.toc`).
4. Avvia, abilita **ForeverGold** nella lista addon, entra con un personaggio.

**Rollback:** chiudi il gioco, cancella `Interface\AddOns\ForeverGold\` e, se
vuoi tornare ai dati precedenti, ripristina il backup di `ForeverGold.lua`
(oppure cancellalo per ripartire da zero).

## Sessione 1 — caricamento e diagnostica (senza AH)

| # | Azione | Esito atteso | Da registrare |
| --- | --- | --- | --- |
| 1.1 | Login | nessun errore Lua | eventuali errori (con `/console scriptErrors 1`) |
| 1.2 | `/fg diagnostics` | riepilogo in chat: build, simboli presenti, eventi registrati/rifiutati | testo in chat (o screenshot) |
| 1.3 | `/fg` | finestra con 5 schede; ridimensionabile; ESC chiude | screenshot a due risoluzioni/scale UI |
| 1.4 | `/fg demo` | tabella con dati etichettati DEMO; clic su una riga apre il dettaglio | screenshot |
| 1.5 | `/reload`, poi `/fg diagnostics` | "Caricamenti dei dati salvati" aumenta di 1 | numero |
| 1.6 | Logout/login e riavvio completo, poi `/fg diagnostics` | il contatore continua a crescere | numeri → flag `persistence` |

Dopo la sessione: invia `WTF\...\SavedVariables\ForeverGold.lua` (contiene
solo build, simboli, eventi, conteggi e trace; nessun nome di venditore).

## Sessione 2 — AH in sola lettura

| # | Azione | Esito atteso | Da registrare |
| --- | --- | --- | --- |
| 2.1 | Apri l'AH, `/fg scan` | stato: richiesta → ricezione → lettura → "osservazione parziale (completezza non ancora verificata)" | tempo totale, righe, chiavi, unità mostrate nella barra di stato |
| 2.2 | Durante la scansione | nessun blocco del gioco percepibile | FPS prima/durante (anche approssimativo) |
| 2.3 | `/fg scan` subito dopo | rifiuto o `no_response`: indica se esiste un cooldown | messaggio e tempo trascorso |
| 2.4 | Impostazioni → "Campiona prezzi stack" | "N righe multi-unità salvate" | poi `/reload` e invia il file: confronta 2–3 righe con la finestra AH (prezzo totale o unitario?) → flag `replicateBuyoutIsTotal` |
| 2.5 | Cerca a mano un materiale nell'AH nativa | la scheda Opportunità aggiorna l'oggetto (osservazione passiva) | se l'oggetto è commodity o asta individuale |
| 2.6 | Chiudi l'AH durante una scansione | stato annullato o parziale "AH chiusa", nessun errore | screenshot |
| 2.7 | Dettaglio di un'opportunità vendor | formula espansa; confronta il prezzo vendor con quello reale del mercante | prezzo reale → flag `sellPrice` |
| 2.8 | Dettaglio → "Aggiorna quotazione" | "quotazione ancora valida/cambiata" | esito |
| 2.9 | Con un addon AH diffuso attivo (es. Auctionator), ripeti 2.1 e 2.5 | nessun errore; eventuale sospensione `search_changed` | esito |

## Misure richieste

- Frame time durante la lettura con budget 2 ms (Impostazioni non lo espone
  ancora: valore di default).
- Memoria dell'addon dopo una scansione (`/run UpdateAddOnMemoryUsage() print(GetAddOnMemoryUsage("ForeverGold"))`, se disponibile su Forever).
- Dimensione di `ForeverGold.lua` dopo 1, 3 e 7 giorni.

## Non richiesto per l'alpha

Acquisti, aste, cancellazioni: non implementati. Le verifiche mutative della
fase 6 useranno un oggetto economico scelto dal proprietario.
