import AppKit
import ConCopyCore
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // MARK: - General Configurable Shortcuts
    public static let toggleConCopyPanel = Self(
        "toggleConCopyPanel",
        default: .init(.v, modifiers: [.command, .shift])
    )
    public static let copySelection = Self(
        "copySelection",
        default: .init(.c, modifiers: [.command])
    )
    public static let pasteSelection = Self(
        "pasteSelection",
        default: .init(.return)
    )
    public static let moveToList = Self(
        "moveToList",
        default: .init(.m, modifiers: [.command])
    )
    public static let toggleFavorite = Self(
        "toggleFavorite",
        default: .init(.d, modifiers: [.command])
    )
    public static let focusSearch = Self(
        "focusSearch",
        default: .init(.f, modifiers: [.command])
    )
    public static let openPreferences = Self(
        "openPreferences",
        default: .init(.comma, modifiers: [.command])
    )
    public static let pasteNextFromQueue = Self(
        "pasteNextFromQueue",
        default: .init(.v, modifiers: [.command, .control])
    )
}

public enum ShortcutScope: String, Sendable {
    case global = "Global"
    case inPanel = "In-Panel"
}

public enum ConCopyShortcutKey: String, CaseIterable, Identifiable, Sendable {
    case toggleConCopyPanel = "toggleConCopyPanel"
    case pasteSelection = "pasteSelection"
    case copySelection = "copySelection"
    case moveToList = "moveToList"
    case toggleFavorite = "toggleFavorite"
    case focusSearch = "focusSearch"
    case openPreferences = "openPreferences"
    case pasteNextFromQueue = "pasteNextFromQueue"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleConCopyPanel:
            return "Open / Close ConCopy"
        case .pasteSelection:
            return "Paste Selected Item"
        case .copySelection:
            return "Copy Item to Clipboard"
        case .moveToList:
            return "Move to List / Snippets"
        case .toggleFavorite:
            return "Add / Remove from Favorites"
        case .focusSearch:
            return "Focus Search Field"
        case .openPreferences:
            return "Open Settings"
        case .pasteNextFromQueue:
            return "Paste Next from Queue / Stack"
        }
    }

    public var systemImage: String {
        switch self {
        case .toggleConCopyPanel:
            return "macwindow.on.rectangle"
        case .pasteSelection:
            return "arrow.right.doc.on.clipboard"
        case .copySelection:
            return "doc.on.doc"
        case .moveToList:
            return "folder.badge.gearshape"
        case .toggleFavorite:
            return "star"
        case .focusSearch:
            return "magnifyingglass"
        case .openPreferences:
            return "gearshape"
        case .pasteNextFromQueue:
            return "rectangle.stack.badge.play"
        }
    }

    public var scope: ShortcutScope {
        switch self {
        case .toggleConCopyPanel, .pasteNextFromQueue:
            return .global
        default:
            return .inPanel
        }
    }

    public var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .toggleConCopyPanel: return .toggleConCopyPanel
        case .pasteSelection: return .pasteSelection
        case .copySelection: return .copySelection
        case .moveToList: return .moveToList
        case .toggleFavorite: return .toggleFavorite
        case .focusSearch: return .focusSearch
        case .openPreferences: return .openPreferences
        case .pasteNextFromQueue: return .pasteNextFromQueue
        }
    }

    public var defaultShortcut: KeyboardShortcuts.Shortcut? {
        shortcutName.defaultShortcut
    }

    @MainActor
    public var currentShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: shortcutName)
    }

    @MainActor
    public var isEnabled: Bool {
        currentShortcut != nil
    }
}

@MainActor
public final class GlobalShortcutsManager: ObservableObject {
    public struct QuickPasteShortcut: Equatable, Sendable {
        public let label: String
        public let modifierSymbol: String
    }
    public static let shared = GlobalShortcutsManager()
    public static let swapNumericModifiersKey = "ConCopy.Shortcuts.swapNumericModifiers"

    @Published public private(set) var swapNumericModifiers: Bool = false
    @Published public private(set) var changeVersion: Int = 0

    private var notificationObserver: (any NSObjectProtocol)?

    public var listModifierSymbol: String {
        swapNumericModifiers ? "⌘⌥" : "⌘"
    }

    public var quickPasteModifierSymbol: String {
        swapNumericModifiers ? "⌘" : "⌘⌥"
    }

    public func quickPasteShortcut(for index: Int, searchFocused: Bool) -> QuickPasteShortcut? {
        guard let label = QuickPasteShortcutMapper.label(forIndex: index) else { return nil }
        if index < 10 { return QuickPasteShortcut(label: label, modifierSymbol: quickPasteModifierSymbol) }
        guard !searchFocused, let character = label.first, !isCharacterReservedForCommands(character) else { return nil }
        return QuickPasteShortcut(label: label, modifierSymbol: "⌘")
    }

    public func matchedLetterQuickPasteIndex(for event: NSEvent, searchFocused: Bool) -> Int? {
        let flags = event.modifierFlags
        guard flags.contains(.command), !flags.contains(.shift), !flags.contains(.control),
            let character = event.charactersIgnoringModifiers?.lowercased().first,
            character >= "a", character <= "z",
            let index = QuickPasteShortcutMapper.index(forCharacter: String(character)),
            quickPasteShortcut(for: index, searchFocused: searchFocused) != nil else { return nil }
        return index
    }

    public init() {
        self.swapNumericModifiers = UserDefaults.standard.bool(forKey: Self.swapNumericModifiersKey)

        // Ensure in-panel shortcuts are not registered as system-wide Carbon hotkeys
        Self.disableInPanelHotKeys()

        // Observe shortcut changes made via KeyboardShortcuts.Recorder or programmatically
        notificationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name {
                    if let key = ConCopyShortcutKey.allCases.first(where: { $0.shortcutName == name }),
                        key.scope == .inPanel
                    {
                        KeyboardShortcuts.disable(name)
                    }
                }
                self.changeVersion &+= 1
            }
        }
    }

    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Disables Carbon global hotkey registration for in-panel shortcuts so they are routed to window events.
    public static func disableInPanelHotKeys() {
        for key in ConCopyShortcutKey.allCases where key.scope == .inPanel {
            KeyboardShortcuts.disable(key.shortcutName)
        }
    }

    public func notifyShortcutChanged() {
        Self.disableInPanelHotKeys()
        changeVersion &+= 1
    }

    /// Determines if a character is reserved by system commands or by currently configured ConCopy shortcuts.
    public func isCharacterReservedForCommands(_ char: Character) -> Bool {
        // System reserved shortcuts
        let systemReserved: Set<Character> = ["a", "q", "w", "x", "z", "v"]
        if systemReserved.contains(char) {
            return true
        }

        // Configured shortcuts that use Command modifier
        for key in ConCopyShortcutKey.allCases {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: key.shortcutName) else { continue }
            if shortcut.modifiers.contains(.command) {
                if let keyChar = shortcut.description.lowercased().last, keyChar == char {
                    return true
                }
            }
        }

        return false
    }

    public func setSwapNumericModifiers(_ isSwapped: Bool) {
        guard isSwapped != self.swapNumericModifiers else { return }
        self.swapNumericModifiers = isSwapped
        UserDefaults.standard.set(isSwapped, forKey: Self.swapNumericModifiersKey)
        changeVersion &+= 1
    }

    public func shortcut(for key: ConCopyShortcutKey) -> KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: key.shortcutName)
    }

    public func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut?, for key: ConCopyShortcutKey) {
        KeyboardShortcuts.setShortcut(shortcut, for: key.shortcutName)
        if key.scope == .inPanel {
            KeyboardShortcuts.disable(key.shortcutName)
        }
        changeVersion &+= 1
    }

    public func removeShortcut(for key: ConCopyShortcutKey) {
        KeyboardShortcuts.setShortcut(nil, for: key.shortcutName)
        if key.scope == .inPanel {
            KeyboardShortcuts.disable(key.shortcutName)
        }
        changeVersion &+= 1
    }

    public func resetShortcut(for key: ConCopyShortcutKey) {
        KeyboardShortcuts.reset(key.shortcutName)
        if key.scope == .inPanel {
            KeyboardShortcuts.disable(key.shortcutName)
        }
        changeVersion &+= 1
    }

    public func resetAll() {
        self.swapNumericModifiers = false
        UserDefaults.standard.set(false, forKey: Self.swapNumericModifiersKey)
        for key in ConCopyShortcutKey.allCases {
            KeyboardShortcuts.reset(key.shortcutName)
            if key.scope == .inPanel {
                KeyboardShortcuts.disable(key.shortcutName)
            }
        }
        changeVersion &+= 1
    }

    /// Determines if an incoming `NSEvent` matches the shortcut assigned to `key`.
    /// Returns `false` if the shortcut is disabled/removed.
    public func matches(event: NSEvent, for key: ConCopyShortcutKey) -> Bool {
        guard let target = KeyboardShortcuts.getShortcut(for: key.shortcutName) else {
            return false
        }
        guard let eventShortcut = KeyboardShortcuts.Shortcut(event: event) else {
            return false
        }

        // Option+Return/Enter is the plain-text variant of the configured paste command.
        if key == .pasteSelection, target.carbonKeyCode == 36,
            event.keyCode == 36 || event.keyCode == 76,
            eventShortcut.modifiers.subtracting(.option) == target.modifiers,
            eventShortcut.modifiers.contains(.option)
        {
            return true
        }

        // Exact match
        if eventShortcut == target {
            return true
        }

        // Support Numpad Enter (76) when Return (36) is registered
        if target.carbonKeyCode == 36 && (event.keyCode == 36 || event.keyCode == 76)
            && eventShortcut.modifiers == target.modifiers
        {
            return true
        }

        return false
    }

    /// Option used to activate quick paste is consumed by the shortcut, not a plain-text request.
    public func plainTextOverride(for event: NSEvent) -> Bool {
        event.modifierFlags.contains(.option) && matchedQuickPasteIndex(for: event) == nil
    }

    /// Determines if an incoming `NSEvent` matches the shortcut for selecting "All" (All clips).
    /// Always matches Cmd+Option+A, and matches Cmd+A when `swapNumericModifiers` is false.
    public func matchesAllClips(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let isCommandOptionA =
            flags.contains(.command) && flags.contains(.option) && !flags.contains(.control) && !flags.contains(.shift)
        let isCommandA =
            flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control) && !flags.contains(.shift)
            && !swapNumericModifiers

        guard isCommandOptionA || isCommandA else {
            return false
        }

        // KeyCode 0 is 'a' on ANSI macOS keyboard layout
        if event.keyCode == 0 {
            return true
        }

        if let char = event.charactersIgnoringModifiers?.lowercased().first, char == "a" {
            return true
        }

        return false
    }

    /// Resolves list digit 1..9 (and 0) from the given keyboard event according to the current modifier configuration.
    public func matchedListDigit(for event: NSEvent) -> Int? {
        guard matchesNumericModifiers(event, optionRequired: swapNumericModifiers) else {
            return nil
        }

        if let idx = digitIndex(forKeyCode: event.keyCode) {
            if idx >= 0 && idx <= 8 {
                return idx + 1  // 1..9
            } else if idx == 9 {
                return 0  // 0
            }
        }

        if let char = event.charactersIgnoringModifiers?.first,
            let d = char.wholeNumberValue, d >= 0 && d <= 9
        {
            return d
        }

        return nil
    }

    /// Resolves quick paste item index 0..9 from the given keyboard event according to the current modifier configuration.
    public func matchedQuickPasteIndex(for event: NSEvent) -> Int? {
        guard matchesNumericModifiers(event, optionRequired: !swapNumericModifiers) else {
            return nil
        }

        if let idx = digitIndex(forKeyCode: event.keyCode) {
            return idx
        }

        if let char = event.charactersIgnoringModifiers?.first {
            if char >= "1" && char <= "9", let digit = Int(String(char)) {
                return digit - 1
            } else if char == "0" {
                return 9
            }
        }

        return nil
    }

    private func matchesNumericModifiers(_ event: NSEvent, optionRequired: Bool) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) && flags.contains(.option) == optionRequired
            && !flags.contains(.control) && !flags.contains(.shift)
    }

    private func digitIndex(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 0  // 1
        case 19, 84: return 1  // 2
        case 20, 85: return 2  // 3
        case 21, 86: return 3  // 4
        case 23, 87: return 4  // 5
        case 22, 88: return 5  // 6
        case 26, 89: return 6  // 7
        case 28, 91: return 7  // 8
        case 25, 92: return 8  // 9
        case 29, 82: return 9  // 0
        default: return nil
        }
    }
}
