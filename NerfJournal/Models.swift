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
    var date: CivilDate

    static let databaseTableName = "journalPage"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    init(id: Int64?, date: CivilDate) {
        self.id = id
        self.date = date
    }

    // Custom decode so pre-CivilDate exports (an ISO instant in `date`) still
    // import; encode stays synthesized. -- claude, 2026-07-25
    private enum CodingKeys: String, CodingKey { case id, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        date = try CivilDate.lenientlyDecode(c, forKey: .date)
    }
}

// Completion or abandonment record. Stored as a JSON string in SQLite
// (via DatabaseValueConvertible); encoded as a nested object in export JSON
// (via Codable). These are distinct code paths with no conflict.
//
// `day` (the civil day it ended) is always present — the ordering/membership
// spine. `time` is the precise moment when we know it (a genuine completion),
// and nil when we don't: resolving something on a past page, or the auto-abandon
// sweep, both of which record only the day. -- claude, 2026-07-25
struct TodoEnding: Codable, DatabaseValueConvertible, Hashable {
    enum Kind: String, Codable { case done, abandoned }
    var day: CivilDate
    var time: Moment?
    var kind: Kind

    init(day: CivilDate, time: Moment? = nil, kind: Kind) {
        self.day = day
        self.time = time
        self.kind = kind
    }

    // A moment-based ending keeps its civil day in sync with the moment.
    init(moment: Moment, kind: Kind) {
        self.init(day: moment.civilDate, time: moment, kind: kind)
    }

    // Encode stays synthesized from these three keys. Pre-CivilDate endings
    // stored a single instant under `date`; we read that legacy shape in New York
    // and split it into day + (real) time via the same sentinel logic the DB
    // migration uses. -- claude, 2026-07-25
    private enum CodingKeys: String, CodingKey { case day, time, kind }
    private enum LegacyKeys: String, CodingKey { case date, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let day = try c.decodeIfPresent(CivilDate.self, forKey: .day) {
            self.day = day
            self.time = try c.decodeIfPresent(Moment.self, forKey: .time)
            self.kind = try c.decode(Kind.self, forKey: .kind)
        } else {
            let lc = try decoder.container(keyedBy: LegacyKeys.self)
            let instant = try lc.decode(Date.self, forKey: .date)
            let split = LegacyEnding.classify(
                instant: instant, assuming: TimeZone(identifier: "America/New_York")!)
            self.day = split.day
            self.time = split.moment
            self.kind = try lc.decode(Kind.self, forKey: .kind)
        }
    }

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
    var start: CivilDate   // the first day the todo appears
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
        if c.contains(.start) {
            start = try CivilDate.lenientlyDecode(c, forKey: .start)
        } else {
            start = try CivilDate.lenientlyDecode(c, forKey: .added)
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
