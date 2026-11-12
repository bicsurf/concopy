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

    func testMatchedListDigitCommandAndOption() {
        let manager = GlobalShortcutsManager.shared

        // Cmd+1 (keyCode 18)
        guard let cmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ), let opt1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "¡",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ) else {
            XCTFail("Could not create mock NSEvents")
            return
        }

        // Default: Cmd+1 matches digit 1, Opt+1 returns nil
        manager.setSwapNumericModifiers(false)
        XCTAssertEqual(manager.matchedListDigit(for: cmd1Event), 1)
        XCTAssertNil(manager.matchedListDigit(for: opt1Event))

        // Inverted: Opt+1 matches digit 1, Cmd+1 returns nil
        manager.setSwapNumericModifiers(true)
        XCTAssertEqual(manager.matchedListDigit(for: opt1Event), 1)
        XCTAssertNil(manager.matchedListDigit(for: cmd1Event))
    }

    func testMatchedQuickPasteIndexCommandAndOption() {
        let manager = GlobalShortcutsManager.shared

        guard let cmd1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ), let opt1Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "¡",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ), let opt0Event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "º",
            charactersIgnoringModifiers: "0",
            isARepeat: false,
            keyCode: 29
        ) else {
            XCTFail("Could not create mock NSEvents")
            return
        }

        // Default: Opt+1 matches index 0, Opt+0 matches index 9, Cmd+1 returns nil
        manager.setSwapNumericModifiers(false)
        XCTAssertEqual(manager.matchedQuickPasteIndex(for: opt1Event), 0)
        XCTAssertEqual(manager.matchedQuickPasteIndex(for: opt0Event), 9)
        XCTAssertNil(manager.matchedQuickPasteIndex(for: cmd1Event))

        // Inverted: Cmd+1 matches index 0, Opt+1 returns nil
        manager.setSwapNumericModifiers(true)
        XCTAssertEqual(manager.matchedQuickPasteIndex(for: cmd1Event), 0)
        XCTAssertNil(manager.matchedQuickPasteIndex(for: opt1Event))
    }

    func testSwapNumericModifiersSymbolsAndState() {
        let manager = GlobalShortcutsManager.shared

        manager.setSwapNumericModifiers(false)
        XCTAssertFalse(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌘")
        XCTAssertEqual(manager.quickPasteModifierSymbol, "⌥")
        XCTAssertEqual(manager.quickPasteModifierSystemImage, "option")

        manager.setSwapNumericModifiers(true)
        XCTAssertTrue(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌥")
        XCTAssertEqual(manager.quickPasteModifierSymbol, "⌘")
        XCTAssertEqual(manager.quickPasteModifierSystemImage, "command")

        manager.resetAll()
        XCTAssertFalse(manager.swapNumericModifiers)
        XCTAssertEqual(manager.listModifierSymbol, "⌘")
    }
}
