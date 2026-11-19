import Foundation
import XCTest

@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class AuditNetworkTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditNetworkProtocol.self]
        return URLSession(configuration: config)
    }
    func testA36AutomaticChecksRepeatAndStopWhenDisabled() async throws {
        AuditNetworkProtocol.reset()
        let session = session()
        defer { session.invalidateAndCancel() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ConCopy.UpdateAudit.\(UUID())"))
        let settings = AppSettingsManager(userDefaults: defaults)
        settings.isAutoCheckUpdatesEnabled = true
        let checker = UpdateChecker(
            appSettings: settings, session: session,
            endpoint: try XCTUnwrap(URL(string: "https://audit.example.test/release")),
            automaticCheckInterval: 0.05, currentVersionProvider: { "1.0.0" })
        checker.startAutomaticChecks()
        defer { checker.stopAutomaticChecks() }
        for _ in 0..<100 {
            if AuditNetworkProtocol.requestCount >= 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(AuditNetworkProtocol.requestCount, 2)
        settings.isAutoCheckUpdatesEnabled = false
        try await Task.sleep(nanoseconds: 100_000_000)
        let stoppedCount = AuditNetworkProtocol.requestCount
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(AuditNetworkProtocol.requestCount, stoppedCount)
    }
}

private final class AuditNetworkProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    static var requestCount: Int { lock.withLock { requests } }
    static func reset() {
        lock.withLock { requests = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let json = "{\"tag_name\":\"v1.0.0\",\"html_url\":\"https://audit.example.test/release\",\"assets\":[]}"
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
    }
}
