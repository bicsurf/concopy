import Foundation

public struct URLMetadata: Sendable, Equatable {
    public let title: String?
    public let faviconURL: URL?

    public init(title: String? = nil, faviconURL: URL? = nil) {
        self.title = title
        self.faviconURL = faviconURL
    }
}

public struct LinkMetadataFetcher: Sendable {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchMetadata(for url: URL, timeout: TimeInterval = 4.0) async -> URLMetadata {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return URLMetadata()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return URLMetadata(title: nil, faviconURL: defaultFaviconURL(for: url))
            }

            // Inspect the first 64KB where <head> resides
            let maxBytes = min(data.count, 65536)
            let headData = data.prefix(maxBytes)
            let htmlString = String(decoding: headData, as: UTF8.self)

            let title = extractTitle(from: htmlString)
            let favicon = extractFavicon(from: htmlString, baseURL: url) ?? defaultFaviconURL(for: url)

            return URLMetadata(title: title, faviconURL: favicon)
        } catch {
            return URLMetadata(title: nil, faviconURL: defaultFaviconURL(for: url))
        }
    }

    public func fetchAndUpdateMetadata(
        clipId: UUID,
        url: URL,
        databaseManager: DatabaseManager
    ) async {
        let meta = await fetchMetadata(for: url)
        guard let title = meta.title, !title.isEmpty else { return }

        do {
            if let clip = try databaseManager.fetchClip(id: clipId), clip.customName == nil {
                try databaseManager.updateCustomName(clipId: clipId, name: title)
            }
        } catch {
            print("[ConCopy] Failed to update clip with URL metadata: \(error)")
        }
    }

    public func extractTitle(from html: String) -> String? {
        let pattern = "(?i)<title[^>]*>(.*?)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let rawTitle = String(html[titleRange])
        let cleaned = decodeHTMLEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    public func extractFavicon(from html: String, baseURL: URL) -> URL? {
        let pattern = "(?i)<link[^>]+rel=[\"']?(?:shortcut )?icon[\"']?[^>]+href=[\"']?([^\"'>\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let hrefRange = Range(match.range(at: 1), in: html) {
            let href = String(html[hrefRange])
            if let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                return resolved
            }
        }

        return nil
    }

    private func defaultFaviconURL(for url: URL) -> URL? {
        guard let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = host
        components.path = "/favicon.ico"
        return components.url
    }

    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        return result
    }
}
