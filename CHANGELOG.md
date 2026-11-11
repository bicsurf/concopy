# Changelog

Tutte le modifiche rilevanti a questo progetto sono documentate in questo file.

Il formato è basato su [Keep a Changelog](https://keepachangelog.com/it/1.1.0/)
e questo progetto aderisce a [Semantic Versioning](https://semver.org/lang/it/).

## [1.2.0] - 2026-11-11

### Aggiunto
- **Selezione Multipla Avanzata (Batch Copy / Paste)**:
  - Supporto completo a `⇧ + Click` e `⇧ + ↑/↓` per estendere o contrarre l'intervallo continuo di selezione con comportamento stile macOS Finder e gestione stabile del punto di ancoraggio (`selectionAnchorId`).
  - Selezione puntuale con `⌘ + Click` e tramite checkbox circolare su ogni riga dell'elenco.
  - Hit-area della checkbox isolata ed estesa a `28x28 pt` con `.contentShape(Rectangle())` per un puntamento mouse affidabile.
  - Protezione anticaduta: con selezione attiva, i click non combinati con tasti modificatori attivano il toggle senza deselezionare l'intero batch.
  - Incollaggio multiplo concatenato nell'ordine visivo dell'elenco con separatori configurabili (a capo, virgola, spazio, tab, ecc.) e supporto all'incollaggio sequenziale tramite Tab nei moduli web/desktop.
  - Barra inferiore dedicata con contatore dinamico (`X selezionati`), selettore del separatore, pulsanti di batch paste/copy e pulsante minimale `"X"` per la deselezione istantanea.
  - Scorciatoia `⌘C` per copiare l'intera selezione o la singola clip senza chiudere il pannello HUD (con notifica toast in-app).
- **Gestione Preferiti Rapida**:
  - Icona stella (★) interattiva direttamente sulla riga della clip per aggiungere o rimuovere dai preferiti con un solo click.
  - Scorciatoia da tastiera `⌘D` per la deselezione rapida (se il batch è attivo) o per il toggle dei preferiti sul record selezionato.
- **Scorciatoia Impostazioni**:
  - Scorciatoia rapida di sistema `⌘,` per aprire direttamente la finestra delle Preferenze.
- **Controllo Aggiornamenti Automatico (`UpdateChecker`)**:
  - Verifica automatica (a intervalli di 12 ore) e manuale dalle Impostazioni per nuove release disponibili su GitHub.
  - Banner nativo non-intrusivo per la notifica e il download diretto del file `.dmg` con opzione per ignorare versioni specifiche.
  - Parsing semantico affidabile dei tag versione (`SemanticVersion`).
- **Formula Homebrew Cask (`Casks/concopy.rb`)**:
  - Aggiunta formula Homebrew ufficiale per l'installazione nativa con `brew install --cask concopy`.
  - Allineamento automatico dei campi `version` e `sha256` in `scripts/build-app.sh`, `scripts/build-dmg.sh` e nella pipeline CI GitHub Actions.
- **Brand Identity & Icona Applicazione (`AppIcon.icns`)**:
  - Generatore nativo basato su CoreGraphics (`scripts/generate-icon.swift`) per l'icona dell'applicazione a 1024x1024 px con squircle macOS, gradiente scuro grafite, schede glassmorphic e stella a 4 punte ambra.
  - Packaging automatico in `scripts/build-app.sh` con 10 risoluzioni standard macOS via `sips` e compilazione `iconutil -c icns`.
- **Icona Vettoriale Barra dei Menu (`MenuBarIcon`)**:
  - Nuovo pittogramma vettoriale monocromatico a 18x18 pt (`isTemplate = true`) per `NSStatusItem` con schede sovrapposte, linee di snippet e stella a 4 punte con cutout trasparente.
- **Pipeline e Versioning Dinamico**:
  - Script `./scripts/build-app.sh` e `./scripts/build-dmg.sh` aggiornati per estrarre la versione direttamente dai tag Git, rimuovendo automaticamente il prefisso `v` e iniettandola nei metadati `Info.plist` del bundle.

### Modificato
- **UI Header-less Pulita**:
  - Rimozione dei pulsanti standard di macOS (chiudi, riduci a icona, ingrandisci) da `FloatingPanel` per un'interfaccia HUD essenziale e priva di ingombri.
- **Latenza Zero (0 ms)**:
  - Eliminato il ritardo artificiale di 600 ms in modalità "Solo copia", garantendo la scrittura immediata nel pasteboard e la chiusura istantanea della finestra.
- **Sincronizzazione Non-Bloccante su iCloud Drive**:
  - Rimosso completamente `CloudKit.framework` e tutte le dipendenze da `CKContainer` per eliminare crash sotto firma ad-hoc.
  - Introdotto `CloudDriveSyncWorker` basato su file JSON (`sync-state-v1.json`) nella directory locale di iCloud Drive, operante in background tramite `actor` dedicato con debounce a 3 secondi, gestione tombstones e rilevamento file `.icloud` non-bloccante.

### Risolto
- Risolto bug di deselezione improvvisa causato da click imprecisi in prossimità del glifo del cerchio.
- Risolto crash `CKException` all'avvio in ambienti con firma locale/ad-hoc privi di entitlement CloudKit.
- Prevenuta la selezione automatica non intenzionale del primo elemento all'inizio di una selezione multipla.

---

## [1.0.1] - 2026-03-24

### Risolto
- Risolto problema di individuazione del binario universale negli script di packaging escludendo file accessori.
- Correzione dei permessi di esecuzione e ottimizzazione della pipeline GitHub Actions con runner `macos-15`.
- Corretta inclusione delle risorse e dei bundle di terze parti all'interno del bundle macOS per la conformità `codesign`.

---

## [1.0.0] - 2026-03-15

### Aggiunto
- Rilascio iniziale di ConCopy per macOS (Sonoma 14+).
- Supporto Universal Binary (`arm64` Apple Silicon + `x86_64` Intel).
- Finestra HUD flessibile (`FloatingPanel`) a zero focus-stealing (`LSUIElement = true`).
- Cattura trasparente e automatica degli appunti di sistema (Testo, RTF, HTML, URL, File, Immagini).
- Database locale SQLite con `GRDB.swift` e ricerca full-text istantanea con FTS5 (**Type-to-Search**).
- Anteprima QuickLook per immagini ad alta risoluzione e testi lunghi (`Spazio` o `←`).
- Gestione Liste personalizzate, contrassegno Preferiti e modalità Auto-Star.
- Modulo dedicato agli Snippet di testo frequenti espandibili.
- Incolla sintetico rapido tramite `CGEvent` con mappatura tastiera indipendente da layout (`⌘1...9`, `⌘0`).
- Rispetto rigoroso della privacy con filtro automatico su password manager (1Password, tipi concealed/transient).
