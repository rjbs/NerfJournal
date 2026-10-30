import Foundation
import Jinx
import JinxJSON
import JinxStore
import JinxWire

// The TaskLists as this client holds them, and what they mean to the
// journal: the default list is "no category," and every other list is a
// category whose id is the list's local key. An index is built fresh for
// each read or write, since a list's server id can arrive with any sync
// and the default flag can move. -- claude, 2026-10-28
public struct TaskListIndex: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var key: LocalKey
        // The JMAP id, once the server has assigned one. A Task can only be
        // filed in a list that has one.
        public var serverId: String?
        public var name: String
        public var color: CategoryColor
        public var sortOrder: Int
        public var isDefault: Bool
        public var pending: PendingOperation?
        public var lastError: SetError?

        public init(key: LocalKey, serverId: String?, name: String, color: CategoryColor, sortOrder: Int,
                    isDefault: Bool, pending: PendingOperation? = nil, lastError: SetError? = nil) {
            self.key = key
            self.serverId = serverId
            self.name = name
            self.color = color
            self.sortOrder = sortOrder
            self.isDefault = isDefault
            self.pending = pending
            self.lastError = lastError
        }

        // Lenient, as all reading is: a list another client made with no
        // color gets one from its name, and no sort order reads as zero.
        init(_ object: SyncedObject) {
            let name = object.value["name"]?.stringValue ?? ""
            self.init(
                key: object.key,
                serverId: object.id,
                name: name,
                color: object.value["color"]?.stringValue.flatMap(CategoryColor.init(css:)) ?? .derived(from: name),
                sortOrder: object.value["sortOrder"]?.intValue ?? 0,
                isDefault: object.value["isDefault"] == .bool(true),
                pending: object.pending,
                lastError: object.lastError
            )
        }

        public var category: Category {
            Category(id: key.rawValue, name: name, color: color, sortOrder: sortOrder)
        }
    }

    // Every list not being destroyed, in display order.
    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries.sorted {
            ($0.sortOrder, $0.name, $0.key.rawValue) < ($1.sortOrder, $1.name, $1.key.rawValue)
        }
    }

    public init(objects: [SyncedObject]) {
        self.init(entries: objects.filter { $0.pending != .destroy }.map(Entry.init))
    }

    // The list for uncategorized Tasks: the one flagged default, or failing
    // that the first in order, so an account whose server never flags one
    // still works. Nil only when there are no lists at all.
    public var defaultEntry: Entry? {
        entries.first { $0.isDefault } ?? entries.first
    }

    public var defaultListId: String? { defaultEntry?.serverId }

    public var categoryEntries: [Entry] {
        let defaultKey = defaultEntry?.key
        return entries.filter { $0.key != defaultKey }
    }

    public var categories: [Category] { categoryEntries.map(\.category) }

    public func entry(forCategory id: Int64) -> Entry? {
        categoryEntries.first { $0.key.rawValue == id }
    }

    public func entry(named name: String) -> Entry? {
        categoryEntries.first { $0.name == name }
    }

    // The category a Task's `taskListIds` puts it in: the first category
    // list, in order, that it belongs to. A Task only in the default list,
    // or only in lists this client has not fetched, has none.
    public func categoryID(forListIds listIds: JSONValue?) -> Int64? {
        guard let members = listIds?.objectValue else { return nil }
        let ids = Set(members.compactMap { key, value in value == .bool(true) ? key : nil })
        return categoryEntries.first { entry in entry.serverId.map(ids.contains) ?? false }?.key.rawValue
    }

    // The encoding of a list this client creates. `isDefault` is the
    // server's to set, so it is never written.
    public static func encodeList(name: String, color: CategoryColor, sortOrder: Int) -> JSONValue {
        ["name": .string(name), "color": .string(color.cssName), "sortOrder": .number(Double(sortOrder))]
    }
}
