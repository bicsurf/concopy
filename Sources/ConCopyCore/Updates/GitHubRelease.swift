import Foundation

public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlUrl: String
    public let assets: [GitHubAsset]

    public init(
        tagName: String,
        name: String? = nil,
        body: String? = nil,
        htmlUrl: String,
        assets: [GitHubAsset] = []
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlUrl = htmlUrl
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case assets
    }
}

public struct GitHubAsset: Codable, Sendable {
    public let name: String
    public let browserDownloadUrl: String

    public init(name: String, browserDownloadUrl: String) {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let title: String
    public let releaseNotes: String
    public let releasePageURL: URL
    public let dmgDownloadURL: URL?

    public init(
        version: String,
        title: String,
        releaseNotes: String,
        releasePageURL: URL,
        dmgDownloadURL: URL? = nil
    ) {
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.releasePageURL = releasePageURL
        self.dmgDownloadURL = dmgDownloadURL
    }
}
