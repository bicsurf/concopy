import Foundation

public enum QuickPasteShortcutMapper {
    public static func label(forIndex index: Int) -> String? {
        switch index {
        case 0...8:
            return String(index + 1)
        case 9:
            return "0"
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

        if let digit = character.wholeNumberValue {
            if digit >= 1 && digit <= 9 {
                return digit - 1
            } else if digit == 0 {
                return 9
            }
        }

        if let ascii = character.asciiValue, ascii >= 97 && ascii <= 122 {
            return Int(ascii - 97) + 10
        }

        return nil
    }
}
