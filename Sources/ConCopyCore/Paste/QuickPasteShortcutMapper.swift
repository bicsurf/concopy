import Foundation

public enum QuickPasteShortcutMapper {
    public static func label(forIndex index: Int) -> String? {
        switch index {
        case 0...9:
            return String(index)
        case 10...35:
            let asciiA = Character("a").asciiValue ?? 97
            let scalar = UnicodeScalar(asciiA + UInt8(index - 10))
            return String(Character(scalar))
        default:
            return nil
        }
    }

    public static func index(forCharacter char: String) -> Int? {
        guard char.count == 1, let character = char.lowercased().first else {
            return nil
        }

        if let digit = character.wholeNumberValue, digit >= 0 && digit <= 9 {
            return digit
        }

        if let ascii = character.asciiValue, ascii >= 97 && ascii <= 122 {
            return Int(ascii - 97) + 10
        }

        return nil
    }
}
