# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni SemVer.

## [0.1.0-alpha.2] - 2026-10-20

Verifiche in gioco sulla build 1.60.1.70450 e primo acquisto assistito.

### Aggiunto

- Acquisto assistito sperimentale (disattivato di default, Impostazioni):
  preventivo del server per le commodity o ricerca dell'asta, poi un clic
  "Compra: spendi X" abilitato solo se il prezzo non supera piano, tetto per
  acquisto (default 50 silver) e oro disponibile. Nessun timer, nessun retry,
  esito incerto registrato da verificare.
- Registro degli acquisti e controllo al mercante: l'oro incassato viene
  confrontato con le unità vendute; se coincide, il prezzo vendor risulta
  verificato su questo client.
- Commodity riconosciute (`GetItemKeyInfo`): acquisto parziale al prezzo
  unitario, costo esatto sul book.
- Banner del guadagno (verificato / probabile / speculativo), righe colorate
  per classe, oro insufficiente in grigio, filtro "Solo verificati",
  dettaglio con "Come fare".
- Feedback della scansione in chat e barra di avanzamento.
- Evidenze salvate con ogni scansione (conteggi, base indice, campioni di
  stack, link grezzi, voti sul buyout).

### Modificato

- Chiave oggetto con bonus ID: su Forever le varianti arrivano così.
- Replica: nessun nuovo tentativo automatico; cooldown misurato (13 min 34 s
  – 16 min) usato per non inviare richieste inutili.
- "Verificato" richiede buyout e prezzo vendor provati in gioco.
- Interfaccia in linguaggio semplice: colonne "Cosa fare / Paghi / Ricevi /
  Guadagno / Affidabilità", una riga di istruzioni che dice cosa fare,
  barra di stato e footer senza gergo, tooltip sulle righe, pulsante
  "Attiva" degli acquisti assistiti direttamente nel dettaglio.
- Varianti dello stesso oggetto unite in una riga vendor; margini vendor
  sotto 25 rame o sotto il 5% nascosti (configurabili; migrazione schema 2).
- Lingua selezionabile: `/fg lang it|en|auto` o Impostazioni.
- L'ultima lista di opportunità sopravvive a `/reload` e relog; conto alla
  rovescia del cooldown sul pulsante di scansione e nella riga di istruzioni.
- Prezzo vendor verificato in gioco (primo acquisto assistito: +1s 60c):
  le opportunità vendor complete risultano "VERIFICATO".
- Dettaglio più corto; rimossi i pulsanti "Prepara" e "Aggiorna quotazione";
  un solo riepilogo in chat, con il conteggio finale.
- Scheda Portafoglio: guadagno realizzato, speso e incassato, oggetti ancora
  da vendere al mercante con il loro valore, esiti incerti, elenco degli
  acquisti dal più recente.

## [0.1.0-alpha.1] - 2026-10-20

Prima alpha di sola analisi, **non verificata in gioco**.

### Aggiunto

- Core economico puro: denaro in copper interi senza conversione di `nil` in
  zero, profondità per livelli, profitto/ROI/pareggio con arrotondamenti
  prudenti, depositi rimborsati e persi, punteggio di confidenza etichettato.
- Strategie vendor e rivendita AH con soglie configurabili (15% ROI, 10 silver)
  dichiarate come scelte di prodotto; disenchant, crafting e conversioni come
  funzioni pure con ranking disattivato.
- Scanner in sola lettura con macchina a stati, generazioni, timeout, retry
  limitati con backoff, lettura a blocchi con budget per frame, osservazione
  passiva delle ricerche dell'utente, ricerca mirata per aggiornare una
  quotazione.
- Storico locale per mercato e variante con retention, import/export testuale
  validato, migrazioni versionate su copia.
- UI nativa (Opportunità, Storico, Professioni, Portafoglio, Impostazioni),
  dettaglio con formula espansa, modalità demo etichettata, tooltip,
  localizzazione enUS e itIT.
- `/fg diagnostics` con report salvato e trace eventi limitato.
- Licenza MIT.
- Test offline (economia, replay scanner, app, UI su mock, pacchetto, lint
  dei globali sul bytecode), benchmark, build PowerShell con checksum.
