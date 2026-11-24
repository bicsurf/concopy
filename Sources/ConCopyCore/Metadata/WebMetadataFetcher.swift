import Foundation

public struct WebLinkMetadata: Sendable, Equatable {
    public let url: URL
    public let title: String?
    public let faviconURL: URL?

    public init(url: URL, title: String? = nil, faviconURL: URL? = nil) {
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
    }
}

public actor WebMetadataFetcher {
    public static let shared = WebMetadataFetcher()

    private var cache: [URL: WebLinkMetadata] = [:]
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchMetadata(for urlString: String) async -> WebLinkMetadata? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        if let cached = cache[url] {
            return cached
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.5
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            // Only parse if HTML content
            let mimeType = httpResponse.mimeType?.lowercased() ?? ""
            guard mimeType.contains("text/html") || mimeType.contains("xhtml") || mimeType.isEmpty else {
                return nil
            }

            // Read at most first 64KB for title & favicon
            let prefixData = data.prefix(65536)
            let html = String(decoding: prefixData, as: UTF8.self)

            let title = extractTitle(from: html)
            let favicon = extractFaviconURL(from: html, baseURL: url)

            let meta = WebLinkMetadata(url: url, title: title, faviconURL: favicon)
            cache[url] = meta
            return meta
        } catch {
            return nil
        }
    }

    public func extractTitle(from html: String) -> String? {
        let pattern = #"(?i)<title[^>]*>([^<]+)</title>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsHtml = html as NSString
        guard let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        let rawTitle = nsHtml.substring(with: match.range(at: 1))
        let cleaned = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    public func extractFaviconURL(from html: String, baseURL: URL) -> URL? {
        let pattern = #"(?i)<link[^>]+rel=["']?(?:shortcut )?icon["']?[^>]+href=["']?([^"'>\s]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsHtml = html as NSString
            if let match = regex.firstMatch(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length)),
               match.numberOfRanges > 1 {
                let href = nsHtml.substring(with: match.range(at: 1))
                if let favURL = URL(string: href, relativeTo: baseURL) {
                    return favURL.absoluteURL
                }
            }
        }
        // Fallback standard /favicon.ico
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/favicon.ico"
        components?.query = nil
        return components?.url
    }
}
