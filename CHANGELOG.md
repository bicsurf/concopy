# Changelog

Le modifiche rilevanti sono raccolte per versione, con una sezione separata per il lavoro non ancora rilasciato. Il formato segue [Keep a Changelog](https://keepachangelog.com/it/1.1.0/) e la numerazione usa [Semantic Versioning](https://semver.org/lang/it/).

Le voci da 1.2.1 a 1.3.1 sono state ricostruite dai tag e dai commit locali. Le correzioni degli audit del 17 novembre 2026 appartengono al working tree successivo a `v1.3.1`: non costituiscono una nuova release.

## Non rilasciato

### Aggiunto

- **Filtri Rapidi & Trasformazioni Testo Developer**:
  - Filtri per tipologia di contenuto (testo, codice, link, immagini, colori).
  - Trasformazioni integrate per sviluppatori: formattazione/minificazione JSON, codifica/decodifica URL e Base64, conversione case (camelCase, snake_case, PascalCase, kebab-case) e conversione Markdown/HTML.
- **Riconoscimento OCR e Campioni Colore**:
  - Estrazione del testo da immagini catturate tramite Apple Vision Framework con indicizzazione per la ricerca FTS5.
  - Riconoscimento automatico di valori colore (HEX, RGB, HSL) e swatch preview interattiva.
- **Paste Stack & Coda Sequenziale**:
  - Modalità Paste Stack (LIFO) e Paste Queue (FIFO) per incollare in successione serie di clip negli applicativi target.
- **Snippet Dinamici con Variabili**:
  - Supporto per variabili dinamiche (`{date}`, `{time}`, `{clipboard}`) e placeholder interattivi con foglio di compilazione al volo prima dell'incollaggio.
- **Batch Paste Multi-Immagini Nativo**:
  - Esportazione ed incollaggio nativo di selezioni multiple di immagini come file/oggetti `NSURL` nel Finder e nelle app di messaggistica.
- **Privacy Shield & Mascheramento Dati Sensibili**:
  - Rilevamento automatico e mascheramento opzionale di carte di credito, password e token API con sblocco biometrico locale.
- **Posizionamento Contestuale del Pannello**:
  - Modalità di ancoraggio del pannello fluttuante in corrispondenza del cursore (caret), del puntatore del mouse o centrato sullo schermo.
- **Azioni Rapide & Anteprima Metadati Link**:
  - Apertura/esecuzione rapida di clip in Terminale, browser o script e anteprima arricchita dei link web (titoli e favicon).
- 25 test di regressione per i dieci rilievi D01–D10 dell'audit di produzione del 19 novembre: destinazione, concorrenza e annullamento degli incollaggi, Unicode, fallback, transazioni, recupero cloud e coerenza dei badge.
- Sincronizzazione v2 di payload, liste e snippet, con identità stabili, alias e cancellazioni persistenti; lettura del precedente file v1 per la migrazione.
- Componenti dei contatori d’uso indipendenti per dispositivo e clock separati per preferiti, nomi, liste e ordine manuale.
- Provenienza persistente degli snippet ripristinati, conservata anche attraverso backup e sincronizzazione.
- Paginazione della cronologia oltre i primi 100 risultati.
- Test di regressione per storage, backup, importazione, sync, incollaggio, privacy, interfaccia e servizi di rete, inclusi 17 test per C01–C11.

### Modificato

- Le righe della cronologia mostrano soltanto il contenuto copiato, anche per record che avevano un nome salvato; anteprima e accessibilità non usano più il nome della clip.
- Un clic semplice su una clip chiude il pannello sia in modalità incollaggio automatico sia in modalità solo copia, agendo sempre sulla clip cliccata. Mantenuta la selezione multipla tramite Shift, Command e cerchi di selezione.
- Scorciatoie numeriche con Option e comando Tutte le clip spostati su ⌘⌥ per consentire la digitazione di simboli e accenti; scambio configurabile aggiornato a ⌘/⌘⌥, con badge e impostazioni coerenti. Mantenuto ⌥Invio per il testo semplice.
- Query con punteggiatura o simboli cercate come sottostringhe letterali nel testo e nei nomi personalizzati, inclusi `%`, `_` e backslash; mantenuta la ricerca FTS5 per prefisso sulle query composte da parole.
- Ripristino degli archivi additivo, con conservazione delle versioni locali modificate e recupero degli snippet in conflitto tramite shortcut alternative.
- Elaborazioni di ricerca, payload e immagini spostate fuori dal thread principale nei percorsi corretti dagli audit.
- Pulizia automatica della cronologia aggiornata anche in risposta alle impostazioni e alle nuove catture.
- GRDB selezionato dal compilatore: 7.5.0 con Swift 6+, 6.29.3 nel percorso Swift 5.9.
- README e stato di lavoro aggiornati a funzioni, scorciatoie, migrazioni, compatibilità e comandi attuali; rimossi i riferimenti di installazione Homebrew non più presenti nel repository.

### Risolto

- Audit D01–D10: coda condivisa degli incollaggi con controllo di destinazione e `changeCount`; fallback con blob isolati e avviso; pulizie e cancellazioni delle liste atomiche; ricerca letterale Unicode; ripristino additivo delle liste con una sola Auto-Star; recupero di blob da copie cloud integre; inoltro degli input modificati e badge coerenti con focus e comandi riservati.
- Sincronizzazione: scritture dopo la disattivazione, aggiornamenti remoti mancati durante sessioni inattive, troncamento della cronologia e sovrascrittura di file cloud illeggibili.
- Identità e merge: collisioni fra immagini o file omonimi, perdita di metadati durante deduplicazione e ricattura di alias offline, ripristino di clip eliminate causato dai clock artificiali della migrazione v6.
- Contatori: incrementi offline che annullavano modifiche al contenuto e conteggi duplicati dopo il ripristino di backup legacy.
- Blob: cancellazione di file ancora condivisi, perdite durante rollback o esportazioni concorrenti, mancato recupero di corruzioni a parità di dimensione e rappresentazioni orfane dopo la migrazione.
- Backup e snippet: snippet esclusi dagli archivi, conflitti con clip modificate, Base64 invalido, perdita di snippet legittimi con shortcut simili e duplicazioni ai ripristini successivi.
- Importazione: clip parziali conteggiate come riuscite, elementi oltre il limite non segnalati e controlli delle dimensioni applicati troppo tardi o misurati in caratteri anziché byte.
- Incollaggio: formati obsoleti dopo modifica o ricattura, perdita di file nelle selezioni Finder multiple, scorciatoie numeriche che forzavano il testo semplice e mancata gestione degli eventi falliti, anche per gli snippet.
- Batch sequenziale: invio di Tab dopo un cambio di applicazione e scelta della destinazione successiva all’attesa iniziale.
- Statistiche: un errore nel salvataggio dell’uso dopo un trasferimento riuscito non viene più presentato come un fallimento dell’incollaggio.
- Screenshot: pausa del monitoraggio non rispettata, file incompleti ignorati definitivamente o acquisiti prima che fossero disponibili i pixel.
- Interfaccia: azioni su risultati di ricerca precedenti, selezioni nascoste, attivazione del pannello, percorsi errati nelle anteprime e chiusura dell’editor snippet dopo un salvataggio fallito.
- Rete e file temporanei: controllo aggiornamenti non ripetuto e collisioni fra esportazioni con la stessa etichetta.

### Compatibilità e verifiche

- Correzioni D01–D10 del 19 novembre 2026: `swift build` e `swift build -c release` riusciti senza warning; `swift test` con **204 test, 203 passati, uno opzionale saltato e zero fallimenti**, comprese tutte le **25 nuove regressioni**.
- Verifiche su applicazioni reali del 19 novembre 2026: 13 controlli nativi superati in TextEdit e Sublime Text su macOS 27.2.1 arm64, inclusi focus, ricerca con `~`, copia al clic, testo semplice, cambio app durante il paste e nove incollaggi consecutivi senza duplicazioni; apertura fisica del pannello confermata. Copertura limitata a testo inline e RTF nelle due applicazioni.
- Verifica delle nuove scorciatoie, della ricerca letterale e del clic sulle clip del 19 novembre 2026: build debug e release riuscite senza warning; suite completa con **179 test, 178 passati, uno opzionale saltato e zero fallimenti**. Il test opzionale richiede `CONCOPY_TEST_CEP_PATH` per un export reale Copy ’Em.
- Migrazioni locali v5–v8 per contatori, identità binarie, clock dei metadati, provenienza degli snippet e pulizia dei blob.
- Backup v1/v2 precedenti leggibili; i nuovi campi del formato v2 sono opzionali in decodifica. Aggiornare tutti i Mac che sincronizzano per preservare `usage`, `metadataRevisions` e `snippetOrigins`.
- **A30 escluso dall'audit del 17 novembre:** in quell'intervento era stato mantenuto il comportamento di ⌥A/⌘A. La successiva modifica delle scorciatoie descritta sopra sposta ⌥A su ⌘⌥A e conserva l'alias ⌘A con il mapping predefinito.
- Verifica del 17 novembre 2026 con Swift 6.4.2 su arm64: `swift build` e `swift build -c release` riusciti, zero warning; `swift test` con **170 test, 169 passati, uno opzionale saltato e zero fallimenti**.
- Il test saltato richiede una fixture reale Copy ’Em tramite `CONCOPY_TEST_CEP_PATH`. Non sono stati verificati due Mac fisici con iCloud, la toolchain Swift 5.9 o il packaging universale di queste correzioni.

### Rimosso

- Recupero automatico dei titoli delle pagine web e comandi per aggiungere o modificare i nomi delle clip. I metadati storici restano compatibili con archivi e sincronizzazione.
- Script di prova manuale, log, report diagnostici e bundle QA temporanei degli audit; conservati i test di regressione della suite.

## [1.3.1] - 2026-11-16

### Risolto

- Allineato il badge di Tutte le clip al modificatore delle scorciatoie configurato.
- Uniformato il comando per tornare a Tutte le clip: con il mapping predefinito, ⌘A viene gestito dal pannello anche quando la ricerca è focalizzata. Questo comportamento corrisponde ad A30 ed è stato successivamente mantenuto per richiesta esplicita.

## [1.3.0] - 2026-11-16

### Modificato

- Interfaccia tradotta dall’italiano all’inglese.
- Rivisti elenco delle clip, componenti delle righe, impostazioni, anteprime e tema.
- Aggiornate le interazioni con clic, selezione multipla e preferiti, con test dedicati alla selezione e ai metadati.

## [1.2.4] - 2026-11-12

### Aggiunto

- Importazione della cronologia da Maccy e Copy ’Em, con deduplicazione e fusione conservativa dei metadati.
- Supporto al formato nativo Copy ’Em e ai pacchetti `.cep`, con lettura degli asset e gestione dei tipi SQLite dinamici.
- Sezione di importazione nelle impostazioni, indicatore di avanzamento e riepilogo dell’esito; aggiornamento di clip e liste dopo l’importazione.
- Fixture sintetiche per importatori e test opzionale su un export reale Copy ’Em.

### Rimosso

- Cask Homebrew e relativi file dal repository. Per l’installazione fare riferimento al DMG delle release.

## [1.2.3] - 2026-11-12

### Modificato

- Scorciatoia per Tutte le clip assegnata ad A con il modificatore appropriato al mapping configurato.
- Disattivato l’aggiornamento automatico del Cask nello script di packaging.

## [1.2.2] - 2026-11-12

### Aggiunto

- Icona dell’applicazione sorgente sulle clip.
- Personalizzazione delle scorciatoie e scambio dei modificatori numerici ⌘/⌥.
- Accesso agli snippet nella navigazione delle liste e nuovi test per icone, scorciatoie e selezione.

### Modificato

- Rivisti impostazioni, elenco delle clip, pannello e gestione dello stato per migliorare interazioni e prestazioni.

## [1.2.1] - 2026-11-11

### Risolto

- Affinata la selezione multipla con Shift e Command e la gestione del comando di deselezione.
- Aggiornata la documentazione della selezione multipla.

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

[1.3.1]: https://github.com/bicsurf/concopy/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/bicsurf/concopy/compare/v1.2.4...v1.3.0
[1.2.4]: https://github.com/bicsurf/concopy/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/bicsurf/concopy/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/bicsurf/concopy/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/bicsurf/concopy/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/bicsurf/concopy/compare/v1.0.1...v1.2.0
[1.0.1]: https://github.com/bicsurf/concopy/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/bicsurf/concopy/releases/tag/v1.0.0
