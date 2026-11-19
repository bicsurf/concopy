# ConCopy - Direttive Architetturali & Regole per Agenti AI

Questo documento definisce le regole di sistema, i vincoli architetturali e i pattern ingegneristici obbligatori per qualsiasi agente AI o sviluppatore che operi sul repository `concopy`.

---

## 1. Architettura a 3 Target (Regole di Isolamento)

Il progetto è strutturato rigorosamente in tre target Swift Package Manager (SPM):

```
Sources/
  ├── ConCopyCore (Libreria statica)
  ├── ConCopyUI   (Libreria statica)
  └── ConCopyApp  (Eseguibile standalone macOS)
```

1. **`ConCopyCore`**:
   - **Nessuna dipendenza da SwiftUI**: Non importare mai `SwiftUI`, `NSView`, `NSWindow`, o viste grafiche in questo target.
   - Responsabilità: Monitoraggio `NSPasteboard`, sanitizzazione query e storage SQLite con `GRDB.swift` + `FTS5`, deduplicazione crittografica SHA-256, I/O dei blob su disco, iniezione sintetica di eventi `CGEvent`, watcher del filesystem, sincronizzazione non-bloccante su `iCloud Drive` e backup JSON.
   - **Concorrenza & Threading**: I/O, parsing e calcoli pesanti devono avvenire su thread secondari o `actor` dedicati, mai vincolati a `@MainActor`.

2. **`ConCopyUI`**:
   - Dipende esclusivamente da `ConCopyCore` e `KeyboardShortcuts`.
   - Responsabilità: Finestra flottante HUD (`FloatingPanel` basato su `NSPanel`), viste SwiftUI per l'elenco delle clip, popover di anteprima QuickLook, pannello preferenze (`PreferencesView`).
   - Gestione dello stato dell'interfaccia coordinata da `ClipboardViewModel` annotato con `@MainActor`.

3. **`ConCopyApp`**:
   - Dipende da `ConCopyCore` e `ConCopyUI`.
   - Configurato come menubar app invisibile nel Dock (`LSUIElement = true`).
   - Responsabilità: `AppDelegate`, ciclo di vita dell'applicazione, `NSStatusItem`, registrazione della scorciatoia globale, verifica permessi di Accessibilità.

---

## 2. Regole Critiche di Sistema (AppKit & Finestre)

### Zero Focus Stealing
La finestra principale (`FloatingPanel`) **non deve mai sottrarre il focus** all'applicazione in uso dall'utente:
- Eredita da `NSPanel`.
- StyleMask: `[.titled, .nonactivatingPanel, .fullSizeContentView, .resizable]`.
- Proprietà obbligatorie: `isFloatingPanel = true`, `level = .floating`, `becomesKeyOnlyIfNeeded = true`.
- All'attivazione del pannello: richiamare `orderFrontRegardless()` e `makeKeyAndOrderFront(nil)` senza mai rendere l'applicazione o la finestra una `main window` standard (`canBecomeMain = false`, `canBecomeKey = true`).

### Chiusura Automatica Istantanea (Auto-Dismiss)
Il pannello deve chiudersi immediatamente al cambio di contesto:
- Ascoltare `NSWindow.didResignKeyNotification`.
- Ascoltare `NSApplication.didResignActiveNotification`.
- Ascoltare `NSWorkspace.didActivateApplicationNotification` (per intercettare click su altre app esterne come VS Code o Terminale).
- Se `isVisible && attachedSheet == nil`, eseguire immediatamente `orderOut(nil)`.

---

## 3. Gestione Tastiera, Responder Chain & Type-to-Search

1. **Type-to-Search (Digitazione Immediata)**:
   - All'apertura della finestra, il campo di ricerca `TextField` deve ricevere automaticamente il focus della tastiera via `@FocusState` e listener di `NSWindow.didBecomeKeyNotification`.
   - Non richiedere la pressione manuale di `Cmd + F` per iniziare a scrivere.

2. **Intercettazione Eventi a Livello di Finestra (`sendEvent`)**:
   - In `FloatingPanel.sendEvent(_:)`, intercettare i tasti funzione critici **prima** che l'evento venga inoltrato alla responder chain di AppKit/SwiftUI:
     - `Return / Enter` (keyCodes 36, 76): incolla la clip selezionata.
     - `↑ / ↓` (keyCodes 126, 125): muovono la selezione nella lista (Shift espande per multi-selezione).
     - `Cmd + 1 ... 9`, `Cmd + 0`: cambio scheda/lista; `Cmd + Option + 1 ... 9`, `Cmd + Option + 0`: incollaggio rapido. L'impostazione di scambio inverte queste due famiglie; entrambe escludono Shift e Control e usano il fallback hardware keycode.
     - `Cmd + Option + A`: Tutte le clip; con il mapping predefinito funziona anche `Cmd + A`.
     - `Option` e `Option + Shift` con tasti di testo: lasciare gli eventi alla responder chain per simboli e accenti, senza intercettarli come scorciatoie numeriche o di navigazione.
     - `Option + Return / Enter`: mantenere l'incollaggio come testo semplice.
     - `Cmd + D`: deselezione rapida se selezione multipla attiva, altrimenti toggle preferiti.
     - `Cmd + M`: apertura modale lista.
     - `Escape`: chiude fogli modali, deseleziona il batch se attivo, svuota la query se valorizzata, o chiude il pannello (`orderOut(nil)`).

3. **Mappatura Hardware KeyCode**:
   - A causa del comportamento di AppKit con layout di tastiera internazionali (IT, US, FR, DE, tastierino numerico), non affidarsi unicamente a `charactersIgnoringModifiers`.
   - Usare sempre la funzione helper `digitIndex(forKeyCode: event.keyCode)` per mappare i codici hardware delle cifre (18..29 e 82..92).

4. **Monitor Locale nei Fogli Modali (`NSEvent.addLocalMonitorForEvents`)**:
   - I fogli modali (es. `MoveToListSheetView`) isolano la responder chain della finestra principale.
   - Utilizzare `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in `.onAppear` e rimuoverlo in `.onDisappear` per intercettare le scorciatoie lista configurate (`Cmd` oppure `Cmd + Option` con `1..9`, `0` e `A`) ed `Esc`.

5. **Ricerca Letterale**:
   - Le query con punteggiatura o simboli (es. `~/Library`, `c++`, `%`, `_`) devono cercare l'intera stringa come sottostringa letterale di testo o nome personalizzato, mantenendo filtri, ordinamento e limite.
   - Il confronto letterale deve rispettare l'equivalenza canonica Unicode e ignorare le maiuscole anche fuori da ASCII. La funzione SQL `concopy_literal_contains` deve essere registrata sul reader usato dalla query; passare sempre il testo come parametro, senza interpretare `%`, `_` o backslash come jolly.
   - Se si introducono query SQL `LIKE`, escapare sempre `%`, `_` e il carattere di escape.
   - Mantenere la ricerca FTS5 per prefisso sulle query composte da parole e spazi, includendo i segni diacritici combinanti fra i caratteri delle parole.

6. **Coerenza dei Badge**:
   - Generare badge e routing con `GlobalShortcutsManager.quickPasteShortcut` e i resolver condivisi. Non mostrare badge alfabetici mentre la ricerca è focalizzata o per lettere riservate ai comandi.
   - Spazio e frecce orizzontali modificati devono raggiungere la responder chain, senza attivare QuickLook.

---

## 4. Gestione della Memoria e Prestazioni

1. **Cicli di Rilascio `autoreleasepool`**:
   - Tutte le operazioni che generano picchi transitori di memoria devono essere incapsulate in blocchi `autoreleasepool { ... }`:
     - Interrogazioni pesanti e iterazioni di record `GRDB`.
     - Ingestione e decodifica di immagini e screenshot (`NSBitmapImageRep`, `CGImage`).
     - Serializzazione e deserializzazione Base64 in `ArchiveManager`.
     - Cicli di polling di `NSPasteboard` in `ClipboardMonitor`.

2. **Offloading Asincrono (`Task.detached`)**:
   - Nessuna operazione di I/O o hashing (SHA-256) deve essere eseguita sul thread principale.
   - Usare `Task.detached(priority: .utility)` per l'elaborazione dei blob, il download dei metadati URL e l'ingestione degli screenshot.

3. **Identità Stabile e Rendering Reattivo**:
   - Nella lista SwiftUI (`ClipboardListView`), utilizzare l'identificatore persistente `clip.id` nel `ForEach` e in `.id(clip.id)` per mantenere stabili le righe e i riferimenti di `ScrollViewReader`.
   - Non includere nell'identità indice, timestamp, nome, preferiti o stati transitori di copia e selezione: il loro aggiornamento non deve ricreare la riga e azzerarne lo stato locale.
   - Passare gli stati e i badge come proprietà reattive di `ClipRowView` e considerarli nel confronto `Equatable`, inclusi indice, selezione, copia e modificatore delle scorciatoie.
   - Mantenere la conformità `.equatable()` su `ClipRowView` per evitare re-render non necessari durante lo scorrimento.

4. **Sicurezza dei Descrittori di File (File Descriptor Leaks)**:
   - In `ScreenshotWatcher`, chiudere sempre il descrittore del file nella chiusura di cancellazione del dispatch source:
     ```swift
     source.setCancelHandler {
         close(fileDescriptor)
     }
     ```

---

## 5. Privacy e Prevenzione Loopback

1. **Filtri di Sicurezza Pasteboard**:
   - Scartare rigorosamente qualsiasi contenuto che presenti uno dei seguenti tipi:
     - `org.nspasteboard.TransientType`
     - `org.nspasteboard.ConcealedType`
     - `org.nspasteboard.AutoGeneratedType`
     - `com.agilebits.onepassword`
   - Rispettare sempre la blacklist di applicazioni configurata dall'utente e lo stato di pausa del monitoraggio.

2. **Prevenzione del Loopback (`PasteInjector`)**:
   - Prima di scrivere negli appunti di sistema per un'operazione di incollaggio sintetico, impostare sempre il tipo marcatore interno:
     ```swift
     pasteboard.setString("1", forType: NSPasteboard.PasteboardType("com.local.ConCopy.internalPaste"))
     ```
   - `ClipboardMonitor` deve verificare la presenza di questo marcatore e ignorare l'evento per evitare la duplicazione infinita della clip incollata.

3. **Integrità di Incollaggio e Storage**:
   - Tutti gli injector devono condividere una coda per pasteboard, mantenuta anche durante gli `await`; prima degli eventi rivalutare destinazione congelata, permessi e `changeCount`. Annullare l'operazione se il contesto o gli appunti sono cambiati.
   - Ogni database indipendente deve possedere la propria cartella blob. Il fallback usa `DatabaseStartup`, una cartella temporanea separata e un avviso persistente; in quella sessione cleanup e sincronizzazione sono sospesi senza cambiare le preferenze salvate.
   - Selezionare e cancellare i record in una sola transazione, rivalutando preferiti e appartenenza a liste nelle pulizie protette; rimuovere i blob non più referenziati solo dopo il commit.
   - Ripristinare le liste in modo additivo e mantenere al massimo una lista Auto-Star attiva. Il recupero cloud può riparare blob locali solo con byte remoti validati che corrispondono esattamente al nome SHA-256 atteso.

---

## 6. Qualità del Codice e Convenzioni

- **Zero Force-Unwrap**: Vietato l'uso di `!` o `fatalError` nel codice di produzione. Gestire sempre gli errori tramite `do-catch`, `guard let` o valori di fallback sicuri.
- **Swift Concurrency**: Usare `async/await`, `actor` e `@MainActor` rispettando i vincoli di isolamento.
- **Nessuna regressione nei test**: Ogni modifica apportata a `ConCopyCore` o alla logica di incollaggio deve mantenere funzionante l'intera suite esistente e includere le regressioni dei difetti corretti.

---

## 7. Comandi di Verifica Obbligatori

Prima di concludere qualsiasi sessione di modifica, eseguire sempre:

```bash
# Verifica compilazione in modalità debug
swift build

# Verifica compilazione ottimizzata per release (zero warning ammessi)
swift build -c release

# Esecuzione completa dei test di unità e integrazione
swift test
```
