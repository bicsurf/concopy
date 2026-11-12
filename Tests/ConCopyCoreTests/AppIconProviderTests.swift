import AppKit
import XCTest
@testable import ConCopyUI

@MainActor
final class AppIconProviderTests: XCTestCase {
    func testAppIconProviderResolvesFinderIcon() {
        let provider = AppIconProvider.shared
        let icon = provider.icon(for: "com.apple.Finder")
        XCTAssertNotNil(icon)
        XCTAssertTrue(icon?.isValid == true)

        let iconLower = provider.icon(for: "com.apple.finder")
        XCTAssertNotNil(iconLower)
        XCTAssertTrue(iconLower?.isValid == true)
    }

    func testAppIconProviderReturnsNilForInvalidBundleId() {
        let provider = AppIconProvider.shared
        let icon = provider.icon(for: "com.invalid.nonexistent.app.bundle.id")
        XCTAssertNil(icon)

        // Verify second lookup uses missing cache and still returns nil
        let iconAgain = provider.icon(for: "com.invalid.nonexistent.app.bundle.id")
        XCTAssertNil(iconAgain)
    }

    func testAppIconProviderHandlesNilAndEmpty() {
        let provider = AppIconProvider.shared
        XCTAssertNil(provider.icon(for: nil))
        XCTAssertNil(provider.icon(for: ""))
        XCTAssertNil(provider.icon(for: "   "))
    }
}
