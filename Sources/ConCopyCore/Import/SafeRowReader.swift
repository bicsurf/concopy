import Foundation
import GRDB

internal enum SafeRowReader {
    static func string(from row: Row, column: String) -> String? {
        guard let dbValue = row[column]?.databaseValue else { return nil }
        switch dbValue.storage {
        case .string(let str):
            return str
        case .blob(let data):
            return String(data: data, encoding: .utf8)
        case .int64(let int):
            return String(int)
        case .double(let dbl):
            return String(dbl)
        case .null:
            return nil
        }
    }

    static func int64(from row: Row, column: String) -> Int64? {
        guard let dbValue = row[column]?.databaseValue else { return nil }
        switch dbValue.storage {
        case .int64(let val):
            return val
        case .double(let val):
            return Int64(val)
        case .string(let val):
            return Int64(val.trimmingCharacters(in: .whitespacesAndNewlines))
        case .blob, .null:
            return nil
        }
    }

    static func double(from row: Row, column: String) -> Double? {
        guard let dbValue = row[column]?.databaseValue else { return nil }
        switch dbValue.storage {
        case .double(let val):
            return val
        case .int64(let val):
            return Double(val)
        case .string(let val):
            return Double(val.trimmingCharacters(in: .whitespacesAndNewlines))
        case .blob, .null:
            return nil
        }
    }

    static func bool(from row: Row, column: String) -> Bool? {
        guard let dbValue = row[column]?.databaseValue else { return nil }
        switch dbValue.storage {
        case .int64(let val):
            return val != 0
        case .double(let val):
            return val != 0
        case .string(let val):
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "1" || trimmed == "true" || trimmed == "yes" { return true }
            if trimmed == "0" || trimmed == "false" || trimmed == "no" || trimmed.isEmpty { return false }
            return !trimmed.isEmpty
        case .blob, .null:
            return nil
        }
    }

    static func data(from row: Row, column: String) -> Data? {
        guard let dbValue = row[column]?.databaseValue else { return nil }
        switch dbValue.storage {
        case .blob(let data):
            return data
        case .string(let str):
            return Data(str.utf8)
        case .int64, .double, .null:
            return nil
        }
    }

    static func databaseValue(from row: Row, column: String) -> DatabaseValue? {
        row[column]?.databaseValue
    }
}
