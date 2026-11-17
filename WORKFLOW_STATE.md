# Stato di lavoro — ConCopy

Aggiornato il **17 novembre 2026**. Questo file riassume lo stato verificato del working tree per chi riprende lo sviluppo. I vincoli architetturali restano definiti in [AGENTS.md](AGENTS.md); la cronologia delle versioni è in [CHANGELOG.md](CHANGELOG.md).

## Stato attuale

| Voce | Stato |
| --- | --- |
| Branch rilevato | `FIX_check_bug_and_test` |
| Base Git | `580411e`, tag locale `v1.3.1` |
| Working tree | Contiene modifiche e nuovi file non ancora committati, inclusi gli interventi dei tre audit. Preservarli quando si riprende il lavoro. |
| Ultimo intervento funzionale | Correzioni C01–C11, iniziate dai tre P1 C01, C02 e C07; aggiunti 17 test di regressione. |
| Eccezione esplicita | **A30 deve rimanere invariato**, salvo nuova istruzione dell’utente. Il test dedicato è passato. |
| Attività documentale | README, stato di lavoro e changelog riallineati al codice e ai tag locali. |
| Pubblicazione | Le correzioni degli audit sono in lavorazione; nessun nuovo commit, tag o rilascio è stato creato in queste sessioni di correzione. |

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

I report documentano i casi verificati nelle rispettive revisioni. Una chiusura storica non certifica l’assenza di difetti successivi nella stessa funzione.

| Ciclo | Interventi | Evidenze |
| --- | --- | --- |
| Primo audit | 37 interventi applicati; A30 escluso. | [Dati e test](docs/audit-fixes.json) |
| Secondo audit | B01–B20 corretti, con verifica iniziale di B19 e 24 test aggiunti. Alcuni percorsi sono stati ulteriormente corretti nel terzo ciclo. | [Report](docs/reaudit-fixes.html) · [Dati](docs/reaudit-fixes.json) |
| Terzo audit | C01–C11 corretti, con 17 test aggiunti. | [Report](docs/third-audit-fixes.html) · [Dati](docs/third-audit-fixes.json) |

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
- **A30 / tastiera:** conservare `matchesAllClips(event:)` e il comportamento attuale di ⌥A/⌘A. Non correggerli incidentalmente durante un intervento sulle scorciatoie.

I test del terzo ciclo si trovano in `Tests/ConCopyCoreTests/ThirdAudit*Tests.swift`; quelli dei cicli precedenti in `Audit*Tests.swift` e `Reaudit*Tests.swift`.

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

Come richiesto da AGENTS.md, la release deve produrre **zero warning**. Il riferimento ai 58 test in AGENTS.md è storico: la suite attuale contiene **170 test**, incluso uno opzionale.

Ultimo esito verificato per C01–C11, 17 novembre 2026:

| Controllo | Esito | Log |
| --- | --- | --- |
| `swift build` | Passato, zero warning. | [Debug](docs/verification-third-audit/debug.log) |
| `swift build -c release` | Passato, zero warning. | [Release](docs/verification-third-audit/release.log) |
| `swift test` | 170 test, 169 passati, uno saltato, zero fallimenti. | [Suite completa](docs/verification-third-audit/tests.log) |
| A30 | File delle scorciatoie invariato rispetto alla baseline delle correzioni C; test dedicato passato. | [Integrità e test](docs/third-audit-fixes.json) |

Il test opzionale `ExternalImportTests.testRealUserExportIfPresent` richiede `CONCOPY_TEST_CEP_PATH` con un export reale Copy ’Em esistente. Il suo skip non deve essere contato come test passato.

## Verifiche ancora aperte

1. **Export reale Copy ’Em:** fornire un fixture tramite `CONCOPY_TEST_CEP_PATH` ed eseguire il test opzionale. Le prove attuali usano fixture sintetiche.
2. **iCloud su due Mac:** verificare idratazione, lavoro offline, conflitti e convergenza sui dispositivi reali. I test usano worker reali con database e cartelle temporanee.
3. **Permessi e focus reali:** confermare l’interazione AppKit/Accessibilità nelle app di destinazione. I nuovi test di incollaggio usano PID ed eventi simulati e pasteboard dedicate.
4. **Compatibilità di compilazione:** eseguire la toolchain Swift 5.9 e il packaging universale su `arm64`/`x86_64`. Le ultime verifiche degli audit coprono solo Swift 6.4.2 su arm64.
5. **Packaging della prossima versione:** verificare bundle, risorse, firma e DMG con gli script dedicati prima di un rilascio. Una build SPM nativa riuscita non equivale a questa verifica.

## Ripresa del lavoro

Leggere lo stato Git e le istruzioni locali, scegliere i test pertinenti al componente modificato e preservare le modifiche già presenti. Aggiornare questo file quando cambiano schema, compatibilità, verifiche o attività pendenti; lasciare il dettaglio storico nel changelog e nei report degli audit. Non considerare una verifica locale come prova di commit, tag o pubblicazione.
