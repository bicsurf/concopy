import Foundation

/// Private multi-item representation; public.file-url remains available for older archives.
public enum FileURLRepresentation {
    public static let multipleURLsUTI = "com.local.ConCopy.file-urls"

    public static func urls(in representations: [String: Data]) -> [URL] {
        if let data = representations[multipleURLsUTI],
            let urls = try? JSONDecoder().decode([URL].self, from: data),
            !urls.isEmpty, urls.allSatisfy(\.isFileURL)
        {
            return urls
        }
        guard let data = representations["public.file-url"],
            let string = String(data: data, encoding: .utf8),
            let url = URL(string: string), url.isFileURL
        else { return [] }
        return [url]
    }
}
