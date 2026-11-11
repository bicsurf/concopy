import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

final class UpdateCheckerTests: XCTestCase {
    // MARK: - SemanticVersion Tests
    func testSemanticVersionComparison() {
        // Basic patch comparison
        XCTAssertTrue(SemanticVersion("1.0.1") > SemanticVersion("1.0.0"))
        XCTAssertFalse(SemanticVersion("1.0.0") > SemanticVersion("1.0.1"))
        XCTAssertTrue(SemanticVersion("1.0.0") < SemanticVersion("1.0.1"))

        // Minor comparison with two-digit version
        XCTAssertTrue(SemanticVersion("1.10.0") > SemanticVersion("1.2.0"))
        XCTAssertFalse(SemanticVersion("1.2.0") > SemanticVersion("1.10.0"))

        // Leading 'v' and 'V' prefix handling
        XCTAssertTrue(SemanticVersion("v1.0.1") > SemanticVersion("1.0.0"))
        XCTAssertTrue(SemanticVersion("V1.0.1") > SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("v1.0.0"), SemanticVersion("1.0.0"))
        XCTAssertEqual(SemanticVersion("V2.3.4"), SemanticVersion("2.3.4"))

        // Major version jumps
        XCTAssertTrue(SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))

        // Two-part version vs three-part version
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion("1.2.0"))
        XCTAssertTrue(SemanticVersion("1.2.1") > SemanticVersion("1.2"))

        // Pre-release tags stripped
        XCTAssertEqual(SemanticVersion("v1.2.3-beta1"), SemanticVersion("1.2.3"))
        XCTAssertEqual(SemanticVersion("1.2.3-rc.1"), SemanticVersion("1.2.3"))
    }

    // MARK: - Release Model JSON Decoding
    func testGitHubReleaseDecoding() throws {
        let json = """
        {
            "tag_name": "v1.2.0",
            "name": "ConCopy 1.2.0",
            "body": "Novità:\\n- Testo di prova",
            "html_url": "https://github.com/bicsurf/concopy/releases/tag/v1.2.0",
            "assets": [
                {
                    "name": "ConCopy-1.2.0.dmg",
                    "browser_download_url": "https://github.com/bicsurf/concopy/releases/download/v1.2.0/ConCopy-1.2.0.dmg"
                },
                {
                    "name": "checksums.txt",
                    "browser_download_url": "https://github.com/bicsurf/concopy/releases/download/v1.2.0/checksums.txt"
                }
            ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.name, "ConCopy 1.2.0")
        XCTAssertEqual(release.assets.count, 2)
        XCTAssertEqual(release.assets[0].name, "ConCopy-1.2.0.dmg")
    }

    // MARK: - Throttling & Skip Version Logic
    @MainActor
    func testThrottlingAndSkipVersion() {
        let defaultsName = "TestDefaults_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsName)!
        let settings = AppSettingsManager(userDefaults: testDefaults)

        // Default setting
        XCTAssertTrue(settings.isAutoCheckUpdatesEnabled)
        XCTAssertNil(settings.lastUpdateCheckDate)
        XCTAssertNil(settings.skippedUpdateVersion)

        // Toggle auto-check
        settings.isAutoCheckUpdatesEnabled = false
        XCTAssertFalse(testDefaults.bool(forKey: AppSettingsManager.isAutoCheckUpdatesEnabledKey))

        // Set skip version
        settings.skippedUpdateVersion = "1.5.0"
        XCTAssertEqual(testDefaults.string(forKey: AppSettingsManager.skippedUpdateVersionKey), "1.5.0")

        // Set last check date
        let now = Date()
        settings.lastUpdateCheckDate = now
        XCTAssertNotNil(testDefaults.object(forKey: AppSettingsManager.lastUpdateCheckDateKey))

        testDefaults.removePersistentDomain(forName: defaultsName)
    }

    // MARK: - UpdateChecker with Mock URLProtocol
    @MainActor
    func testUpdateCheckerAvailableUpdateDetection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let mockJSON = """
        {
            "tag_name": "v2.0.0",
            "name": "ConCopy 2.0.0",
            "body": "Major release",
            "html_url": "https://github.com/bicsurf/concopy/releases/tag/v2.0.0",
            "assets": [
                {
                    "name": "ConCopy.dmg",
                    "browser_download_url": "https://example.com/ConCopy.dmg"
                }
            ]
        }
        """.data(using: .utf8)!

        MockUpdateURLProtocol.mockResponseData = mockJSON
        MockUpdateURLProtocol.mockStatusCode = 200

        let defaultsName = "TestDefaults_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsName)!
        let settings = AppSettingsManager(userDefaults: testDefaults)

        let checker = UpdateChecker(
            appSettings: settings,
            session: mockSession,
            currentVersionProvider: { "1.0.0" }
        )

        let result = await checker.checkForUpdates(isUserInitiated: true)
        if case .updateAvailable(let update) = result {
            XCTAssertEqual(update.version, "2.0.0")
            XCTAssertEqual(update.dmgDownloadURL?.absoluteString, "https://example.com/ConCopy.dmg")
            XCTAssertEqual(checker.availableUpdate?.version, "2.0.0")
        } else {
            XCTFail("Expected updateAvailable, got \(result)")
        }

        // Test skip update
        checker.skipUpdate(version: "2.0.0")
        XCTAssertNil(checker.availableUpdate)
        XCTAssertEqual(settings.skippedUpdateVersion, "2.0.0")

        testDefaults.removePersistentDomain(forName: defaultsName)
    }

    @MainActor
    func testUpdateCheckerWhenAlreadyUpToDate() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let mockSession = URLSession(configuration: configuration)

        let mockJSON = """
        {
            "tag_name": "v1.0.0",
            "name": "ConCopy 1.0.0",
            "body": "Initial release",
            "html_url": "https://github.com/bicsurf/concopy/releases/tag/v1.0.0",
            "assets": []
        }
        """.data(using: .utf8)!

        MockUpdateURLProtocol.mockResponseData = mockJSON
        MockUpdateURLProtocol.mockStatusCode = 200

        let defaultsName = "TestDefaults_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: defaultsName)!
        let settings = AppSettingsManager(userDefaults: testDefaults)

        let checker = UpdateChecker(
            appSettings: settings,
            session: mockSession,
            currentVersionProvider: { "1.0.0" }
        )

        let result = await checker.checkForUpdates(isUserInitiated: true)
        if case .upToDate = result {
            XCTAssertNil(checker.availableUpdate)
        } else {
            XCTFail("Expected upToDate, got \(result)")
        }

        testDefaults.removePersistentDomain(forName: defaultsName)
    }
}

// MARK: - Mock URL Protocol
final class MockUpdateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mockResponseData: Data?
    nonisolated(unsafe) static var mockStatusCode: Int = 200

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.github.com")!,
            statusCode: Self.mockStatusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let data = Self.mockResponseData {
            client?.urlProtocol(self, didLoad: data)
        }

        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
