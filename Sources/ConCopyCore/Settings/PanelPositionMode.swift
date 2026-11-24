import Foundation

public enum PanelPositionMode: String, Codable, CaseIterable, Sendable {
    case nearMouse = "nearMouse"
    case nearCaret = "nearCaret"
    case centerScreen = "centerScreen"

    public var title: String {
        switch self {
        case .nearMouse: return "Near mouse cursor"
        case .nearCaret: return "Near text cursor (active caret)"
        case .centerScreen: return "Center of active screen"
        }
    }

    public var description: String {
        switch self {
        case .nearMouse:
            return "Opens the HUD panel adjacent to your mouse pointer."
        case .nearCaret:
            return "Opens the HUD panel adjacent to the active text typing caret, falling back to mouse cursor."
        case .centerScreen:
            return "Centers the HUD panel on the screen currently containing the mouse."
        }
    }
}
