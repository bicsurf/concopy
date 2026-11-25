# Changelog

Notable changes to ConCopy are documented in this file by version, with a dedicated section for unreleased work. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **Quick Content-Type Filters & Developer Text Transformations**:
  - Filter clips instantly by type: text, code, links, images, and colors.
  - Built-in developer transformations: JSON format/minify, URL encode/decode, Base64 encode/decode, case conversion (camelCase, snake_case, PascalCase, kebab-case), and Markdown-to-HTML conversion.
- **Vision OCR & Color Swatches**:
  - Text extraction from captured images using Apple Vision OCR with indexing into SQLite FTS5.
  - Automatic detection of color formats (HEX, RGB, HSL) with interactive color swatch previews.
- **Paste Stack & Sequential Queue**:
  - LIFO Paste Stack and FIFO Paste Queue modes to paste sequences of clips into target fields without reopening the HUD panel between pastes.
- **Dynamic Snippets with Variables**:
  - Support for dynamic variables (`{date}`, `{time}`, `{clipboard}`) and interactive fill-in placeholders with a dedicated modal prompt before pasting.
- **Native Multi-Image Batch Paste**:
  - Export and paste multiple selected images simultaneously as native file objects (`NSURL`) into Finder and messaging applications (Slack, Telegram, Messages, Mail).
- **Privacy Shield & Sensitive Data Masking**:
  - Automated detection and masking for credit cards, passwords, and API keys with local biometric (Touch ID) or account password reveal.
- **Contextual Panel Positioning**:
  - Optional floating panel placement anchored near active text caret, mouse pointer, or centered on screen.
- **Quick Actions & Rich Link Previews**:
  - Fast execution of clips in Terminal, web browser, or custom scripts; rich web metadata previews fetching page titles and favicons.
- **Production Audit Regression Test Suite (D01–D10)**:
  - 25 regression tests covering paste destination locking, concurrency control, Unicode literal search equivalence, temporary history fallback isolation, atomic transactions, cloud blob recovery, and keyboard shortcut badge consistency.
- Sync v2 for payloads, lists, and snippets with stable identities, aliases, and persistent tombstones; transparent migration from legacy v1 state.
- Per-device usage counters and separate clocks for favorites, names, lists, and manual ordering.
- Persistent provenance for restored snippets across backups and iCloud Drive synchronization.
- History pagination extending beyond the first 100 search results.

### Changed

- History list rows display exact copied content: URLs are displayed cleanly without title scraping.
- Single-clicking a clip dismisses the HUD in both auto-paste and copy-only modes, operating on the selected item while preserving multi-selection via Shift/Command.
- Shortcut modifier swap updated to ⌘ / ⌘⌥: numeric shortcuts with Option and All Clips moved to ⌘⌥, keeping standard Option combinations free for typing symbols and accents; ⌥Enter preserved for plain text paste.
- Punctuation and symbol queries search literal substrings across text and custom names (including `%`, `_`, and backslashes); FTS5 prefix search preserved for word queries.
- Archive restoration is strictly additive, preserving modified local versions and recovering conflicting snippet versions with alternate shortcuts (`~restored`).
- CPU-intensive tasks (image decoding, OCR, hashing, search indexing) moved entirely to background actors and utility threads.
- Updated automated history retention to re-evaluate on settings changes and new clip captures.
- GRDB selected conditionally: 7.5.0 on Swift 6+ toolchains, 6.29.3 on Swift 5.9.
- Updated documentation and work tracking to English; removed obsolete Homebrew Cask references from active workflows.

### Fixed

- **Production Audits D01–D10**:
  - Paste operations share a serialized queue per pasteboard, preventing race conditions during concurrent pastes.
  - Frozen target PID, permissions, and clipboard change counts re-verified immediately before synthetic event dispatch.
  - Temporary history fallback operates in an isolated temporary directory, safeguarding persistent database blobs.
  - Atomicity enforced: rollback preserves existing blobs and restores consistent database state.
  - Literal search respects Unicode canonical equivalence and case folding across ASCII and non-ASCII characters.
  - Additive list restoration enforces at most one active Auto-Star list.
  - Damaged or missing local blobs recovered from validated intact remote iCloud copies.
  - Modified space and arrow inputs properly forwarded to search field without triggering QuickLook.
  - Shortcut badges strictly mirror active keyboard routing and exclude reserved command keys.
- Prevented pasteboard loopback using internal markers on synthetic paste events.
- Prevented accidental deselection of multi-item batches on edge clicks.
- Resolved crash on launch under ad-hoc code signatures when CloudKit entitlements were absent.

---

## [1.3.1] - 2026-11-16

### Fixed

- Aligned All Clips shortcut badge with configured modifier mapping.
- Standardized All Clips command: with default mapping, ⌘A is handled by the panel even when the search field is focused.

---

## [1.3.0] - 2026-11-16

### Changed

- UI localized to English.
- Overhauled clip list view, row components, preferences, previews, and theme.
- Updated multi-selection, click interactions, and favorites with dedicated test coverage.

---

## [1.2.4] - 2026-11-12

### Added

- History import from Maccy and Copy ’Em with deduplication and conservative metadata merging.
- Support for Copy ’Em native format and `.cep` export bundles, with asset extraction and dynamic SQLite type handling.
- Import settings section with progress indicators and detailed summary dialogs.
- Synthetic fixtures for external importers and optional integration test for real-world exports.

### Removed

- Homebrew Cask files removed from repository in favor of direct DMG releases.

---

## [1.2.3] - 2026-11-12

### Changed

- All Clips shortcut assigned to 'A' with the appropriate modifier matching configured mapping.
- Disabled automated Cask updates in packaging scripts.

---

## [1.2.2] - 2026-11-12

### Added

- Source application icon badge displayed on history rows.
- Shortcut customization with numeric modifier swap (⌘ / ⌥).
- Direct access to Snippets tab in list navigation.

### Changed

- Refactored settings, list view, HUD panel, and state management for improved rendering performance.

---

## [1.2.1] - 2026-11-11

### Fixed

- Refined multi-selection behavior with Shift and Command keys, along with batch deselection handling.
- Updated documentation for multi-item selection.

---

## [1.2.0] - 2026-11-11

### Added

- **Advanced Multi-Selection (Batch Copy / Paste)**:
  - Range selection with `⇧ + Click` and `⇧ + ↑/↓` with macOS Finder-style anchor point tracking (`selectionAnchorId`).
  - Item selection with `⌘ + Click` and circular row checkboxes with expanded hit areas (`28x28 pt`).
  - Concatenated multi-paste with configurable delimiters (newline, comma, space, tab) and sequential tabbed field entry.
  - Dedicated bottom action bar with selection count, delimiter picker, batch copy/paste buttons, and instant clear button.
  - In-app toast feedback on `⌘C` copy operations.
- **Quick Favorites**:
  - Interactive star icon on clip rows for instant toggle.
  - Shortcut `⌘D` for batch deselection or favorite toggle on selected record.
- **Settings Shortcut**:
  - Global `⌘,` shortcut to open Preferences directly from the HUD.
- **Automatic Update Checker**:
  - Periodic checks against GitHub releases API (`UpdateChecker`) with semantic version comparison.
- **Application Icon & Menubar Asset**:
  - High-resolution squircle icon generation via CoreGraphics (`scripts/generate-icon.swift`).
  - Vector monochrome template icon (`isTemplate = true`) for `NSStatusItem`.
- **Dynamic Versioning**:
  - Packaging scripts inject Git tag versions directly into `Info.plist`.

### Changed

- Clean HUD design: removed standard window title bar buttons for a minimal floating interface.
- Zero-latency copy: removed artificial delays in copy-only mode for immediate clipboard write.
- Switched to non-blocking JSON sync on iCloud Drive (`sync-state-v1.json`), removing CloudKit dependency.

---

## [1.0.1] - 2026-03-24

### Fixed

- Resolved universal binary detection issues in packaging scripts.
- Optimized GitHub Actions CI pipeline on macOS runners.
- Corrected bundle resource inclusion and code signature validation.

---

## [1.0.0] - 2026-03-15

### Added

- Initial release of ConCopy for macOS (Sonoma 14+).
- Universal Binary support (`arm64` Apple Silicon + `x86_64` Intel).
- Floating HUD panel (`FloatingPanel`) with zero focus-stealing (`LSUIElement = true`).
- Background clipboard monitoring for text, RTF, HTML, URLs, files, and images.
- Local SQLite database with `GRDB.swift` and full-text search with FTS5.
- QuickLook preview for images and long text (`Space` or `←`).
- Custom lists, favorite tagging, and Auto-Star automation.
- Reusable snippet templates.
- Synthetic paste injection via `CGEvent` with layout-independent hardware keycode mapping (`⌘1...9`, `⌘0`).
- Privacy filters ignoring concealed/transient types and 1Password entries.

[Unreleased]: https://github.com/bicsurf/concopy/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/bicsurf/concopy/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/bicsurf/concopy/compare/v1.2.4...v1.3.0
[1.2.4]: https://github.com/bicsurf/concopy/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/bicsurf/concopy/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/bicsurf/concopy/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/bicsurf/concopy/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/bicsurf/concopy/compare/v1.0.1...v1.2.0
[1.0.1]: https://github.com/bicsurf/concopy/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/bicsurf/concopy/releases/tag/v1.0.0
