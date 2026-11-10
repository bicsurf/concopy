import Foundation

public enum ClipPrimaryType: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case html
    case image
    case file
    case url
    case color
}
