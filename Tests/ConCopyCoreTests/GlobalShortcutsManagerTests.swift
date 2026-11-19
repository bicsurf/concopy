import AppKit
import XCTest
import KeyboardShortcuts
@testable import ConCopyUI

@MainActor
final class GlobalShortcutsManagerTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        GlobalShortcutsManager.shared.resetAll()
    }

    override func tearDown() async throws {
        GlobalShortcutsManager.shared.resetAll()
        try await super.tearDown()
    }

    func testAllShortcutKeysHaveDefaultsAndScopes() {
        for key in ConCopyShortcutKey.allCases {
            XCTAssertFalse(key.displayName.isEmpty)
            XCTAssertFalse(key.systemImage.isEmpty)
            XCTAssertNotNil(key.defaultShortcut, "\(key.rawValue) should have a default shortcut")
            XCTAssertNotNil(key.currentShortcut, "\(key.rawValue) should initially have currentShortcut set")
            XCTAssertTrue(key.isEnabled)
        }

        XCTAssertEqual(ConCopyShortcutKey.toggleConCopyPanel.scope, .global)
        XCTAssertEqual(ConCopyShortcutKey.moveToList.scope, .inPanel)
        XCTAssertEqual(ConCopyShortcutKey.copySelection.scope, .inPanel)
    }

    func testRemoveAndResetShortcut() {
        let manager = GlobalShortcutsManager.shared
        let key = ConCopyShortcutKey.moveToList

        XCTAssertNotNil(manager.shortcut(for: key))
        let initialVersion = manager.changeVersion

        // Remove shortcut
        manager.removeShortcut(for: key)
        XCTAssertNil(manager.shortcut(for: key))
        XCTAssertFalse(key.isEnabled)
        XCTAssertGreaterThan(manager.changeVersion, initialVersion)

        // Reset shortcut to default
        let prevVersion = manager.changeVersion
        manager.resetShortcut(for: key)
        XCTAssertNotNil(manager.shortcut(for: key))
        XCTAssertEqual(manager.shortcut(for: key), key.defaultShortcut)
        XCTAssertTrue(key.isEnabled)
        XCTAssertGreaterThan(manager.changeVersion, prevVersion)
    }

    func testResetAllRestoresDefaults() {
        let manager = GlobalShortcutsManager.shared

        // Remove several shortcuts
        manager.removeShortcut(for: .copySelection)
        manager.removeShortcut(for: .moveToList)

        XCTAssertNil(manager.shortcut(for: .copySelection))
        XCTAssertNil(manager.shortcut(for: .moveToList))

        // Reset all
        manager.resetAll()

        XCTAssertNotNil(manager.shortcut(for: .copySelection))
        XCTAssertNotNil(manager.shortcut(for: .moveToList))
        XCTAssertEqual(manager.shortcut(for: .moveToList), ConCopyShortcutKey.moveToList.defaultShortcut)
    }

    func testEventMatchingWhenEnabledAndDisabled() {
        let manager = GlobalShortcutsManager.shared

        // Cmd+M: Carbon keyCode for 'm' is 46, modifiers is Command
        guard let moveEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "m",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: 46
        ) else {
            XCTFail("Could not create mock NSEvent")
            return
        }

        // Initially moveToList default is Cmd+M, should match
        XCTAssertTrue(manager.matches(event: moveEvent, for: .moveToList))

        // When shortcut is removed, must not match
        manager.removeShortcut(for: .moveToList)
        XCTAssertFalse(manager.matches(event: moveEvent, for: .moveToList))

        // Reset restores match
        manager.resetShortcut(for: .moveToList)
        XCTAssertTrue(manager.matches(event: moveEvent, for: .moveToList))
    }

    func testCustomShortcutRemappingAndMatching() {
        let manager = GlobalShortcutsManager.shared

        // Default copySelection is Cmd+C (keyCode 8)
        guard let cmdCEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ), let customEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40 // 'k'
        ) else {
            XCTFail("Could not create mock NSEvents")
            return
        }

        // Initially Cmd+C matches
        XCTAssertTrue(manager.matches(event: cmdCEvent, for: .copySelection))
        XCTAssertFalse(manager.matches(event: customEvent, for: .copySelection))

        // Remap to Cmd+Shift+K
        let newShortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .shift])
        manager.setShortcut(newShortcut, for: .copySelection)

        // Now Cmd+C should NOT match, and Cmd+Shift+K SHOULD match
        XCTAssertFalse(manager.matches(event: cmdCEvent, for: .copySelection))
        XCTAssertTrue(manager.matches(event: customEvent, for: .copySelection))

        // Reset restores Cmd+C
        manager.resetShortcut(for: .copySelection)
        XCTAssertTrue(manager.matches(event: cmdCEvent, for: .copySelection))
        XCTAssertFalse(manager.matches(event: customEvent, for: .copySelection))
    }

    func testShortcutChangeNotificationUpdatesVersionAndDisablesCarbonHotKey() async throws {
        let manager = GlobalShortcutsManager.shared
        let initialVersion = manager.changeVersion

        // Simulate external change (as done by KeyboardShortcuts.Recorder)
        let newShortcut = KeyboardShortcuts.Shortcut(.j, modifiers: [.command])
        KeyboardShortcuts.setShortcut(newShortcut, for: ConCopyShortcutKey.toggleFavorite.shortcutName)

        // Wait brief runloop turn for async notification task
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertGreaterThan(manager.changeVersion, initialVersion)
        XCTAssertEqual(manager.shortcut(for: .toggleFavorite), newShortcut)

        // Verify matches immediately without restart
        guard let cmdJEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "j",
            charactersIgnoringModifiers: "j",
            isARepeat: false,
            keyCode: 38 // 'j'
        ) else {
            XCTFail("Failed to create mock key event")
            return
        }

        XCTAssertTrue(manager.matches(event: cmdJEvent, for: .toggleFavorite))
    }

    func testMatchesAllClipsCommandAndCommandOption() throws {
        let manager = GlobalShortcutsManager.shared
        let command = try keyEvent(code: 0, modifiers: [.command], characters: "a")
        let combined = try keyEvent(code: 0, modifiers: [.command, .option], characters: "å")

        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            XCTAssertTrue(manager.matchesAllClips(event: combined))
            XCTAssertEqual(manager.matchesAllClips(event: command), !swapped)
        }
    }

    func testNumericShortcutsUseHardwareKeysAcrossLayoutsAndNumpad() throws {
        let manager = GlobalShortcutsManager.shared
        let topRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        let numpad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]

        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            for keys in [topRow, numpad] {
                for (index, code) in keys.enumerated() {
                    // Neither character string contains a digit, as can happen with international layouts.
                    let command = try keyEvent(code: code, modifiers: [.command], characters: "&")
                    let combined = try keyEvent(code: code, modifiers: [.command, .option], characters: "~")
                    let paste = swapped ? command : combined
                    let list = swapped ? combined : command
                    XCTAssertEqual(manager.matchedQuickPasteIndex(for: paste), index)
                    XCTAssertEqual(manager.matchedListDigit(for: list), (index + 1) % 10)
                    XCTAssertNil(manager.matchedQuickPasteIndex(for: list))
                    XCTAssertNil(manager.matchedListDigit(for: paste))
                    XCTAssertFalse(manager.plainTextOverride(for: paste))
                }
            }
        }
    }

    func testOptionTextInputAndDeadKeysDoNotMatchNavigationOrQuickPaste() throws {
        let manager = GlobalShortcutsManager.shared
        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            for modifiers: NSEvent.ModifierFlags in [[.option], [.option, .shift]] {
                for code: UInt16 in [0, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 83, 84, 85, 86, 87, 88, 89, 91, 92, 82] {
                    for characters in ["~", "", "å"] {
                        let event = try keyEvent(code: code, modifiers: modifiers, characters: characters)
                        XCTAssertNil(manager.matchedQuickPasteIndex(for: event))
                        XCTAssertNil(manager.matchedListDigit(for: event))
                        XCTAssertFalse(manager.matchesAllClips(event: event))
                    }
                }
            }
        }
    }

    func testNumericShortcutsRejectShiftAndControl() throws {
        let manager = GlobalShortcutsManager.shared
        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            for modifiers: NSEvent.ModifierFlags in [
                [.command, .shift], [.command, .option, .shift],
                [.command, .control], [.command, .option, .control]
            ] {
                let event = try keyEvent(code: 18, modifiers: modifiers, characters: "1")
                XCTAssertNil(manager.matchedQuickPasteIndex(for: event))
                XCTAssertNil(manager.matchedListDigit(for: event))
            }
        }
    }

    func testNumericShortcutsRetainCharacterFallback() throws {
        let manager = GlobalShortcutsManager.shared
        // A key outside the hardware digit map must still work when the event contains a digit.
        let list = try keyEvent(code: 10, modifiers: [.command], characters: "5")
        let paste = try keyEvent(code: 10, modifiers: [.command, .option], characters: "5")
        XCTAssertEqual(manager.matchedListDigit(for: list), 5)
        XCTAssertEqual(manager.matchedQuickPasteIndex(for: paste), 4)
    }

    private func keyEvent(code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    func testSwapNumericModifiersSymbolsAndState() {
        let manager = GlobalShortcutsManager.shared

        manager.setSwapNumericModifiers(false)
        XCTAssertFalse(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌘")
        XCTAssertEqual(manager.quickPasteModifierSymbol, "⌘⌥")

        manager.setSwapNumericModifiers(true)
        XCTAssertTrue(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌘⌥")
        XCTAssertEqual(manager.quickPasteModifierSymbol, "⌘")

        manager.resetAll()
        XCTAssertFalse(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌘")
    }

    func testIsCharacterReservedForCommands() {
        let manager = GlobalShortcutsManager.shared

        // System reserved
        XCTAssertTrue(manager.isCharacterReservedForCommands("a"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("q"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("w"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("x"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("z"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("v"))

        // Default configured shortcuts (c = copy, d = favorite, m = move, f = search)
        XCTAssertTrue(manager.isCharacterReservedForCommands("c"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("d"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("m"))
        XCTAssertTrue(manager.isCharacterReservedForCommands("f"))

        // Unreserved letters
        XCTAssertFalse(manager.isCharacterReservedForCommands("b"))
        XCTAssertFalse(manager.isCharacterReservedForCommands("k"))
        XCTAssertFalse(manager.isCharacterReservedForCommands("l"))

        // Remap favorite from d to j
        let newShortcut = KeyboardShortcuts.Shortcut(.j, modifiers: [.command])
        manager.setShortcut(newShortcut, for: .toggleFavorite)

        XCTAssertTrue(manager.isCharacterReservedForCommands("j"))
        XCTAssertFalse(manager.isCharacterReservedForCommands("d"))

        // Reset restores defaults
        manager.resetShortcut(for: .toggleFavorite)
        XCTAssertTrue(manager.isCharacterReservedForCommands("d"))
        XCTAssertFalse(manager.isCharacterReservedForCommands("j"))
    }
}
