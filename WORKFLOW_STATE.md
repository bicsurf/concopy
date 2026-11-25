# Work Status — ConCopy

Note November 24, 2026 — multi-image batch paste resolved on branch `fix/batch-paste-multi-images`:
1. **Multi-Image Batch Paste**: In `PasteInjector.copyBatchToPasteboard`, when all selected clips are of type `.image`, instead of concatenating OCR text (`clip.plainText`), images are exported temporarily via `FilePasteExporter` and registered as native `NSURL` file objects (`writeObjects`) onto the system pasteboard.
2. **Compatibility**: Enables simultaneous multi-image pasting into Finder, chat apps (Telegram, Slack, Messages), Keynote, Pages, Word, etc. Text concatenation is preserved when the selection contains text or mixed types.
3. **Verification & Tests**: Added unit test `testBatchPasteMultipleImagesWritesFileObjects` in `Phase4Tests`. Verifications: `swift build` ok, `swift build -c release` ok (zero warnings), `swift test` 228 tests / 1 skipped / 0 failures.

Updated on **November 25, 2026**. This file summarizes the verified working tree state for developers continuing development. Architectural constraints remain in [AGENTS.md](AGENTS.md); version history is maintained in [CHANGELOG.md](CHANGELOG.md).

---

## Current Status

| Item | Status |
| --- | --- |
| Active Branch | `chore/repo-prep-license-funding-readme` |
| Git Base | `719dced`; latest local tag `v1.3.2`. |
| Working Tree | Clean pre-release documentation & packaging improvements ready for review. |
| Functional Work | Full Sprint 1–4 capabilities implemented (quick filters, developer text transforms, Vision OCR & color swatches, paste stack & queue, dynamic snippet variables, privacy shield masking, contextual panel positioning, quick actions & rich link previews, multi-image batch paste). |
| Keyboard Shortcuts | Default mapping uses ⌘⌥ for quick paste and ⌘ for navigation; ⌥Enter retains plain text paste, and ⌘A returns to All Clips. Swap option available in Settings. |
| Licensing | GPLv3 text in `LICENSE`, `CONTRIBUTING.md` CLA established, references updated. |
| Cleanup | Temporary test logs, manual QA reports, and artifacts removed. Full regression test suite retained. |
| Publication | v1.3.2 released; next minor/patch release in preparation. |

Verify repository state with `git status --short` and `git log -1 --oneline --decorate` before starting work.

---

## Module Boundaries & Stack

| Area | Implementation |
| --- | --- |
| Verified Runtime | macOS 14+, Swift 6.4.2 arm64 (Swift 5.9 supported). |
| Manifest | Swift Package Manager, `swift-tools-version: 5.9`. |
| Dependencies | GRDB 7.5.0 with Swift 6+ (GRDB 6.29.3 on Swift 5.9); KeyboardShortcuts in `ConCopyUI`. |
| `ConCopyCore` | Pasteboard monitoring, SQLite/FTS5, blobs, importers, backup, screenshots, synthetic paste events, and iCloud Drive sync. No SwiftUI or AppKit view imports. |
| `ConCopyUI` | AppKit/SwiftUI; `@MainActor ClipboardViewModel`, non-activating HUD panel, and previews. |
| `ConCopyApp` | Menubar app with `LSUIElement`, service orchestration and lifecycle. |
| Storage | `DatabasePool` on disk, `DatabaseQueue` for in-memory tests; FTS5 external-content table `clips_fts`. |
| Blobs | Inlined up to 4,096 bytes; files over 4 KiB stored as `<sha256>.blob`, verified on open and repaired atomically on write. |
| Verification | XCTest and SPM commands. Packaging scripts remain decoupled from native host builds. |

Production storage paths:

```text
~/Library/Application Support/ConCopy/concopy.sqlite
~/Library/Application Support/ConCopy/blobs/
~/Library/Mobile Documents/com~apple~CloudDocs/ConCopy/sync-state-v2.json
```

---

## Audit Corrections & Preserved Invariants

Audit results summarize verified cases from previous review passes. Historic passes do not guarantee absence of new issues.

| Cycle | Scope |
| --- | --- |
| Cycle 1 | 37 items addressed; A30 deferred. |
| Cycle 2 | B01–B20 resolved; 24 regression tests added. |
| Cycle 3 | C01–C11 resolved; 17 regression tests added. |
| Production Audit | D01–D10 resolved; 25 regression tests added (concurrency, Unicode, fallback, transactions, cloud recovery, badges). |

### Key Invariants to Preserve

- **C01 / Migration**: Recalculating a binary identity does not constitute a user edit. Preserve existing metadata revisions, deletions, and aliases.
- **C02 / Metadata**: Favorite status, custom name, list membership, and manual order have clocks decoupled from content revisions. Distinguish default values of a re-copied clip from explicit user removals, even across offline aliases.
- **C03 / Usage Counters**: Legacy counter components preserve the original archive ID after deduplication; repeated imports must not double-count usage.
- **C04 / Snippets**: Use persistent origin and stable identity to identify previously restored snippets. A shortcut ending in `~restored` does not by itself imply a duplicate.
- **C05–C06 / Blobs**: Verify SHA-256 digests, repair corrupted files from valid data, and purge only unreferenced blobs after transaction commit. Rollbacks must keep original blobs intact.
- **C07 / Batch Paste**: Capture target PID before processing and initial delay; re-verify target PID and accessibility permissions before each event, including Tab.
- **C08–C09 / Paste Dispatch**: Separate event failures from usage statistic persistence errors. Snippet paste failures must be surfaced while keeping clipboard content ready for manual paste.
- **C10 / Import Limits**: Enforce SQLite limits in bytes before materializing payloads, including multi-byte Unicode strings.
- **C11 / Screenshots**: Do not capture on raw PNG headers alone; require complete chunks and decodable image pixels.
- **Keyboard Handling**: Respect configured ⌘/⌘⌥ shortcut swap; allow `Option` for text/accent typing and preserve `⌥Enter`. Badges must share shortcut resolvers.
- **D01–D02 / Paste Serialization**: Maintain a shared queue per pasteboard across `await` points; re-evaluate frozen target PID, permissions, and `changeCount` before dispatching synthetic events.
- **Row Content Display**: Display copied plain text or URL directly without synthetic titles. Web title scraping is disabled; legacy custom names remain searchable and preserved for sync/backup.

Regression tests are located in `Tests/ConCopyCoreTests/` under `Audit*Tests.swift`, `Reaudit*Tests.swift`, `ThirdAudit*Tests.swift`, and `ProductionAuditRegressionTests.swift`.

---

## Schema & Compatibility

| Migration | Purpose |
| --- | --- |
| v1–v3 | Initial schema, list ordering, and snippets. |
| v4 | Sync change journal. |
| v5 | Device-independent usage counter components. |
| v6 | Binary identity consolidation and migration. |
| v7 | Independent metadata revision clocks. |
| v8 | Restored snippet provenance and orphaned blob cleanup queue. |

Sync writes format **v2** and reads legacy v1 state for migrations. Fields `usage`, `metadataRevisions`, and `snippetOrigins` are optional during decoding; all syncing Macs should run updated builds to maintain these fields. Legacy v1/v2 backups remain readable.

---

## External Importer Contract

Maccy and Copy ’Em importers are integrated in Settings:

- `ExternalClipboardImporter` is `Sendable` and exposes synchronous `importClips(into:progress:) throws -> ImportResult`. The UI runs this via `Task.detached` off the main thread.
- `ImportResult` tracks imported items, merged duplicates, created lists, and errors (up to 100 details). `isSuccess` requires `errorsCount == 0`.
- `SourceDatabase` safely resolves files, copies database and WAL/SHM sidecars to a temporary sandbox, and opens the clone without applying ConCopy migrations.
- Importers reuse `CapturedClip.computeContentHash()`. Duplicate merging is conservative for local metadata and avoids touching `updatedAt`.
- Limits: **50 MiB per payload**, **500 MiB total per import**, **50,000 items**.
- UI refreshes both clips and lists after an import completes.

---

## Verification Checklist

Run before committing any changes:

```bash
swift build
swift build -c release
swift test
```

Release compilation must pass with **zero warnings**. The test suite currently contains **228 tests**, including one optional test.

Latest verification run (November 25, 2026):

| Check | Result |
| --- | --- |
| `swift build` | Passed, zero warnings. |
| `swift build -c release` | Passed, zero warnings. |
| `swift test` | 228 tests, 227 passed, 1 skipped, 0 failures. |

The optional test `ExternalImportTests.testRealUserExportIfPresent` requires `CONCOPY_TEST_CEP_PATH` set to a valid Copy ’Em `.cep` export file. Skipping this test is expected in environments without local fixtures.

---

## Pending Verifications

1. **Real Copy ’Em Export Fixture**: Run optional test with `CONCOPY_TEST_CEP_PATH` when real-world sample archives are available. Current suite validates synthetic fixtures.
2. **Multi-Mac iCloud Sync**: Validate offline changes, concurrent edits, and convergence across physical Macs.
3. **App Store & Packaging Pipeline**: Validate `.app` bundle, entitlements, code signing, and DMG generation with `./scripts/build-dmg.sh` before release.
