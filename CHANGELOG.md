# Changelog

Formato: [Keep a Changelog](https://keepachangelog.com/it/1.1.0/), versioni SemVer.

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
