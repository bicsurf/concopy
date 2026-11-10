import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    public static let toggleConCopyPanel = Self(
        "toggleConCopyPanel",
        default: .init(.v, modifiers: [.command, .shift])
    )
}
