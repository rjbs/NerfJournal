import Foundation
import SwiftUI
import GRDB

enum CategoryColor: String, CaseIterable, Codable, DatabaseValueConvertible {
    case blue, red, green, orange, purple, pink, teal, yellow

    var databaseValue: DatabaseValue { rawValue.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CategoryColor? {
        guard let s = String.fromDatabaseValue(dbValue) else { return nil }
        return CategoryColor(rawValue: s)
    }

    var swatch: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        case .green:  return .green
        case .orange: return .orange
        case .purple: return .purple
        case .pink:   return .pink
        case .teal:   return .teal
        case .yellow: return .yellow
        }
    }
}

struct Category: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var color: CategoryColor
    var sortOrder: Int

    static let databaseTableName = "category"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// NOTE: Named TaskBundle rather than Bundle to avoid shadowing Foundation.Bundle.
struct TaskBundle: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int
    var todosShouldMigrate: Bool

    static let databaseTableName = "taskBundle"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct BundleTodo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var bundleID: Int64
    var title: String
    var sortOrder: Int
    var externalURL: String?
    var categoryID: Int64?

    static let databaseTableName = "bundleTodo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct JournalPage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var date: Date

    static let databaseTableName = "journalPage"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Completion or abandonment record. Stored as a JSON string in SQLite
// (via DatabaseValueConvertible); encoded as a nested object in export JSON
// (via Codable). These are distinct code paths with no conflict.
struct TodoEnding: Codable, DatabaseValueConvertible {
    enum Kind: String, Codable { case done, abandoned }
    var date: Date
    var kind: Kind

    var databaseValue: DatabaseValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try! enc.encode(self)
        return String(data: data, encoding: .utf8)!.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TodoEnding? {
        guard let s = String.fromDatabaseValue(dbValue),
              let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TodoEnding.self, from: d)
    }
}

// A todo spans journal pages naturally: it is visible on any day from its
// `start` date until the day it ends. No per-page duplication; "migration"
// is an emergent display property, not a status value.
struct Todo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var title: String
    var shouldMigrate: Bool
    var start: Date     // start-of-day timestamp for the first day the todo appears
    var ending: TodoEnding?
    var categoryID: Int64?
    var externalURL: String?

    static let databaseTableName = "todo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var isPending:   Bool { ending == nil }
    var isDone:      Bool { ending?.kind == .done }
    var isAbandoned: Bool { ending?.kind == .abandoned }
}

extension Todo {
    // Custom coding in an extension so the memberwise init is still synthesized.
    // Decodes `start` first; falls back to `added` so JSON exported before the
    // column rename still imports correctly. Encodes only `start`.
    // -- claude, 2026-03-03
    private enum CodingKeys: String, CodingKey {
        case id, title, shouldMigrate, start, added, ending, categoryID, externalURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(Int64.self,      forKey: .id)
        title         = try c.decode(String.self,              forKey: .title)
        shouldMigrate = try c.decode(Bool.self,                forKey: .shouldMigrate)
        if let s = try c.decodeIfPresent(Date.self, forKey: .start) {
            start = s
        } else {
            start = try c.decode(Date.self,                    forKey: .added)
        }
        ending        = try c.decodeIfPresent(TodoEnding.self, forKey: .ending)
        categoryID    = try c.decodeIfPresent(Int64.self,      forKey: .categoryID)
        externalURL   = try c.decodeIfPresent(String.self,     forKey: .externalURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,           forKey: .id)
        try c.encode(title,                 forKey: .title)
        try c.encode(shouldMigrate,         forKey: .shouldMigrate)
        try c.encode(start,                 forKey: .start)
        try c.encodeIfPresent(ending,       forKey: .ending)
        try c.encodeIfPresent(categoryID,   forKey: .categoryID)
        try c.encodeIfPresent(externalURL,  forKey: .externalURL)
    }
}

struct Note: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var pageID: Int64
    var timestamp: Date
    var text: String?

    static let databaseTableName = "note"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ExportGroup: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int

    static let databaseTableName = "exportGroup"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Junction record linking an ExportGroup to a category it contains.
// categoryID == nil represents the "Other" bucket (uncategorized todos).
struct ExportGroupMember: Codable, FetchableRecord, TableRecord {
    var groupID: Int64
    var categoryID: Int64?

    static let databaseTableName = "exportGroupMember"
}

extension [Todo] {
    // Sort by insertion order (id); cross-category ordering is done in the view
    // using category.sortOrder.
    func sortedForDisplay() -> [Todo] {
        sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }
}

// Groups `items` by category, sorting named groups by `category.sortOrder`.
// Items whose categoryID is nil or no longer matches a known category collect
// into an "Other" group appended at the end. -- claude, 2026-03-02
func groupedByCategory<Item>(
    _ items: [Item],
    categoryID keyPath: KeyPath<Item, Int64?>,
    categories: [Category]
) -> [(id: String, category: Category?, items: [Item])] {
    let grouped = Dictionary(grouping: items, by: { $0[keyPath: keyPath] })
    var named: [(id: String, category: Category?, items: [Item])] = []
    var other: [Item] = grouped[nil] ?? []
    for (catID, group) in grouped {
        guard let catID else { continue }
        if let cat = categories.first(where: { $0.id == catID }) {
            named.append((id: "\(catID)", category: cat, items: group))
        } else {
            other.append(contentsOf: group)
        }
    }
    named.sort { $0.category!.sortOrder < $1.category!.sortOrder }
    if !other.isEmpty {
        named.append((id: "other", category: nil, items: other))
    }
    return named
}
