# ConCopy - Architectural Guidelines & AI Agent Rules

This document defines system rules, architectural boundaries, and mandatory engineering patterns for any AI agent or developer working on the `concopy` repository.

---

## 1. Three-Target Architecture (Isolation Rules)

The project is strictly structured into three Swift Package Manager (SPM) targets:

```
Sources/
  ├── ConCopyCore (Static library)
  ├── ConCopyUI   (Static library)
  └── ConCopyApp  (Standalone macOS executable)
```

1. **`ConCopyCore`**:
   - **No SwiftUI dependency**: Never import `SwiftUI`, `NSView`, `NSWindow`, or UI views into this target.
   - Responsibilities: `NSPasteboard` monitoring, query sanitization and SQLite storage with `GRDB.swift` + `FTS5`, SHA-256 cryptographic deduplication, disk blob I/O, synthetic `CGEvent` injection, filesystem watchers, non-blocking sync via `CloudDriveSyncEngine` and `CloudDriveSyncWorker` (`iCloud Drive`), JSON archives, structured logging via `ConCopyLogger`, and sensitive clip auto-expiration.
   - **Concurrency & Threading**: Heavy I/O, parsing, and computations must occur on background threads or dedicated `actor` instances, never bound to `@MainActor`.

2. **`ConCopyUI`**:
   - Depends exclusively on `ConCopyCore` and `KeyboardShortcuts`.
   - Responsibilities: Floating HUD panel (`FloatingPanel` based on `NSPanel`), modular subviews (`ClipRowView`, `ClipBatchBarView`, `ClipContextMenu`, `MoveToListSheetView`, `SnippetsViews`, `NavigationComponents`), QuickLook preview popovers, preferences window (`PreferencesView`).
   - Interface state coordination is managed by `ClipboardViewModel` annotated with `@MainActor`, delegating specialized logic to `BatchSelectionManager`, `PasteQueueManager`, and `SearchCoordinator`.

3. **`ConCopyApp`**:
   - Depends on `ConCopyCore` and `ConCopyUI`.
   - Configured as an invisible menubar app in the Dock (`LSUIElement = true`).
   - Responsibilities: `AppDelegate`, application lifecycle, `NSStatusItem`, global shortcut registration, Accessibility permission verification.

---

## 2. Critical System Rules (AppKit & Windows)

### Zero Focus Stealing
The main window (`FloatingPanel`) **must never steal focus** from the user's active application:
- Inherits from `NSPanel`.
- StyleMask: `[.titled, .nonactivatingPanel, .fullSizeContentView, .resizable]`.
- Mandatory properties: `isFloatingPanel = true`, `level = .floating`, `becomesKeyOnlyIfNeeded = true`.
- When activating the panel: call `orderFrontRegardless()` and `makeKeyAndOrderFront(nil)` without ever making the application or window a standard main window (`canBecomeMain = false`, `canBecomeKey = true`).

### Immediate Auto-Dismiss
The panel must dismiss immediately upon context change:
- Listen to `NSWindow.didResignKeyNotification`.
- Listen to `NSApplication.didResignActiveNotification`.
- Listen to `NSWorkspace.didActivateApplicationNotification` (to intercept clicks on external apps such as VS Code or Terminal).
- If `isVisible && attachedSheet == nil`, immediately call `orderOut(nil)`.

---

## 3. Keyboard Handling, Responder Chain & Type-to-Search

1. **Type-to-Search (Immediate Typing)**:
   - When the window opens, the `TextField` search box must automatically receive keyboard focus via `@FocusState` and `NSWindow.didBecomeKeyNotification` listeners.
   - Do not require pressing `Cmd + F` manually to begin typing.

2. **Window-Level Event Interception (`sendEvent`)**:
   - In `FloatingPanel.sendEvent(_:)`, intercept critical function keys **before** the event reaches AppKit/SwiftUI responder chain:
     - `Return / Enter` (keyCodes 36, 76): pastes the selected clip.
     - `↑ / ↓` (keyCodes 126, 125): move selection in list (Shift expands range for multi-selection).
     - `Cmd + 1 ... 9`, `Cmd + 0`: switch tab/list; `Cmd + Option + 1 ... 9`, `Cmd + Option + 0`: quick paste. Modifier swap reverses these two families; both exclude Shift and Control and use hardware keycode fallback.
     - `Cmd + Option + A`: All clips; with default mapping `Cmd + A` also works.
     - `Option` and `Option + Shift` with text keys: leave events to responder chain for symbols and accents, without intercepting them as numeric or navigation shortcuts.
     - `Option + Return / Enter`: maintain plain text paste.
     - `Cmd + D`: rapid deselection if multi-selection active, otherwise toggle favorites.
     - `Cmd + M`: open move to list sheet.
     - `Escape`: closes modal sheets, clears batch selection if active, clears query if set, or closes panel (`orderOut(nil)`).

3. **Hardware KeyCode Mapping**:
   - Due to AppKit behavior on international keyboard layouts (IT, US, FR, DE, numeric keypad), do not rely solely on `charactersIgnoringModifiers`.
   - Always use the helper function `digitIndex(forKeyCode: event.keyCode)` to map hardware digit key codes (18..29 and 82..92).

4. **Local Event Monitor in Modal Sheets (`NSEvent.addLocalMonitorForEvents`)**:
   - Modal sheets (e.g. `MoveToListSheetView`) isolate the main window's responder chain.
   - Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in `.onAppear` and remove it in `.onDisappear` to intercept configured list shortcuts (`Cmd` or `Cmd + Option` with `1..9`, `0`, and `A`) and `Esc`.

5. **Literal Search**:
   - Queries with punctuation or symbols (e.g., `~/Library`, `c++`, `%`, `_`) must search the full string as a literal substring in text or custom name, preserving filters, ordering, and limits.
   - Literal comparison must respect Unicode canonical equivalence and case-insensitivity beyond ASCII. The SQL function `concopy_literal_contains` must be registered on readers; always pass query text as parameters, never interpreting `%`, `_`, or backslash as wildcards.
   - If SQL `LIKE` queries are introduced, always escape `%`, `_`, and escape characters.
   - Maintain prefix FTS5 search on queries consisting of words and spaces, including combining diacritics within word characters.

6. **Badge Consistency**:
   - Generate badges and routing via `GlobalShortcutsManager.quickPasteShortcut` and shared resolvers. Do not display alphabetical badges while search is focused or for keys reserved for commands.
   - Modified Space and horizontal arrow keys must reach the responder chain without triggering QuickLook.

---

## 4. Memory Management & Performance

1. **`autoreleasepool` Release Cycles**:
   - All operations generating transient memory spikes must be wrapped in `autoreleasepool { ... }` blocks:
     - Heavy queries and `GRDB` record iterations.
     - Ingestion and decoding of images and screenshots (`NSBitmapImageRep`, `CGImage`).
     - Base64 serialization and deserialization in `ArchiveManager`.
     - `NSPasteboard` polling cycles in `ClipboardMonitor`.

2. **Asynchronous Offloading (`Task.detached`)**:
   - No disk I/O or hashing (SHA-256) operations may be executed on the main thread.
   - Use `Task.detached(priority: .utility)` for blob processing, URL metadata fetching, and screenshot ingestion.

3. **Stable Identity & Reactive Rendering**:
   - In SwiftUI list (`ClipboardListView`), use persistent identifier `clip.id` in `ForEach` and `.id(clip.id)` to keep rows and `ScrollViewReader` references stable.
   - Do not include index, timestamp, custom name, favorite status, or transient copy/selection states in view identities: updating them must not destroy and recreate rows.
   - Pass states and badges as reactive properties of `ClipRowView` and consider them in `Equatable` comparison, including index, selection, copy, and shortcut modifiers.
   - Maintain `.equatable()` compliance on `ClipRowView` to prevent unnecessary re-renders during scrolling.

4. **File Descriptor Leak Prevention**:
   - In `ScreenshotWatcher`, always close file descriptors in dispatch source cancellation handlers:
     ```swift
     source.setCancelHandler {
         close(fileDescriptor)
     }
     ```

---

## 5. Privacy & Loopback Prevention

1. **Pasteboard Security Filters**:
   - Strictly discard any content containing any of the following pasteboard types:
     - `org.nspasteboard.TransientType`
     - `org.nspasteboard.ConcealedType`
     - `org.nspasteboard.AutoGeneratedType`
     - `com.agilebits.onepassword`
   - Always respect the user-configured application blacklist and monitoring pause status.

2. **Loopback Prevention (`PasteInjector`)**:
   - Before writing to system pasteboard for synthetic paste operations, always set the internal marker type:
     ```swift
     pasteboard.setString("1", forType: NSPasteboard.PasteboardType("com.local.ConCopy.internalPaste"))
     ```
   - `ClipboardMonitor` must check for this marker and ignore the event to prevent infinite duplicate ingestion of pasted clips.

3. **Paste & Storage Integrity**:
   - All injectors must share a single queue per pasteboard, preserved across `await` points; re-evaluate frozen target PID, permissions, and `changeCount` before dispatching events. Abort the operation if context or clipboard has changed.
   - Each independent database must own its dedicated blob directory. Fallback uses `DatabaseStartup`, an isolated temporary directory, and a persistent warning banner; cleanup and sync are paused during that session without modifying saved settings.
   - Select and delete records within a single transaction, re-checking favorites and list memberships before deletion; remove unreferenced blobs only after commit.
   - Restore lists additively and enforce at most one active Auto-Star list. Cloud recovery can repair local blobs only with validated remote bytes exactly matching the expected SHA-256 filename.

---

## 6. Code Quality & Conventions

- **Zero Force-Unwraps**: Using `!` or `fatalError` in production code is prohibited. Always handle errors via `do-catch`, `guard let`, or safe fallbacks.
- **Swift Concurrency**: Use `async/await`, `actor`, and `@MainActor` adhering to isolation boundaries.
- **Zero Test Regressions**: Every change made to `ConCopyCore` or paste logic must keep the full test suite green and include regression tests for fixed issues.

---

## 7. Mandatory Verification Commands

Before completing any development session, always run:

```bash
# Verify debug compilation
swift build

# Verify optimized release build (zero warnings permitted)
swift build -c release

# Full unit and integration test suite execution
swift test
```
