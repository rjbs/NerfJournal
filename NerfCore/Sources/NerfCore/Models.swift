import Foundation
import GRDB

public enum CategoryColor: String, CaseIterable, Codable, Sendable {
    case blue, red, green, orange, purple, pink, teal, yellow

    // A TaskList's color is a CSS color, a name or #rrggbb. Every case here
    // is itself a CSS color name, so writing is just the raw value. Reading
    // takes one of our names as is and a hex value as the nearest case in
    // RGB; anything else is nil and the caller falls back to `derived(from:)`.
    // -- claude, 2026-10-28
    public var cssName: String { rawValue }

    public init?(css: String) {
        let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = CategoryColor(rawValue: trimmed) {
            self = named
            return
        }
        guard let rgb = Self.parseHex(trimmed) else { return nil }
        self = Self.allCases.min { Self.distance($0.rgb, rgb) < Self.distance($1.rgb, rgb) }!
    }

    // The color for a list that has none, chosen from its name so every
    // client picks the same one. FNV-1a rather than Hasher, whose seed
    // changes per process.
    public static func derived(from name: String) -> CategoryColor {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return allCases[Int(hash % UInt32(allCases.count))]
    }

    // The CSS value of each name, for nearest-match reading.
    var rgb: (Int, Int, Int) {
        switch self {
        case .blue:   (0x00, 0x00, 0xff)
        case .red:    (0xff, 0x00, 0x00)
        case .green:  (0x00, 0x80, 0x00)
        case .orange: (0xff, 0xa5, 0x00)
        case .purple: (0x80, 0x00, 0x80)
        case .pink:   (0xff, 0xc0, 0xcb)
        case .teal:   (0x00, 0x80, 0x80)
        case .yellow: (0xff, 0xff, 0x00)
        }
    }

    private static func parseHex(_ s: String) -> (Int, Int, Int)? {
        guard s.hasPrefix("#") else { return nil }
        var digits = Array(s.dropFirst())
        if digits.count == 3 {
            digits = digits.flatMap { [$0, $0] }
        }
        guard digits.count == 6, let value = Int(String(digits), radix: 16) else { return nil }
        return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    private static func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        let (dr, dg, db) = (a.0 - b.0, a.1 - b.1, a.2 - b.2)
        return dr * dr + dg * dg + db * db
    }
}

// A category is a TaskList on the server; `id` is the engine's local key
// for that list, as a Todo's is for its Task. See TaskListIndex, which
// builds these from the lists in the store. -- claude, 2026-10-28
public struct Category: Identifiable, Codable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var color: CategoryColor
    public var sortOrder: Int

    public init(id: Int64?, name: String, color: CategoryColor, sortOrder: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }
}

// NOTE: Named TaskBundle rather than Bundle to avoid shadowing Foundation.Bundle.
public struct TaskBundle: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var sortOrder: Int
    public var todosShouldMigrate: Bool

    public init(id: Int64?, name: String, sortOrder: Int, todosShouldMigrate: Bool) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.todosShouldMigrate = todosShouldMigrate
    }

    public static let databaseTableName = "taskBundle"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct BundleTodo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var bundleID: Int64
    public var title: String
    public var sortOrder: Int
    public var externalURL: String?
    public var categoryID: Int64?

    public init(id: Int64?, bundleID: Int64, title: String, sortOrder: Int,
                externalURL: String? = nil, categoryID: Int64? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.sortOrder = sortOrder
        self.externalURL = externalURL
        self.categoryID = categoryID
    }

    public static let databaseTableName = "bundleTodo"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct JournalPage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var date: CivilDate

    public static let databaseTableName = "journalPage"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public init(id: Int64?, date: CivilDate) {
        self.id = id
        self.date = date
    }
}

// Completion or abandonment record, encoded as a nested object in export
// JSON and carried on the server as the Task's progress and endedAt.
//
// `day` (the civil day it ended) is always present — the ordering/membership
// spine. `time` is the precise moment when we know it (a genuine completion),
// and nil when we don't: resolving something on a past page, or the auto-abandon
// sweep, both of which record only the day. -- claude, 2026-07-25
public struct TodoEnding: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case done, abandoned }
    public var day: CivilDate
    public var time: Moment?
    public var kind: Kind

    public init(day: CivilDate, time: Moment? = nil, kind: Kind) {
        self.day = day
        self.time = time
        self.kind = kind
    }

    // A moment-based ending keeps its civil day in sync with the moment.
    public init(moment: Moment, kind: Kind) {
        self.init(day: moment.civilDate, time: moment, kind: kind)
    }
}

// A todo spans journal pages naturally: it is visible on any day from its
// `start` date until the day it ends. No per-page duplication; "migration"
// is an emergent display property, not a status value. A todo is a Task
// on the server, decoded by TaskCodec; its id is the sync engine's local
// key for that Task.
public struct Todo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    public var shouldMigrate: Bool
    public var start: CivilDate   // the first day the todo appears
    public var ending: TodoEnding?
    public var categoryID: Int64?
    public var externalURL: String?

    public init(id: Int64?, title: String, shouldMigrate: Bool, start: CivilDate,
                ending: TodoEnding? = nil, categoryID: Int64? = nil, externalURL: String? = nil) {
        self.id = id
        self.title = title
        self.shouldMigrate = shouldMigrate
        self.start = start
        self.ending = ending
        self.categoryID = categoryID
        self.externalURL = externalURL
    }

    public var isPending:   Bool { ending == nil }
    public var isDone:      Bool { ending?.kind == .done }
    public var isAbandoned: Bool { ending?.kind == .abandoned }
}

public struct ExportGroup: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public var id: Int64?
    public var name: String
    public var sortOrder: Int

    public init(id: Int64?, name: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }

    public static let databaseTableName = "exportGroup"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Junction record linking an ExportGroup to a category it contains.
// categoryID == nil represents the "Other" bucket (uncategorized todos).
public struct ExportGroupMember: Codable, FetchableRecord, TableRecord, Sendable {
    public var groupID: Int64
    public var categoryID: Int64?

    public init(groupID: Int64, categoryID: Int64?) {
        self.groupID = groupID
        self.categoryID = categoryID
    }

    public static let databaseTableName = "exportGroupMember"
}

extension [Todo] {
    // Sort by insertion order (id); cross-category ordering is done in the view
    // using category.sortOrder.
    public func sortedForDisplay() -> [Todo] {
        sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }
}

// Groups `items` by category, sorting named groups by `category.sortOrder`.
// Items whose categoryID is nil or no longer matches a known category collect
// into an "Other" group appended at the end. -- claude, 2026-03-02
public func groupedByCategory<Item>(
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
