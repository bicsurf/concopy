import Foundation

public enum ClipTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case images
    case links
    case files
    case colors

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        case .links: return "Links"
        case .files: return "Files"
        case .colors: return "Colors"
        }
    }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "doc.text"
        case .images: return "photo"
        case .links: return "link"
        case .files: return "folder"
        case .colors: return "paintpalette"
        }
    }

    public var matchingPrimaryTypes: [ClipPrimaryType]? {
        switch self {
        case .all:
            return nil
        case .text:
            return [.text, .richText, .html]
        case .images:
            return [.image]
        case .links:
            return [.url]
        case .files:
            return [.file]
        case .colors:
            return [.color]
        }
    }
}
