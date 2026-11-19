# ConCopy

![macOS 14+](https://img.shields.io/badge/macOS-14+-000000?logo=apple&logoColor=white)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)
![SPM](https://img.shields.io/badge/Build-Swift_Package_Manager-blue)
![MIT](https://img.shields.io/badge/License-MIT-green)

ConCopy è un gestore di appunti e snippet per macOS. Conserva testi, immagini e riferimenti ai file, permette di cercarli e riutilizzarli e rimane nella barra dei menu, senza un’icona nel Dock.

Apri il pannello con **⌘⇧V**, scrivi per cercare e premi **Invio** per incollare la clip selezionata. Il pannello usa una finestra non attivante per mantenere il contesto dell’applicazione di destinazione.

[Installazione](#installazione) · [Funzioni](#funzioni) · [Scorciatoie](#scorciatoie) · [Sviluppo](#sviluppo) · [Changelog](CHANGELOG.md)

## Installazione

1. Scarica il file `.dmg` dalla pagina [Releases](https://github.com/bicsurf/concopy/releases).
2. Aprilo e trascina **ConCopy.app** in **Applicazioni**.
3. Avvia ConCopy e apri il pannello con **⌘⇧V**. La scorciatoia globale è personalizzabile nelle impostazioni.

È richiesto **macOS 14 Sonoma o successivo**. Per compilare il bundle localmente, segui le istruzioni di [packaging](#bundle-app-e-dmg).

### Permessi e modalità di incollaggio

Per incollare automaticamente nell’app attiva, autorizza ConCopy in **Impostazioni di Sistema → Privacy e Sicurezza → Accessibilità**.

In assenza del permesso, il contenuto rimane disponibile negli appunti per l’incollaggio manuale con **⌘V**. Nelle impostazioni di ConCopy puoi scegliere fra **Paste into active app** e **Copy to clipboard**.

Un clic semplice su una clip chiude il pannello in entrambe le modalità: incolla la clip cliccata nell'app precedente con **Paste into active app**, oppure la copia pronta per **⌘V** con **Copy to clipboard**. **⇧clic**, **⌘clic** e il cerchio di selezione mantengono aperto il pannello per comporre una selezione multipla.

## Funzioni

| Area | Cosa puoi fare |
| --- | --- |
| Cronologia e ricerca | Salvare testo, RTF, HTML, URL, immagini e riferimenti ai file; cercare con FTS5 e riutilizzare le clip senza duplicati di contenuto. |
| Selezione multipla | Selezionare intervalli o elementi separati, concatenarli nell’ordine dell’elenco e scegliere il separatore. Il batch sequenziale usa Tab per passare fra i campi. |
| Preferiti e liste | Contrassegnare le clip come preferite, organizzarle in liste e usare Auto-Star. |
| Snippet | Salvare frammenti di testo con titolo e shortcut, cercarli nella scheda dedicata e incollarli su richiesta. |
| Anteprime | Aprire l’anteprima di testi, immagini e file dal pannello. |
| Screenshot | Aggiungere automaticamente gli screenshot alla cronologia quando l’immagine è completa e decodificabile. |
| Manutenzione | Mettere in pausa la cattura, escludere applicazioni e configurare la pulizia automatica per età e numero di elementi. Preferiti e clip nelle liste sono protetti dalla pulizia automatica. |
| Importazione e backup | Importare da Maccy e Copy ’Em, esportare un archivio JSON e ripristinarlo senza sostituire l’intera cronologia locale. |
| Sincronizzazione | Condividere cronologia, payload, liste e snippet fra i propri Mac tramite iCloud Drive, attivando l’opzione nelle impostazioni. |
| Aggiornamenti | Verificare le release GitHub dalle impostazioni o abilitare il controllo automatico. |

Le righe mostrano il contenuto copiato, senza un titolo aggiuntivo: per i link viene visualizzato direttamente l’URL. ConCopy non scarica le pagine per ricavarne il titolo. Gli eventuali nomi presenti nelle vecchie cronologie restano compatibili con backup, importazione e ricerca, ma non vengono mostrati come intestazione delle clip.

### Importare da Maccy e Copy ’Em

In **Impostazioni → History → Import from Other Apps**, scegli **Import from Maccy…** o **Import from Copy ’Em…**. Sono supportati database SQLite e cartelle; Copy ’Em supporta anche pacchetti di esportazione `.cep` riconosciuti dall’importatore.

L’importazione riutilizza la deduplicazione di ConCopy e conserva, quando presenti nel formato sorgente, date, preferiti, nomi e liste. La fusione dei duplicati mantiene i metadati locali già valorizzati. Al termine viene mostrato un riepilogo degli elementi importati, uniti e non importati.

I limiti sono **50 MiB per payload**, **500 MiB di dati elaborati per importazione** e **50.000 elementi**. I limiti preventivi delle stringhe SQLite sono misurati in byte, anche per testo Unicode. Un archivio oltre i limiti può essere rifiutato o produrre un riepilogo con errori: controlla sempre l’esito prima di considerare conclusa la migrazione.

### Backup e ripristino

In **Impostazioni → History → Backup & Restore**, usa **Export Archive…** e **Import Archive…**.

Il ripristino è additivo: conserva i dati locali, recupera i payload mancanti o corrotti da un backup integro e mantiene le versioni degli snippet in conflitto con una shortcut alternativa, ad esempio `~restored`. I nuovi archivi conservano anche la provenienza degli snippet e i componenti dei contatori d’uso per rendere idempotenti i ripristini ripetuti.

Sono leggibili gli archivi v1 e v2 precedenti. Le migrazioni locali fino allo schema v8 vengono applicate automaticamente all’apertura del database.

### Sincronizzazione iCloud Drive

Abilita **iCloud Drive Sync** nelle impostazioni sui Mac collegati al tuo iCloud Drive. Lo stato condiviso si trova in:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/ConCopy/sync-state-v2.json
```

Il formato v2 trasferisce anche i payload e conserva ID, alias e cancellazioni. Le revisioni dei metadati e i contatori d’uso sono indipendenti da quelle del contenuto: ricopiare una clip non deve annullare un nome, un preferito o una lista modificati su un altro Mac.

**Aggiorna tutti i Mac coinvolti** per conservare i nuovi campi `usage`, `metadataRevisions` e `snippetOrigins`. Il vecchio file `sync-state-v1.json` viene letto per la migrazione e non viene aggiornato. La sincronizzazione non sostituisce un backup separato.

### Dati locali e privacy

I dati vengono conservati in:

```text
~/Library/Application Support/ConCopy/
├── concopy.sqlite
└── blobs/             # Payload esterni, indirizzati tramite SHA-256
```

ConCopy ignora i tipi pasteboard transient, concealed e autogenerated, il marcatore di 1Password e le applicazioni escluse dall’utente. Il marcatore interno evita di ricatturare i propri incollaggi. La pausa della cattura si applica anche agli screenshot.

La cronologia e i backup possono contenere dati sensibili; il formato locale e gli archivi JSON non prevedono una cifratura applicativa dedicata. La sincronizzazione usa la cartella personale di iCloud Drive; il controllo aggiornamenti consulta GitHub.

Se la cronologia salvata non può essere aperta, ConCopy mostra **Temporary history** e usa uno spazio temporaneo separato. In quella sessione pulizia automatica e sincronizzazione sono sospese: esporta un backup dalle impostazioni prima di chiudere l'app. Il database di ripiego non elimina i file della cronologia persistente.

## Scorciatoie

Questa tabella descrive il mapping predefinito attuale. **Swap numeric modifiers (⌘ ⇋ ⌘⌥)** scambia i modificatori delle scorciatoie numeriche nelle impostazioni. Le combinazioni con il solo Option, anche insieme a Shift, restano disponibili per digitare simboli e accenti nella ricerca; **⌥Invio** mantiene l'incollaggio come testo semplice.

| Scorciatoia | Azione nel pannello |
| --- | --- |
| **⌘⇧V** | Apre o chiude il pannello; disponibile anche dalle altre applicazioni. |
| Digitazione | Avvia la ricerca nel campo già focalizzato. |
| **Invio** | Incolla o copia la selezione secondo la modalità configurata. |
| **⌥Invio** | Richiede il testo semplice per la clip selezionata. |
| **⌘C** | Copia la clip o il batch selezionato; per le clip mantiene aperto il pannello. |
| **⌘⌥1…9**, **⌘⌥0** | Riutilizza la clip o lo snippet corrispondente al badge numerico. |
| **⌘1** / **⌘2** | Apre Preferiti / Snippet. |
| **⌘3…9**, **⌘0** | Apre le prime otto liste personali. |
| **⌘⌥A** | Torna a Tutte le clip; con il mapping predefinito funziona anche **⌘A**. |
| **↑ / ↓** | Sposta la selezione. |
| **⇧↑ / ⇧↓**, **⇧clic** | Estende o contrae un intervallo di selezione. |
| **⌘clic** o cerchio della riga | Aggiunge o rimuove un singolo elemento dalla selezione. |
| **⌘D** | Deseleziona il batch; altrimenti cambia lo stato di preferito della clip. |
| **⌘M** | Apre lo spostamento nella lista. |
| **⌘,** | Apre le impostazioni. |
| **Spazio / ←** | Apre l’anteprima quando la ricerca non sta consumando quel tasto. |
| **→** | Chiude l’anteprima. |
| **Esc** | Chiude anteprima o modale, deseleziona il batch, svuota la query oppure chiude il pannello, secondo lo stato corrente. |

Con il mapping predefinito, **⌘A** torna a Tutte le clip anche quando il campo di ricerca è focalizzato.

I badge alfabetici compaiono soltanto quando la ricerca non è focalizzata e la lettera è disponibile; usano **⌘** e rispettano i comandi personalizzati. Le lettere riservate, inclusa **A**, non vengono mostrate come scorciatoie delle clip. Le combinazioni modificate di Spazio e frecce orizzontali restano disponibili per la digitazione.

Le ricerche composte da parole mantengono il matching FTS5 per prefisso. Le query con punteggiatura o simboli cercano invece l'intera stringa letterale nel testo e nei nomi personalizzati: ad esempio `~/Library`, `c++`, `50%` e `user_name` mantengono i propri simboli. `%` e `_` vengono cercati come caratteri, senza funzionare da jolly. Il confronto letterale ignora le maiuscole anche per le lettere accentate e riconosce rappresentazioni Unicode equivalenti.

Gli incollaggi vengono coordinati per evitare sovrapposizioni; un cambio di app o degli appunti durante la preparazione annulla l'invio. Il comando **Retry** della sincronizzazione verifica nuovamente i dati e può recuperare file locali danneggiati da una copia iCloud integra dello stesso contenuto; in assenza di una copia corrispondente segnala l'errore senza sovrascrivere il contenuto locale.

## Sviluppo

### Requisiti e avvio

- macOS 14 o successivo.
- Toolchain Swift 5.9 o successiva, con gli strumenti di sviluppo macOS necessari.
- Swift Package Manager; nessun generatore di progetto aggiuntivo.

```bash
git clone https://github.com/bicsurf/concopy.git
cd concopy
swift build
swift run ConCopyApp
```

L’avvio con `swift run` è utile durante lo sviluppo; per usare il bundle dell’app, la firma locale e le risorse impacchettate, usa lo script di packaging.

Il manifest seleziona **GRDB 7.5.0 con Swift 6+** e **GRDB 6.29.3 con Swift 5.9**. Le ultime verifiche, del 19 novembre 2026, sono state eseguite con **Swift 6.4.2 su arm64**; il percorso Swift 5.9 e la build x86_64 non sono stati rieseguiti.

### Build e test

Esegui tutti e tre i controlli prima di concludere una modifica, come richiesto da [AGENTS.md](AGENTS.md):

```bash
swift build
swift build -c release
swift test
```

La release deve compilare senza warning. L’ultima verifica conta **204 test: 203 passati, uno opzionale saltato, zero fallimenti**. Sono state inoltre superate 13 verifiche native di focus, ricerca e incollaggio in TextEdit e Sublime Text su macOS 27.2.1, con apertura del pannello confermata anche da tastiera fisica.

Il test opzionale usa un export reale Copy ’Em. Per abilitarlo:

```bash
CONCOPY_TEST_CEP_PATH="/percorso/al/proprio/export.cep" \
  swift test --filter ExternalImportTests.testRealUserExportIfPresent
```

Senza un percorso esistente il test viene saltato. Gli altri test di importazione usano fixture sintetiche.

### Bundle `.app` e DMG

```bash
./scripts/build-app.sh
./scripts/build-dmg.sh
```

`build-app.sh` compila per `arm64` e `x86_64`, prepara `ConCopy.app`, include icone e risorse e applica una firma ad-hoc. `build-dmg.sh` ricompila il bundle e crea `ConCopy-<versione>.dmg` nella root del repository, stampandone lo SHA-256.

La versione deriva, nell’ordine, da `VERSION`, da `GITHUB_REF_NAME` o dal tag Git individuato dallo script. Per specificarla esplicitamente:

```bash
VERSION=1.3.2 ./scripts/build-dmg.sh
```

Questo comando sceglie la versione del pacchetto locale; non crea tag né pubblica una release. Il workflow [release.yml](.github/workflows/release.yml) pubblica invece il DMG quando viene inviato un tag `v*`.

### Architettura e documentazione

| Target | Responsabilità |
| --- | --- |
| `ConCopyCore` | Storage GRDB/FTS5, cattura pasteboard, blob, importazione e backup, screenshot, eventi sintetici e sync. Nessuna dipendenza da SwiftUI o viste AppKit. |
| `ConCopyUI` | Pannello `NSPanel`, viste SwiftUI, anteprime, impostazioni e stato dell’interfaccia coordinato dal `ClipboardViewModel` su `@MainActor`. |
| `ConCopyApp` | Avvio, ciclo di vita, barra dei menu, collegamento dei servizi e scorciatoia globale. |

- [AGENTS.md](AGENTS.md): vincoli architetturali e comandi obbligatori.
- [WORKFLOW_STATE.md](WORKFLOW_STATE.md): stato operativo, decisioni e verifiche ancora da eseguire.
- [CHANGELOG.md](CHANGELOG.md): modifiche in lavorazione e cronologia delle versioni.

## Licenza

ConCopy è distribuito con licenza [MIT](LICENSE).
