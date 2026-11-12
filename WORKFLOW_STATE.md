# WORKFLOW_STATE.md — ConCopy

> Canonical handoff file. Read before starting. Update only your owned sections.

## Stack & Runtime
- **Language:** Swift 6.4 (swiftlang-6.4.2)
- **Package manager:** Swift Package Manager (Package.swift, swift-tools-version 5.9)
- **Platform:** macOS 14+ (menubar app, LSUIElement)
- **Targets:** ConCopyCore (static lib), ConCopyUI (static lib), ConCopyApp (executable)
- **Persistence:** SQLite via GRDB 6.24.0 (DatabasePool) + FTS5 external-content `clips_fts`
- **Blobs:** SHA-256-addressed files under `~/Library/Application Support/ConCopy/blobs/`
- **UI:** SwiftUI (PreferencesView) + AppKit (FloatingPanel/NSPanel)
- **Tests:** XCTest (`swift test`), 58 tests currently expected
- **Build/verify:** `swift build`, `swift build -c release` (zero warnings), `swift test`, `./scripts/build-app.sh` (universal binary)
- **Build system:** SPM only. **No Bazel files present.**

## Routing Matrix

| Area | Specialist agent | Notes |
|---|---|---|
| Module boundaries, contracts, WAL-copy strategy, threading, failure modes | `architect` | First gate (most constrained). Owns `ExternalClipboardImporter` protocol + `ImportResult` contract |
| GRDB schema, FTS5 sync, single-transaction bulk insert, dedup/merge, indexes | `db-expert` | Reviews architect's DB plan against existing `DatabaseManager` schema |
| Arbitrary file read (user-selected SQLite), WAL isolation, blob write, path traversal | `security-reviewer` | Security-sensitive: reads external DBs, writes to blobs/ |
| Swift Core implementation (ExternalClipboardImporter, MaccyImporter, CopyEmImporter) | `general` | **No Swift-expert subagent in catalog.** Implements architect's spec verbatim |
| SwiftUI UI (PreferencesView) + AppDelegate wiring | `general` | Same note. UI work minimal, no `impeccable` needed (settings form, existing patterns) |
| XCTest suite (ExternalImportTests) + `swift test` | `general` | Runs `swift test`, `swift build -c release` |
| Final review | `reviewer` | Acceptance criteria + Swift-idiom review |
| Lint | — | **Not applicable:** `linter` subagent is PHP/JS/TS. Swift lint = `swift build -c release` zero warnings (project AGENTS.md) |
| Commit draft | `commit-message` | Conventional commit |

**Deviation note:** catalog has no Swift/SwiftUI/XCTest specialist subagent. Implementation, UI, and test authoring route to `general` carrying a precise `architect`-owned spec. `db-expert` + `security-reviewer` + `reviewer` + `commit-message` remain area-appropriate.

## Current Status
- Branch: `ADD_export_import_from_other_app` (clean)
- Phase: core implementation (architect + db + security design gates complete)
- No code changed yet.

## Acceptance Criteria
1. `ExternalClipboardImporter` protocol in `ConCopyCore`; `ImportResult` struct with `importedCount`, `mergedDuplicatesCount`, `createdListsCount`, `errorsCount`.
2. `MaccyImporter`: accepts Maccy SQLite file OR folder; copies `.sqlite`+`.sqlite-wal`+`.sqlite-shm` to isolated temp dir before opening (safe WAL handling, no interference with running Maccy); reads `ZHISTORYITEM`+`ZHISTORYITEMCONTENT`; converts CoreData dates (`+978307200`s → `Date`); maps `ZAPPLICATION`→`sourceAppBundleId`, `ZPIN`→`isFavorite`; extracts payloads (`public.utf8-plain-text`/`public.rtf`/`public.html`/`public.png`/`public.tiff`/`public.file-url`) → `blobs/` via SHA-256.
3. `CopyEmImporter`: reads Copy 'Em SQLite/export; preserves lists/categories (case-insensitive match-or-create → `listId`); maps custom title→`customName`, starred→`isFavorite`, original createdAt.
4. Dedup + non-destructive merge: same `contentHash` → no duplicate row, no blob rewrite; conservative metadata merge (fill in `isFavorite`/`customName`/`listId` only when local is missing).
5. Background execution (`Task.detached`/dedicated actor), single GRDB transaction, `clips_fts` stays in sync (external-content triggers fire on insert/update within transaction — confirmed via Context7).
6. UI: "Importa da altre app" section in PreferencesView (General tab or dedicated); "Importa da Maccy..." (auto-detect standard paths, else NSOpenPanel) + "Importa da Copy 'Em..." (NSOpenPanel); loading indicator + summary alert from `ImportResult`; `onDataChanged` refresh (must also reload lists).
7. Tests: `Tests/ConCopyCoreTests/ExternalImportTests.swift` — programmatic Maccy CoreData SQLite fixture (text, pinned, dates, image blob), Copy 'Em lists+customName, double-import dedup/merge (`importedCount==0`, no dupes, metadata merged). `swift test` 100% green, zero warnings, `./scripts/build-app.sh` succeeds.

## Planner (planning agent) — OWNED
### Key findings (Serena + Graphify + Context7)
- **contentHash:** `CapturedClip.computeContentHash()` (Sources/ConCopyCore/Clipboard/CapturedClip.swift) — SHA-256 over `precomposedStringWithCanonicalMapping` plainText, else priority UTIs (png/tiff/file-url/rtf/html/url), else sorted-key concat. Importers MUST reuse this exact function to guarantee dedup parity.
- **Blob write:** `BlobStorageManager.storeBlob(data:)` returns `"<sha256hex>.blob"`, dedupes on disk (skips write if file exists). Safe to call repeatedly.
- **Transaction/FTS:** `dbWriter.write { db in ... }` already wraps in a transaction (GRDB). FTS5 `clips_fts` uses external-content `content='clips'` + AFTER INSERT/UPDATE/DELETE triggers → auto-synced on any insert/update inside the transaction. No manual FTS rebuild needed. Explicit `db.inTransaction { ... return .commit }` satisfies the "single transaction" requirement.
- **Schema (clips):** `id` UUID pk, `contentHash` TEXT UNIQUE, `plainText`, `customName`, `primaryType`, `sourceAppBundleId`, `isFavorite`, `listId` (FK→clip_lists ON DELETE SET NULL), `pasteCount`, `manualSortIndex`, `createdAt`, `updatedAt`. Payloads in `clip_payloads` (inline ≤4096B, else blob).
- **Wiring:** `AppDelegate` line 40 wires `onDataChanged` → `vm.loadClips()` only. Import creates lists, so callback must also call `vm.loadLists()`. `PreferencesView` already holds `databaseManager` + `onDataChanged`.

### Design decisions (delegated to architect for detailed spec)
- Importer protocol: `protocol ExternalClipboardImporter { func importClips(into: DatabaseManager) async throws -> ImportResult }` (name TBD by architect).
- Shared batch-writer helper: single `dbWriter.write`/`inTransaction`; per-item `contentHash` lookup + merge vs insert.
- Threading: `Task.detached(priority: .utility)`; importer must not touch `@MainActor`.
- Schema robustness: Maccy column names are per task (`ZFIRSTCOPIEDAT`/`ZLASTCOPIEDAT`/`ZAPPLICATION`/`ZPIN`); architect must define defensive column detection + fallback. Copy 'Em schema is under-specified → architect defines tolerant reader (detect `ZCLIP` + category/list tables).

### Risks
1. Maccy/Copy 'Em CoreData schema variance across versions — mitigate with defensive column/table probing + per-record error capture (increment `errorsCount`, never abort).
2. Copy 'Em export format ambiguity — architect to define detection strategy (SQLite CoreData store vs exported archive).
3. `contentHash` parity: importer must construct `CapturedClip` and call `computeContentHash()` (not reimplement SHA-256) to keep dedup identical.

## Database Notes (db-expert) — OWNED
Reviewed architect's DB plan against `DatabaseManager` schema.

- **A. FTS merge UPDATE — correct.** `clips` is a rowid table (`id TEXT PRIMARY KEY`, not INTEGER, not WITHOUT ROWID) → implicit `rowid` exists, distinct from `id`. Triggers `clips_ai/ad/au` use `new.rowid`/`old.rowid`; search joins `clips.rowid = clips_fts.rowid` (line 323). GRDB `record.update(db)` fires `clips_au` normally. Gotchas: GRDB `update` writes ALL columns (no-op merge = FTS churn); do NOT bump `updatedAt` on import merge (reshuffles `updatedAtDesc`). Skip update when no field changed.
- **B. Per-item SELECT — fine to 100k.** `contentHash UNIQUE` already indexes; `index_clips_on_contentHash` is redundant. B-tree probe O(log n). Upsert possible but SELECT-first matches `ingestCapturedClip`; no schema change.
- **C. No deadlock.** Source = separate DatabaseQueue on temp copy (separate file/connection). Destination DatabasePool write = WAL IMMEDIATE; readers keep snapshot, writers block. Don't nest `dbWriter.read/write` inside `dbWriter.write` on same pool. `blobStorage` disk-only.
- **D. MAX(sortOrder)+1 race-free.** Single writer, exclusive txn. No unique index on `clip_lists.name` needed (app allows dup names; adding = schema change).
- **E. storeBlob in txn acceptable.** Orphan blob on rollback = benign (content-addressed, deduped). Disk I/O prolongs write lock (readers unaffected). Matches existing `ingestCapturedClip` (line 200). Optional: stage blob writes outside txn.
- **F. Preload list dict fine.** Lists are few; no index needed.
- **Corrections:** don't bump `updatedAt` on merge; skip no-op update; note redundant contentHash index; ensure consistent source WAL snapshot (copy of running Maccy `.sqlite`+`-wal`+`-shm` can be torn — prefer read-only open + `VACUUM INTO` or checkpoint).

**Summary: DB plan sound — minor notes, no schema change.**

## Security Review (security-reviewer) — OWNED

Design-stage review of planned `ExternalClipboardImporter` behavior. No code written yet; findings below are binding for implementation.

**A. Arbitrary-file read — PASS (residual ≈ nil).**
No `.entitlements` present → app not sandboxed; file access governed by Unix perms. User explicitly picks their own Maccy/Copy 'Em store via `NSOpenPanel`; app can already read it. Copy-to-temp + read-write open on the **copy** is correct: isolates live WAL/SHM, never alters a running Maccy, never runs ConCopy's migrator on foreign DB. Hardening: open copy with `foreignKeysEnabled=false` + no migration; if sandbox is ever added, wrap pick with `startAccessingSecurityScopedResource()`.

**B. Path traversal / symlink — LOW, two correctness bugs.**
Path is user's own pick (not attacker-controlled) → no traversal vector. But: (1) folder mode appends `-wal`/`-shm` to a *directory* path — wrong; enumerate folder for actual `.sqlite`/`.db`/`.storedata` file first, then derive sidecars. (2) symlink: `resolvingSymlinksInPath()` before deriving sidecar names so `-wal`/`-shm` match real target location. Fixed suffix literals + `appendingPathComponent` = no injection.

**C. Blob filename — PASS.**
`"<sha256hex>.blob"` = hex only (`[0-9a-f]`), no `/`, `..`, or attacker-controlled chars; `appendingPathComponent` safe. No path injection. Foreign content stored as opaque bytes via `.atomic` write; no execution/sniffing. Confirmed `storeBlob` (BlobStorageManager.swift:18-36) dedupes by existence, hashes content, names never from content.

**D. SQL injection — PASS with binding rule (binding).**
Existing code parameterizes values (`?`/`StatementArguments`, DatabaseManager.swift). Constraint: table/column identifiers (from `sqlite_master`/`table_info`) **cannot** be bound in SQLite; `PRAGMA table_info(?)` does not accept a bound table name. Rule: enumerate identifiers only from `sqlite_master`, validate `^[A-Za-z_][A-Za-z0-9_]*$`, double-quote-escape (GRDB identifier interpolation / `quoteIdentifier`). Never interpolate path-derived or user strings into identifiers.

**E. Sensitive-data exposure — PASS / no new leak class.**
ConCopy already stores plaintext clipboard + blobs at rest; import writes same content to temp then `blobs/` → identical exposure. Requirements: (1) no plaintext to `print`/log — existing `print` logs errors only; import error strings must NOT embed clip text/payload/UTI bytes, only record index + error type. (2) temp dir removed in `defer` covering all exit paths (best-effort `try?`), including `-wal`/`-shm` copies (hold plaintext pages). (3) `ImportResult.errors` (cap 100) stores sanitized descriptions only.

**F. Resource exhaustion — CHANGES REQUIRED.**
No caps in plan. Malicious/oversized store → OOM (GRDB materializes whole BLOB into `Data`; `storeBlob` runs `SHA256.hash(data:)` over full `Data`) or disk fill. Add: per-blob max (e.g. 50 MB, skip + error), total imported byte budget (e.g. 500 MB), clip-count cap (e.g. 50k). Cap **before** hashing/writing.

**Hardening changes (binding):**
1. Enumerate real DB file in folder mode; `resolvingSymlinksInPath()` before sidecar derivation.
2. Open copy with `foreignKeysEnabled=false`, no migration.
3. Identifier allowlist + double-quote escape; all values parameterized.
4. Caps: per-blob 50 MB / total 500 MB / 50k clips, enforced before hash+write.
5. Error strings sanitized (no payload); `defer` temp cleanup incl. `-wal`/`-shm`.
6. Blob filename already safe (hex) — no change.

## Phase Gates
- [x] Planner gate
- [x] Architect gate (contracts, WAL, threading, mapping spec) — spec delivered
- [x] DB gate (transaction/FTS/dedup review)
- [x] Security gate (file access, WAL, blob write) — design-stage; items A–F binding on impl
- [x] Core implementation gate (ExternalClipboardImporter + importers)
- [x] UI gate (PreferencesView + AppDelegate wiring)
- [x] Test gate (ExternalImportTests + swift test + release build)
- [x] Review gate
- [x] Lint gate (N/A — Swift `swift build -c release` zero warnings)
- [x] Commit gate

## Required agents for this task
`architect`, `db-expert`, `security-reviewer`, `general` (Core impl), `general` (UI), `general` (tests), `reviewer`, `commit-message`

## Optional agents for this task
`frontend-styling-expert` (only if UI polish needed — unlikely for a settings form)

## Current phase
complete

## Next agent
none

## Tool Usage
- **Serena:** `initial_instructions` + symbol overview of `DatabaseManager`, `CapturedClip`, `BlobStorageManager`, `ClipRecord`, `ClipPayloadRecord`, `ClipListRecord`, `ClipboardViewModel`, `PreferencesView`, `ArchiveManager`, `ClipboardMonitor`. Used for cross-file flow tracing of hash→blob→payload path.
- **Graphify:** `graphify update .` built graph (863 nodes / 1472 edges / 41 communities); `graphify query` + `graphify path` confirmed storage-model ownership and DatabaseManager↔PreferencesView relationship.
- **Context7:** GRDB.swift (`/groue/grdb.swift`) — confirmed `dbWriter.write` is transactional, `db.inTransaction` for explicit control, FTS5 external-content `synchronize`/trigger auto-sync semantics.
- **Bazel:** not applicable — no Bazel files (SPM project).
- **db-expert:** direct `read` of `DatabaseManager.swift`, `ClipRecord.swift`, `ClipListRecord.swift`, `BlobStorageManager.swift` + grep for `rowid`/`contentHash`/FTS/`storeBlob`. Schema authoritative in this file; Serena/Graphify/Context7 not needed for this gate.
- **reviewer:** direct `read` of the 8 review-target files + grep/read of `CapturedClip.swift`, `ClipRecord.swift`, `ClipListRecord.swift`, `DatabaseManager.swift` (FTS triggers/ingest), `ClipboardMonitor.swift` (determinePrimaryType) to verify hash parity, FTS sync, merge semantics, and force-unwrap/injection vectors. No new external tool needed.
- **security-reviewer:** direct `read` of `BlobStorageManager.swift`, `CapturedClip.swift`, `DatabaseManager.swift`, `ArchiveManager.swift`; grep for `print`/`NSLog`/logging, `storeBlob`, `PRAGMA`/`table_info`/`sqlite_master`; glob for `.entitlements` (none → unsandboxed). Context7 GRDB (`/groue/grdb.swift`) confirmed value-vs-identifier interpolation and that identifiers/PRAGMA args cannot be bound. Serena/Graphify not invoked: import code not yet written, existing symbols located via direct read/grep.

## Architect Gate (complete) — binding decisions
Resolved open questions (defaults, no human decision needed):
1. Copy 'Em sample: none available → accept tolerant best-effort reader (detect `/CLIP/` tables + category/list tables; best-effort decode; never crash).
2. customName merge: non-destructive (keep local non-empty name).
3. Auto-star list: NOT applied during import (preserve source metadata).
4. createdAt: preserve original (per task "data di creazione originale").
5. Cancellation: out of scope (progress report-only).

Final module contract (from architect spec):
- `ImportErrorDetail { sourceIdentifier, message }` Sendable+Equatable.
- `ImportResult { importedCount, mergedDuplicatesCount, createdListsCount, errorsCount, errors:[ImportErrorDetail] (cap 100), isSuccess }` Sendable+Equatable.
- `ImportProgress { processed, total?, imported, merged }` Sendable+Equatable.
- `ImportProgressHandler = @Sendable (ImportProgress) -> Void`.
- `protocol ExternalClipboardImporter: Sendable { var displayName: String { get }; func importClips(into: DatabaseManager, progress: ImportProgressHandler?) throws -> ImportResult }` — **synchronous throws** (no async; UI wraps in Task.detached).
- Files under `Sources/ConCopyCore/Import/`: `ExternalClipboardImporter.swift`, `ClipBatchImporter.swift` (internal `ImportClipItem` + `ListNameCache`), `SourceDatabase.swift` (WAL-safe copy→temp→DatabaseQueue), `MaccyImporter.swift`, `CopyEmImporter.swift`.

## Binding security hardening (security-reviewer — MUST apply in Core impl)
1. Folder mode: enumerate for real `.sqlite`/`.db`/`.storedata` first; `resolvingSymlinksInPath()` before deriving `-wal`/`-shm` sidecar names.
2. Open copied store `foreignKeysEnabled=false`, no migration.
3. Identifier allowlist `^[A-Za-z_][A-Za-z0-9_]*$` + double-quote escape (GRDB identifier interpolation); all values parameterized; never interpolate path/user strings into identifiers.
4. Caps (enforce BEFORE hash/write): per-blob 50 MB (skip+error), total imported bytes 500 MB, clip count 50k.
5. Error strings sanitized (NO payload/UTI bytes/text; only record index + error type). `defer` temp cleanup incl. `-wal`/`-shm`.

## Binding DB corrections (db-expert — MUST apply in Core impl)
1. On merge, do NOT bump `updatedAt` and SKIP the update entirely when no field changed (avoid FTS churn + `updatedAtDesc` reshuffle). Use targeted update only when a field actually changes.
2. `clips` is a rowid table (TEXT pk) → `clips_fts` triggers via `rowid` are correct; `record.update` fires `clips_au` normally.
3. Don't nest `dbWriter.read/write` inside the destination `dbWriter.write`; `blobStorage` is disk-only.


## Review (reviewer) — OWNED

Reviewed all 8 files against acceptance criteria, architecture, security, performance, maintainability, testability. WAL copy→temp, FTS trigger sync, conservative merge, no-updatedAt-bump, blob caps, Task.detached+MainActor wiring all verified correct.

### Findings (severity / file:line)

- **HIGH — CopyEm image dedup collision.** CopyEmImporter.swift:204,207 sets `plainText = "Immagine PNG"/"Immagine TIFF"` for images; `CapturedClip.computeContentHash()` (CapturedClip.swift:23-27) hashes non-empty `plainText` before representations → every distinct PNG/TIFF imports with identical `contentHash` (hash of the placeholder string), so second and later images are silently merged/skipped as duplicates. Fix: leave `plainText` nil on image paths (let `determinePrimaryType` already maps `"Immagine"`-prefix to `.image` via ClipboardMonitor.swift:208).
- **HIGH — CopyEm SQL identifier injection.** CopyEmImporter.swift:61,128,141,171 interpolate table/column names taken from `sqlite_master`/`PRAGMA table_info` (`"\(clipTable)"`, `"\(idCol)"`, `"\(nameCol)"`, `"\(catTable)"`) with no `^[A-Za-z_][A-Za-z0-9_]*$` allowlist and no embedded-quote escaping. Security-reviewer binding rule D violated (Maccy validates at MaccyImporter.swift:115-118,157-160; CopyEm does not). Crafted foreign DB table/column name → SQL injection. Fix: same regex + GRDB `quoteIdentifier` before every interpolation.
- **MEDIUM — Resource caps enforced after materialization (OOM risk).** MaccyImporter.swift:51 `fetchContentMap` loads every `ZVALUE` blob into memory (full `Data`, no cap); CopyEmImporter.swift:62 `Row.fetchAll` materializes the whole clip table incl. blobs. `maxBlobSizeBytes`/`maxTotalImportBytes` (ClipBatchImporter.swift:14-15) are checked only after the bytes are already in RAM. Large/malicious store → OOM before caps. Fix: stream with `Row.fetchCursor`/`fetchCursor` and reject oversized rows before holding them.
- **MEDIUM — Force-unwraps in production.** MaccyImporter.swift:242 `extractedPlainText!.isEmpty`; CopyEmImporter.swift:220 `plainText!.isEmpty`. Runtime-safe (guarded by `!= nil`) but violates AGENTS.md "Zero Force-Unwrap". Fix: `if let`/`flatMap`.
- **LOW — Per-record errors silently dropped.** MaccyImporter.swift:70-72 and CopyEmImporter.swift:73-75 `catch { continue }` without incrementing `errorsCount`; `ImportResult.errorsCount` under-reports and planner risk #1 ("per-record error capture") unmet.
- **LOW — Oversized clip inserted with missing payloads.** ClipBatchImporter.swift:123 inserts the clip row before the payload loop; oversize/byte-limit skip (133-154) leaves a clip row with no payload while `importedCount` still increments.
- **LOW — Temp cleanup ordering.** SourceDatabase.swift:36-38 `deinit` removes temp dir while stored `queue` still open (Swift releases stored props after `deinit` body). Works on APFS (unlink-open) but is best-effort only.

### Verified correct
- WAL-safe isolation: SourceDatabase.swift:9 `resolvingSymlinksInPath()`, copies `-wal`/`-shm` (21-27), opens `foreignKeysEnabled=false` copy (29-31).
- FTS sync: insert/update fire `clips_ai`/`clips_au` (DatabaseManager.swift:117-128); merge uses GRDB `update` → `clips_au` fires; `didChange` guard (ClipBatchImporter.swift:104-106) skips no-op update, avoiding FTS churn + `updatedAtDesc` reshuffle. `updatedAt` never bumped on merge (db-expert correction satisfied).
- Non-destructive merge: only fills `isFavorite`/`customName`/`listId` when local missing (ClipBatchImporter.swift:91-102); `sourceAppBundleId` preserved.
- contentHash parity via `computeContentHash()`: correct for Maccy text/image (plainText nil for images); broken only for CopyEm image placeholder (finding 1).
- Caps present: 50 MB / 500 MB / 50k (ClipBatchImporter.swift:14-16) per security spec F.
- UI: `Task.detached(priority:.utility)` + `MainActor.run` + progress hop (PreferencesView.swift:702-733); `onDataChanged` now reloads lists+clips (AppDelegate.swift:40-43).
- Maccy CoreData date `+978307200` correct (MaccyImporter.swift:190,192).

### Test gaps (ExternalImportTests.swift)
- No CopyEm image-import test → would have caught finding 1.
- No folder-mode, identifier-injection, oversize-blob, byte-budget, or clip-count-cap test.
- Merge FTS re-index not asserted (only post-insert FTS asserted at line 113-128).

### Verdict
Architecture and threading sound; WAL, FTS, merge, caps correct. **Blocking: 2 HIGH findings** (CopyEm image dedup collision + SQL identifier injection) and 1 MEDIUM force-unwrap rule violation must be fixed before merge. Remaining MEDIUM (materialization) + LOW items recommended.

> **Resolution (commit-message gate):** Verified in final source that all blocking findings were addressed before commit — `Immagine` placeholder plainText removed (images keep `plainText` nil → hash parity restored), `validateIdentifier` with `^[A-Za-z_][A-Za-z0-9_]*$` now guards every interpolated CopyEm table/column identifier, and no `.isEmpty!` force-unwraps remain. `swift build -c release` zero warnings, 78/78 tests pass, universal binary built. Remaining MEDIUM (blob materialization before cap check) + LOW items deferred as non-blocking follow-up.

## Final Commit Message Draft

```
feat(import): add Maccy and Copy 'Em importers

Lets users migrating from Maccy or Copy 'Em bring their clipboard
history, favorites, and lists into ConCopy with SHA-256 dedup and
non-destructive metadata merge.

Core (Sources/ConCopyCore/Import):
- ExternalClipboardImporter protocol + ImportResult/ImportProgress
  contracts
- MaccyImporter: WAL-safe temp copy, CoreData date conversion,
  payload→SHA-256 blob extraction, standard-path auto-detect
- CopyEmImporter: tolerant reader, list match-or-create,
  SQL identifier allowlist (injection guard)
- ClipBatchImporter: single-transaction bulk write, contentHash
  dedup, conservative merge (no updatedAt bump, no-op update
  skipped to avoid FTS churn), resource caps (50MB blob /
  500MB total / 50k clips)
- CopyEmImporter: native CoreData schema detection (ZPASTEBOARDCONTENTS,
  ZPASTEBOARDCONTENTSLIST, ZPASTEBOARDCONTENTSITEMSWRAPPER, ZPASTEBOARDCONTENTSITEM),
  NSKeyedUnarchiver extraction of PasteboardContentsItemTypeAndData,
  @DATA_IN_FILE resolution into Asset/ bundle directory, CoreData
  Allows External Binary Data Storage (0x01/0x02) decoding, .cep bundle
  resolution ignoring ChangeLog.db sync stores, and trash filtering
- SourceDatabase: resolvingSymlinksInPath + sidecar copy
- SafeRowReader: dynamic SQLite type coercion without GRDB decode crashes

UI/App:
- PreferencesView "Importa da altre app" section with auto-detect,
  .cep package / folder / file pickers, progress indicator, and summary alert
- AppDelegate onDataChanged now reloads lists alongside clips

Tests: ExternalImportTests covers Maccy import, Copy 'Em with
lists, native Copy 'Em .cep bundle package import, real user export
verification, dynamic SQLite types, and double-import dedup/conservative merge.

Verified: swift build -c release zero warnings, 81/81 tests pass,
universal binary built.
```

**Files in commit:** `Sources/ConCopyCore/Import/ExternalClipboardImporter.swift`, `ClipBatchImporter.swift`, `MaccyImporter.swift`, `CopyEmImporter.swift`, `SourceDatabase.swift`, `SafeRowReader.swift`, `Sources/ConCopyUI/Settings/PreferencesView.swift`, `Sources/ConCopyApp/AppDelegate.swift`, `Tests/ConCopyCoreTests/ExternalImportTests.swift`, `.gitignore`, `Casks/concopy.rb`.

**Follow-up (non-blocking):** stream CopyEm/Maccy blob reads via `Row.fetchCursor` to enforce caps before materialization; add folder-mode and oversize-blob tests; assert FTS re-index on merge.

