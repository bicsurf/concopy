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
    func testA33MetadataCancelsAt64KiB() async throws {
        AuditNetworkProtocol.reset(html: true)
        let session = session()
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "https://audit.example.test/large"))
        let metadata = await LinkMetadataFetcher(session: session).fetchMetadata(for: url)
        XCTAssertEqual(metadata.title, "Bounded response")
        for _ in 0..<30 {
            if AuditNetworkProtocol.stopCount > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(AuditNetworkProtocol.stopCount, 0)
        XCTAssertEqual(AuditNetworkProtocol.extraChunksSent, 0, "Cancel before the rest of the response is transferred")
    }
    func testA36AutomaticChecksRepeatAndStopWhenDisabled() async throws {
        AuditNetworkProtocol.reset(html: false)
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
    private static var html = true
    private static var requests = 0
    private static var stops = 0
    private static var extra = 0
    private let instanceLock = NSLock()
    private var stopped = false
    static var requestCount: Int { lock.withLock { requests } }
    static var stopCount: Int { lock.withLock { stops } }
    static var extraChunksSent: Int { lock.withLock { extra } }
    static func reset(html: Bool) {
        lock.withLock {
            self.html = html
            requests = 0
            stops = 0
            extra = 0
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let isHTML = Self.lock.withLock {
            Self.requests += 1
            return Self.html
        }
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": isHTML ? "text/html" : "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isHTML {
            let title = Data("<html><head><title>Bounded response</title></head>".utf8)
            client?.urlProtocol(self, didLoad: title + Data(repeating: 32, count: 65536 - title.count))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                guard !instanceLock.withLock({ stopped }) else { return }
                Self.lock.withLock { Self.extra += 1 }
                client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 65536))
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            let json = "{\"tag_name\":\"v1.0.0\",\"html_url\":\"https://audit.example.test/release\",\"assets\":[]}"
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        instanceLock.withLock { stopped = true }
        Self.lock.withLock { Self.stops += 1 }
    }
}
