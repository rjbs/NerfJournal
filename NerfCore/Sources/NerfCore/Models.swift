import Foundation
import GRDB

/// One of the eight colors a category can have.
///
/// On the server, a category's color is its TaskList's `color`, which may be
/// any CSS color.  Each case's raw value is a CSS color name, so a color
/// written by NerfJournal is read back as the same case.
public enum CategoryColor: String, CaseIterable, Codable, Sendable {
    case blue, red, green, orange, purple, pink, teal, yellow

    /// The CSS color name to write to a TaskList, which is the raw value.
    public var cssName: String { rawValue }

    /// The case for a TaskList's CSS color, or nil if it is neither one of
    /// these names nor a hex color.
    ///
    /// A hex color, `#rrggbb` or `#rgb`, reads as the nearest case in RGB, so
    /// a color picked by another client still reads as something close.  A
    /// list whose color is nil gets one from ``derived(from:)``.
    public init?(css: String) {
        let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = CategoryColor(rawValue: trimmed) {
            self = named
            return
        }
        guard let rgb = Self.parseHex(trimmed) else { return nil }
        self = Self.allCases.min { Self.distance($0.rgb, rgb) < Self.distance($1.rgb, rgb) }!
    }

    /// The color for a list that has none, chosen from its name, so that
    /// every client picks the same one.
    ///
    /// The name is hashed with FNV-1a, not `Hasher`, whose seed changes from
    /// one process to the next.
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

/// A category that todos can be filed in, which is a TaskList on the server.
///
/// Categories are built from the lists in the sync engine's store by
/// ``TaskListIndex``, and changed with ``CategoryWriter``.
public struct Category: Identifiable, Codable, Hashable, Sendable {
    /// The sync engine's local key for the category's TaskList, as a
    /// ``Todo``'s id is for its Task.
    public var id: Int64?

    /// The category's name, which is its TaskList's.
    public var name: String

    /// The category's color.
    public var color: CategoryColor

    /// Where the category sorts among the others, lowest first.
    public var sortOrder: Int

    /// Makes a category from its parts.
    public init(id: Int64?, name: String, color: CategoryColor, sortOrder: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.sortOrder = sortOrder
    }
}

/// A named set of todos that can be added to a page all at once.
///
/// A bundle and its ``BundleTodo``s are stored in the journal's own tables,
/// not on the server.  It is called `TaskBundle`, not `Bundle`, so as not to
/// shadow Foundation's.
public struct TaskBundle: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The bundle's row id, or nil before it is inserted.
    public var id: Int64?

    /// The bundle's name.
    public var name: String

    /// Where the bundle sorts among the others, lowest first.
    public var sortOrder: Int

    /// Whether the todos made from this bundle carry forward to later days
    /// until they are done, as ``Todo/shouldMigrate`` says.
    public var todosShouldMigrate: Bool

    /// Makes a bundle from its parts.
    public init(id: Int64?, name: String, sortOrder: Int, todosShouldMigrate: Bool) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.todosShouldMigrate = todosShouldMigrate
    }

    /// The table bundles are stored in.
    public static let databaseTableName = "taskBundle"

    /// Takes the row id SQLite assigned as the bundle's ``id``.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One todo in a ``TaskBundle``, from which a ``Todo`` is made each time the
/// bundle is applied.
public struct BundleTodo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The bundle todo's row id, or nil before it is inserted.
    public var id: Int64?

    /// The id of the ``TaskBundle`` this belongs to.
    public var bundleID: Int64

    /// The title the todo will have.
    public var title: String

    /// Where this sorts within its bundle, lowest first.
    public var sortOrder: Int

    /// The URL the todo will link to, if any.
    public var externalURL: String?

    /// The id of the ``Category`` the todo will be filed in, or nil for
    /// none.
    ///
    /// There is no foreign key behind this, since categories live in the
    /// sync engine, so ``CategoryWriter/delete(_:)`` clears it.
    public var categoryID: Int64?

    /// Makes a bundle todo from its parts.
    public init(id: Int64?, bundleID: Int64, title: String, sortOrder: Int,
                externalURL: String? = nil, categoryID: Int64? = nil) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
        self.sortOrder = sortOrder
        self.externalURL = externalURL
        self.categoryID = categoryID
    }

    /// The table bundle todos are stored in.
    public static let databaseTableName = "bundleTodo"

    /// Takes the row id SQLite assigned as the bundle todo's ``id``.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A day that has been started in the journal.
///
/// A page holds no todos.  A todo belongs to no page, and is shown on every
/// page from its start until it ends; the page records only that the day
/// was begun.  Pages are stored in the journal's own tables.
public struct JournalPage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The page's row id, or nil before it is inserted.
    public var id: Int64?

    /// The day the page is for.  No two pages have the same date.
    public var date: CivilDate

    /// The table pages are stored in.
    public static let databaseTableName = "journalPage"

    /// Takes the row id SQLite assigned as the page's ``id``.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Makes a page from its parts.
    public init(id: Int64?, date: CivilDate) {
        self.id = id
        self.date = date
    }
}

/// How and when a todo ended: done or abandoned, on a day and perhaps at a
/// moment.
///
/// It is a nested object in an export file, and on the server it is the
/// Task's `progress` and NerfJournal's own `endedAt` property.
///
/// ``day`` is always present, and is what decides which pages show the todo
/// as ended.  ``time`` is the precise ``Moment`` when it is known, as it is
/// when a todo is marked done as it happens, and nil when it is not: when
/// something is resolved on a past page, or abandoned by
/// ``TaskWriter/sweep(asOf:now:)``, only the day is recorded.
public struct TodoEnding: Codable, Hashable, Sendable {
    /// Whether a todo was done or abandoned.
    public enum Kind: String, Codable, Sendable {
        /// The todo was done: the Task's progress is `completed`.
        case done

        /// The todo was abandoned: the Task's progress is `cancelled`, or
        /// `failed` if another client said so.
        case abandoned
    }

    /// The day the todo ended.
    public var day: CivilDate

    /// The moment the todo ended, if it is known.
    public var time: Moment?

    /// Whether the todo was done or abandoned.
    public var kind: Kind

    /// Makes an ending from its parts.  The day and the moment's day are not
    /// checked against each other; ``init(moment:kind:)`` keeps them in step.
    public init(day: CivilDate, time: Moment? = nil, kind: Kind) {
        self.day = day
        self.time = time
        self.kind = kind
    }

    /// Makes an ending at a moment, on the moment's own civil day.
    public init(moment: Moment, kind: Kind) {
        self.init(day: moment.civilDate, time: moment, kind: kind)
    }
}

/// Something to do, which is a Task on the server.
///
/// A todo is visible on every day from its ``start`` until the day it ends,
/// with no copy of it on each page.  That a todo "migrates" from one day to
/// the next is a matter of how it is shown, not a state it is in.  Tasks are
/// turned into todos and back by ``TaskCodec``.
public struct Todo: Identifiable, Codable, Equatable, Sendable {
    /// The sync engine's local key for the todo's Task, or nil for a todo
    /// that hasn't been written yet.
    public var id: Int64?

    /// What is to be done.
    public var title: String

    /// Whether the todo carries forward to later days until it ends.
    ///
    /// A todo that doesn't is live on its start day only, and if it is still
    /// pending after that, ``TaskWriter/sweep(asOf:now:)`` abandons it.  On
    /// the server, a todo that doesn't migrate has NerfJournal's
    /// `autoCancel` property set.
    public var shouldMigrate: Bool

    /// The first day the todo appears, which is in the future for a todo in
    /// the Future Log.
    public var start: CivilDate

    /// How and when the todo ended, or nil while it is pending.
    public var ending: TodoEnding?

    /// The id of the ``Category`` the todo is filed in, or nil for none.
    public var categoryID: Int64?

    /// A URL the todo links to, if any.
    public var externalURL: String?

    /// Makes a todo from its parts.
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

    /// Whether the todo has not yet ended.
    public var isPending:   Bool { ending == nil }

    /// Whether the todo ended by being done.
    public var isDone:      Bool { ending?.kind == .done }

    /// Whether the todo ended by being abandoned.
    public var isAbandoned: Bool { ending?.kind == .abandoned }
}

/// A named set of categories, used to export only part of a page.
///
/// Groups are stored in the journal's own tables, with their categories as
/// ``ExportGroupMember`` rows.
public struct ExportGroup: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    /// The group's row id, or nil before it is inserted.
    public var id: Int64?

    /// The group's name.
    public var name: String

    /// Where the group sorts among the others, lowest first.
    public var sortOrder: Int

    /// Makes a group from its parts.
    public init(id: Int64?, name: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }

    /// The table groups are stored in.
    public static let databaseTableName = "exportGroup"

    /// Takes the row id SQLite assigned as the group's ``id``.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One category in an ``ExportGroup``.
public struct ExportGroupMember: Codable, FetchableRecord, TableRecord, Sendable {
    /// The id of the group.
    public var groupID: Int64

    /// The id of the ``Category``, or nil for the uncategorized todos, which
    /// are exported under "Other".
    public var categoryID: Int64?

    /// Makes a membership from its parts.
    public init(groupID: Int64, categoryID: Int64?) {
        self.groupID = groupID
        self.categoryID = categoryID
    }

    /// The table memberships are stored in.
    public static let databaseTableName = "exportGroupMember"
}

extension [Todo] {
    /// The todos in the order they were made, which is the order of their
    /// ids.
    ///
    /// Ordering by category, by ``Category/sortOrder``, is left to the view.
    public func sortedForDisplay() -> [Todo] {
        sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }
}

/// Groups items by category, in the categories' order, with the
/// uncategorized ones last.
///
/// Each group's `id` is its category's id as a string, or "other".  An item
/// whose category id is nil, or names no category in `categories`, goes in
/// the "Other" group, which is left out when it would be empty.
///
/// - Parameters:
///   - items: The things to group, like todos or bundle todos.
///   - keyPath: Where each item keeps its category id.
///   - categories: The known categories.
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
