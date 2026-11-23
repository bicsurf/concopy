import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

final class UpdateDownloaderTests: XCTestCase {
    func testDiskImageValidationRejectsTruncationAndInvalidTrailer() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(repeating: 0, count: 1024)
        try data.write(to: file)
        XCTAssertThrowsError(try UpdateDownloader.validateDiskImage(at: file, expectedLength: 1024))
        data.replaceSubrange(512..<516, with: Data("koly".utf8))
        try data.write(to: file)
        XCTAssertNoThrow(try UpdateDownloader.validateDiskImage(at: file, expectedLength: 1024))
        XCTAssertNoThrow(try UpdateDownloader.validateDiskImage(at: file, expectedLength: -1))
        XCTAssertThrowsError(try UpdateDownloader.validateDiskImage(at: file, expectedLength: 2048))
        try Data(repeating: 0, count: 100).write(to: file)
        XCTAssertThrowsError(try UpdateDownloader.validateDiskImage(at: file, expectedLength: -1))
    }

    func testDownloadRejectsInsecureURL() async throws {
        let url = try XCTUnwrap(URL(string: "http://example.com/update.dmg"))
        do {
            _ = try await UpdateDownloader().download(from: url) { _, _ in }
            XCTFail("Expected rejection before downloading")
        } catch UpdateDownloader.DownloadError.invalidResponse {
            // The transport must require HTTPS.
        }
    }

    @MainActor
    func testAutomaticChecksRespectDailyIntervalAndLaunchOverride() async throws {
        let suite = "UpdateSchedule-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsManager(userDefaults: defaults)
        settings.isAutoCheckUpdatesEnabled = true
        let recent = Date().addingTimeInterval(-60)
        settings.lastUpdateCheckDate = recent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MockUpdateURLProtocol.mockStatusCode = 404
        MockUpdateURLProtocol.mockResponseData = nil
        let checker = UpdateChecker(appSettings: settings, session: session)
        await checker.checkAutomaticallyIfNeeded()
        XCTAssertEqual(settings.lastUpdateCheckDate, recent)
        await checker.checkAutomaticallyIfNeeded(force: true)
        XCTAssertGreaterThan(try XCTUnwrap(settings.lastUpdateCheckDate), recent)
        let expired = Date().addingTimeInterval(-25 * 3600)
        settings.lastUpdateCheckDate = expired
        await checker.checkAutomaticallyIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(settings.lastUpdateCheckDate), expired)
        settings.isAutoCheckUpdatesEnabled = false
        settings.lastUpdateCheckDate = recent
        await checker.checkAutomaticallyIfNeeded(force: true)
        XCTAssertEqual(settings.lastUpdateCheckDate, recent)
    }
}
