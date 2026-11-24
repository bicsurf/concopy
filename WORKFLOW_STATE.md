# Stato di lavoro — ConCopy

Nota 24 novembre 2026 — nuova feature "mostra/nascondi icona barra dei menu" (`showMenuBarIcon`, default attivo), su branch `feat/hide-menu-bar-icon` (commit `0cbb13c`). L'app è LSUIElement-only: a icona nascosta l'unico ingresso resta la scorciatoia globale del pannello. Verifiche: `swift build` ok, `swift build -c release` ok zero warning, `swift test` 213 test / 1 saltato / 0 fallimenti.

Aggiornato il **24 novembre 2026**. Questo file riassume lo stato verificato del working tree per chi riprende lo sviluppo. I vincoli architetturali restano definiti in [AGENTS.md](AGENTS.md); la cronologia delle versioni è in [CHANGELOG.md](CHANGELOG.md).

## Stato attuale

| Voce | Stato |
| --- | --- |
| Branch rilevato | `main` |
| Base Git | `8a6d344`; ultimo tag locale `v1.3.2`. |
| Working tree | Contiene modifiche e nuovi file non ancora committati, inclusi gli interventi D01–D10. Preservarli quando si riprende il lavoro. |
| Ultimo intervento funzionale | Rimossi titoli automatici e nomi aggiuntivi dalle righe; la cronologia mostra il contenuto copiato. Completate in precedenza le correzioni D01–D10 e le prove di focus/incollaggio in applicazioni reali. |
| Scorciatoie | La successiva istruzione dell’utente ha spostato i comandi Option su ⌘⌥; mantenuti ⌥Invio e l’alias ⌘A con mapping predefinito. |
| Pulizia | Rimossi script manuali, report, log e bundle QA temporanei. Gli esiti sono riassunti qui e nel changelog; la suite di regressione è conservata. |
| Pubblicazione | La 1.3.2 è già rilasciata. La prossima release non è stata preparata. |

Branch, tag e pulizia del working tree sono uno snapshot: verificarli nuovamente con `git status --short` e `git log -1 --oneline --decorate` prima di operare.

## Stack e confini dei moduli

| Area | Implementazione attuale |
| --- | --- |
| Runtime verificato | macOS, Swift 6.4.2, arm64; destinazione minima macOS 14. |
| Manifest | Swift Package Manager, `swift-tools-version: 5.9`. |
| Dipendenze | GRDB 7.5.0 con Swift 6+; GRDB 6.29.3 nel ramo condizionale Swift 5.9; KeyboardShortcuts in `ConCopyUI`. |
| `ConCopyCore` | Logica di cattura, SQLite/FTS5, blob, importazione, backup, screenshot, incollaggio e iCloud Drive. Non importare SwiftUI o classi di vista/finestra. |
| `ConCopyUI` | AppKit/SwiftUI; `ClipboardViewModel` su `@MainActor`, pannello non attivante e anteprime. |
| `ConCopyApp` | Eseguibile menubar con `LSUIElement`, inizializzazione e coordinamento dei servizi. |
| Storage | `DatabasePool` su disco, `DatabaseQueue` nei test in memoria; FTS5 external-content `clips_fts`. |
| Blob | Inline fino a 4096 byte; oltre tale soglia file `<sha256>.blob`, verificati all’apertura e riparati atomicamente se corrotti al successivo salvataggio di dati integri. |
| Verifiche | XCTest e comandi SPM; gli script di packaging sono separati dalle build native dell’host. |

Percorsi di produzione:

```text
~/Library/Application Support/ConCopy/concopy.sqlite
~/Library/Application Support/ConCopy/blobs/
~/Library/Mobile Documents/com~apple~CloudDocs/ConCopy/sync-state-v2.json
```

## Correzioni degli audit

Gli esiti riassumono i casi verificati nelle rispettive revisioni. Una chiusura storica non certifica l’assenza di difetti successivi nella stessa funzione.

| Ciclo | Interventi |
| --- | --- |
| Primo audit | 37 interventi applicati; A30 escluso in quel ciclo. |
| Secondo audit | B01–B20 corretti, con verifica iniziale di B19 e 24 test aggiunti. Alcuni percorsi sono stati ulteriormente corretti nel terzo ciclo. |
| Terzo audit | C01–C11 corretti, con 17 test aggiunti. |
| Audit di produzione | D01–D10 corretti, con 25 test aggiunti; coperti destinazione, concorrenza, Unicode, fallback, transazioni, recupero cloud e badge. |

### Invarianti da conservare

- **C01 / migrazione:** ricalcolare un’identità binaria non crea una nuova modifica utente. Conservare revisioni, cancellazioni e alias preesistenti.
- **C02 / metadati:** preferito, nome, lista e ordine manuale hanno clock indipendenti dal contenuto. Distinguere i valori predefiniti di una ricattura dalle rimozioni esplicite, anche attraverso un alias offline.
- **C03 / contatori:** la componente legacy mantiene l’ID originario dell’archivio dopo la deduplicazione; il ripristino ripetuto non deve sommare due volte lo stesso uso.
- **C04 / snippet:** usare provenienza e identità persistenti per riconoscere una versione già ripristinata. Una shortcut con il suffisso `~restored` non prova da sola che due snippet siano duplicati.
- **C05–C06 / blob:** verificare il digest, recuperare i file corrotti da dati integri ed eliminare solo quelli privi di riferimenti. La pulizia della migrazione avviene dopo il commit; un rollback deve lasciare disponibili i blob originari.
- **C07 / batch:** acquisire il PID prima di elaborazione e attesa iniziale; ricontrollare destinazione e permessi prima di ogni evento, incluso Tab.
- **C08–C09 / incollaggio:** distinguere evento fallito e statistiche non salvate dopo un trasferimento riuscito. Anche gli snippet devono controllare l’esito dell’evento e consentire l’incollaggio manuale.
- **C10 / importazione:** misurare i limiti SQLite in byte prima di materializzare i payload, comprese le stringhe Unicode.
- **C11 / screenshot:** un header PNG leggibile non basta. Attendere chunk completi e pixel decodificabili prima della cattura.
- **Tastiera:** rispettare il mapping ⌘/⌘⌥ configurato; lasciare Option alla digitazione e mantenere ⌥Invio. I badge devono condividere i resolver degli eventi.
- **D01–D02 / incollaggio:** mantenere la coda condivisa per pasteboard anche durante gli `await`; rivalutare PID congelato, permessi e `changeCount` prima degli eventi.
- **Contenuto delle righe:** visualizzare testo o URL copiato senza anteporre `customName`, anche per le cronologie esistenti. Il recupero dei titoli web è stato rimosso; il campo storico resta leggibile per compatibilità con backup, importazione e sync.

I test del terzo ciclo si trovano in `Tests/ConCopyCoreTests/ThirdAudit*Tests.swift`; quelli dei cicli precedenti in `Audit*Tests.swift` e `Reaudit*Tests.swift`. Le 25 regressioni D01–D10 sono in `Tests/ConCopyCoreTests/ProductionAuditRegressionTests.swift`.

## Schema e compatibilità

| Migrazione | Scopo |
| --- | --- |
| v1–v3 | Schema iniziale, ordinamento delle liste e snippet. |
| v4 | Journal delle modifiche per il sync. |
| v5 | Componenti indipendenti dei contatori d’uso. |
| v6 | Migrazione e consolidamento delle identità binarie. |
| v7 | Clock indipendenti dei metadati delle clip. |
| v8 | Provenienza degli snippet ripristinati e coda di pulizia dei blob. |

Il sync scrive il formato **v2** e legge anche il file v1 per la migrazione. I campi `usage`, `metadataRevisions` e `snippetOrigins` sono opzionali in decodifica; tutti i Mac devono usare la versione aggiornata per conservarli durante le riscritture. I backup v1/v2 precedenti rimangono leggibili.

I formati legacy non permettono di ricostruire con certezza vecchie rimozioni esplicite dei metadati né i clock reali già sostituiti dal vecchio v6. Non inventare una cronologia retroattiva. La v8 raccoglie anche i blob rimasti orfani dopo un v6 già applicato.

## Contratto degli importatori

L’importazione da Maccy e Copy ’Em è implementata e collegata alle impostazioni. I dettagli qui sotto sostituiscono il precedente piano di implementazione ormai completato.

- `ExternalClipboardImporter` è `Sendable` e espone `importClips(into:progress:) throws -> ImportResult`, sincrono. La UI lo esegue fuori dal MainActor con `Task.detached`.
- `ImportResult` riporta importati, duplicati uniti, liste create ed errori; conserva fino a 100 dettagli. `isSuccess` richiede `errorsCount == 0`.
- `SourceDatabase` risolve il file, copia database e sidecar WAL/SHM presenti in una directory temporanea e apre la copia senza applicare le migrazioni ConCopy. Una copia live dei sidecar non dimostra da sola la consistenza di ogni snapshot esterno.
- Riutilizzare `CapturedClip.computeContentHash()`: non replicare l’algoritmo negli importatori. La fusione è conservativa per i metadati locali e non deve alterare inutilmente `updatedAt`.
- Limiti: **50 MiB per payload**, **500 MiB per importazione**, **50.000 elementi**. Segnalare elementi oltre i limiti; non presentarli come importati correttamente.
- Mantenere valori SQL parametrizzati, validazione degli identificatori dinamici, errori senza contenuto delle clip e pulizia delle directory temporanee.
- Le scritture passano dal writer GRDB; i trigger mantengono FTS5 allineato. Non annidare letture o scritture sullo stesso writer dentro una transazione già in corso.
- L’aggiornamento della UI dopo un’importazione deve ricaricare sia clip sia liste.

## Verifiche da eseguire prima di concludere

```bash
swift build
swift build -c release
swift test
```

Come richiesto da AGENTS.md, la release deve produrre **zero warning**. La suite attuale contiene **204 test**, incluso uno opzionale.

Ultimo esito verificato, 19 novembre 2026:

| Controllo | Esito |
| --- | --- |
| `swift build` | Passato, zero warning. |
| `swift build -c release` | Passato, zero warning. |
| `swift test` | 204 test, 203 passati, uno saltato, zero fallimenti. |
| Applicazioni reali | 13 controlli nativi superati in TextEdit e Sublime Text su macOS 27.2.1 arm64; apertura fisica confermata. |

Le prove reali coprono focus immediato sulla ricerca, digitazione di `~`, ricerca letterale, clic con copia o paste, ⌘⌥1, ⌥Invio, conservazione o rimozione del grassetto RTF, cambio app durante il paste e nove incollaggi consecutivi senza duplicazioni. La QA e i documenti dedicati sono stati chiusi e il permesso temporaneo di Accessibilità revocato.

Il test opzionale `ExternalImportTests.testRealUserExportIfPresent` richiede `CONCOPY_TEST_CEP_PATH` con un export reale Copy ’Em esistente. Il suo skip non deve essere contato come test passato.

## Verifiche ancora aperte

1. **Export reale Copy ’Em:** fornire un fixture tramite `CONCOPY_TEST_CEP_PATH` ed eseguire il test opzionale. Le prove attuali usano fixture sintetiche.
2. **iCloud su due Mac:** verificare idratazione, lavoro offline, conflitti e convergenza sui dispositivi reali. I test usano worker reali con database e cartelle temporanee.
3. **Copertura aggiuntiva su app reali:** verificare immagini/file, altre applicazioni e altri sistemi macOS; le prove concluse coprono testo inline e RTF nelle due applicazioni indicate.
4. **Compatibilità di compilazione:** eseguire la toolchain Swift 5.9 e il packaging universale su `arm64`/`x86_64`. Le ultime verifiche coprono solo Swift 6.4.2 su arm64.
5. **Packaging della prossima versione:** verificare bundle, risorse, firma e DMG con gli script dedicati prima di un rilascio. Una build SPM nativa riuscita non equivale a questa verifica.

## Ripresa del lavoro

Leggere lo stato Git e le istruzioni locali, scegliere i test pertinenti al componente modificato e preservare le modifiche già presenti. Aggiornare questo file quando cambiano schema, compatibilità, verifiche o attività pendenti; lasciare il dettaglio storico nel changelog. Non considerare una verifica locale come prova di commit, tag o pubblicazione.
