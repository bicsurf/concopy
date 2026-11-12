import AppKit
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
}

public enum ShortcutScope: String, Sendable {
    case global = "Globale"
    case inPanel = "Nel Pannello"
}

public enum ConCopyShortcutKey: String, CaseIterable, Identifiable, Sendable {
    case toggleConCopyPanel = "toggleConCopyPanel"
    case pasteSelection = "pasteSelection"
    case copySelection = "copySelection"
    case moveToList = "moveToList"
    case toggleFavorite = "toggleFavorite"
    case focusSearch = "focusSearch"
    case openPreferences = "openPreferences"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .toggleConCopyPanel:
            return "Apri / Chiudi ConCopy"
        case .pasteSelection:
            return "Incolla elemento selezionato"
        case .copySelection:
            return "Copia elemento negli appunti"
        case .moveToList:
            return "Sposta nella Lista / Snippet"
        case .toggleFavorite:
            return "Aggiungi / Rimuovi dai Preferiti"
        case .focusSearch:
            return "Focalizza campo di ricerca"
        case .openPreferences:
            return "Apri Impostazioni"
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
        }
    }

    public var scope: ShortcutScope {
        switch self {
        case .toggleConCopyPanel:
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
    public static let shared = GlobalShortcutsManager()
    public static let swapNumericModifiersKey = "ConCopy.Shortcuts.swapNumericModifiers"

    @Published public private(set) var swapNumericModifiers: Bool = false
    @Published public private(set) var changeVersion: Int = 0

    public var listModifierSymbol: String {
        swapNumericModifiers ? "⌥" : "⌘"
    }

    public var quickPasteModifierSymbol: String {
        swapNumericModifiers ? "⌘" : "⌥"
    }

    public var quickPasteModifierSystemImage: String {
        swapNumericModifiers ? "command" : "option"
    }

    public init() {
        self.swapNumericModifiers = UserDefaults.standard.bool(forKey: Self.swapNumericModifiersKey)
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
        changeVersion &+= 1
    }

    public func removeShortcut(for key: ConCopyShortcutKey) {
        KeyboardShortcuts.setShortcut(nil, for: key.shortcutName)
        changeVersion &+= 1
    }

    public func resetShortcut(for key: ConCopyShortcutKey) {
        KeyboardShortcuts.reset(key.shortcutName)
        changeVersion &+= 1
    }

    public func resetAll() {
        self.swapNumericModifiers = false
        UserDefaults.standard.set(false, forKey: Self.swapNumericModifiersKey)
        for key in ConCopyShortcutKey.allCases {
            KeyboardShortcuts.reset(key.shortcutName)
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

        // Exact match
        if eventShortcut == target {
            return true
        }

        // Support Numpad Enter (76) when Return (36) is registered
        if target.carbonKeyCode == 36 && (event.keyCode == 36 || event.keyCode == 76) && eventShortcut.modifiers == target.modifiers {
            return true
        }

        return false
    }

    /// Resolves list digit 1..9 from the given keyboard event according to the current modifier configuration.
    public func matchedListDigit(for event: NSEvent) -> Int? {
        let isOptionRequired = swapNumericModifiers
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if isOptionRequired {
            guard flags.contains(.option),
                  !flags.contains(.command),
                  !flags.contains(.control) else {
                return nil
            }
        } else {
            guard flags.contains(.command),
                  !flags.contains(.option),
                  !flags.contains(.control) else {
                return nil
            }
        }

        if let idx = digitIndex(forKeyCode: event.keyCode), idx >= 0 && idx <= 8 {
            return idx + 1
        }

        if let char = event.charactersIgnoringModifiers?.first,
           let d = char.wholeNumberValue, d >= 1 && d <= 9 {
            return d
        }

        return nil
    }

    /// Resolves quick paste item index 0..9 from the given keyboard event according to the current modifier configuration.
    public func matchedQuickPasteIndex(for event: NSEvent) -> Int? {
        let isCommandRequired = swapNumericModifiers
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if isCommandRequired {
            guard flags.contains(.command),
                  !flags.contains(.shift),
                  !flags.contains(.control) else {
                return nil
            }
        } else {
            guard flags.contains(.option),
                  !flags.contains(.command),
                  !flags.contains(.control) else {
                return nil
            }
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

    private func digitIndex(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18, 83: return 0 // 1
        case 19, 84: return 1 // 2
        case 20, 85: return 2 // 3
        case 21, 86: return 3 // 4
        case 23, 87: return 4 // 5
        case 22, 88: return 5 // 6
        case 26, 89: return 6 // 7
        case 28, 91: return 7 // 8
        case 25, 92: return 8 // 9
        case 29, 82: return 9 // 0
        default: return nil
        }
    }
}
