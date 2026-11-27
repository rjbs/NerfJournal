import Foundation
import Jinx
import JinxJSON
import JinxStore
import JinxWire

/// The TaskLists as this client holds them, and what they mean to the
/// journal.
///
/// The default list holds the todos with no category, and every other list
/// is a ``Category``, whose id is the list's local key.  An index is built
/// fresh for each read or write, since a list's server id can arrive with
/// any sync, and which list is the default can change.
public struct TaskListIndex: Sendable, Equatable {
    /// One TaskList.
    public struct Entry: Sendable, Equatable {
        /// The list's local key in the sync engine.
        public var key: LocalKey

        /// The list's JMAP id, once the server has assigned one.  A Task
        /// can be filed only in a list that has one.
        public var serverId: String?

        /// The list's name.
        public var name: String

        /// The list's color.
        public var color: CategoryColor

        /// Where the list sorts among the others, lowest first.
        public var sortOrder: Int

        /// Whether the server says this is the account's default list.
        public var isDefault: Bool

        /// The change to the list still waiting to be sent to the server, if
        /// any.
        public var pending: PendingOperation?

        /// Why the server refused the last change sent, if it did.
        public var lastError: SetError?

        /// Makes an entry from its parts.
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

        /// The list as a category.
        public var category: Category {
            Category(id: key.rawValue, name: name, color: color, sortOrder: sortOrder)
        }
    }

    /// Every list not being destroyed, in display order.
    public var entries: [Entry]

    /// Makes an index of `entries`, which it puts in display order: by sort
    /// order, then name, then local key.
    public init(entries: [Entry]) {
        self.entries = entries.sorted {
            ($0.sortOrder, $0.name, $0.key.rawValue) < ($1.sortOrder, $1.name, $1.key.rawValue)
        }
    }

    /// Makes an index of the TaskLists in the sync engine's store, leaving
    /// out any waiting to be destroyed.
    ///
    /// Reading is lenient: a list another client made with no color gets
    /// one from its name, by ``CategoryColor/derived(from:)``, and a list
    /// with no sort order sorts as zero.
    public init(objects: [SyncedObject]) {
        self.init(entries: objects.filter { $0.pending != .destroy }.map(Entry.init))
    }

    /// The list for the todos with no category.
    ///
    /// That's the list the server says is the default, or failing that the
    /// first in order, so that an account whose server never says still
    /// works.  It is nil only when there are no lists at all.
    public var defaultEntry: Entry? {
        entries.first { $0.isDefault } ?? entries.first
    }

    /// The JMAP id of the ``defaultEntry``, if it has one.
    public var defaultListId: String? { defaultEntry?.serverId }

    /// Every list but the default, in display order.
    public var categoryEntries: [Entry] {
        let defaultKey = defaultEntry?.key
        return entries.filter { $0.key != defaultKey }
    }

    /// The categories, which are the ``categoryEntries`` as categories.
    public var categories: [Category] { categoryEntries.map(\.category) }

    /// The entry for the category with the id `id`, if there is one.
    public func entry(forCategory id: Int64) -> Entry? {
        categoryEntries.first { $0.key.rawValue == id }
    }

    /// The entry for the first category named `name`, if there is one.
    public func entry(named name: String) -> Entry? {
        categoryEntries.first { $0.name == name }
    }

    /// The id of the category that a Task's `taskListIds` puts it in, or
    /// nil for none.
    ///
    /// That's the first category's list, in display order, that the Task is
    /// in.  A Task only in the default list, or only in lists this client
    /// hasn't fetched, has no category.
    public func categoryID(forListIds listIds: JSONValue?) -> Int64? {
        guard let members = listIds?.objectValue else { return nil }
        let ids = Set(members.compactMap { key, value in value == .bool(true) ? key : nil })
        return categoryEntries.first { entry in entry.serverId.map(ids.contains) ?? false }?.key.rawValue
    }

    /// The JSON for a new TaskList, as this client creates one.
    ///
    /// It has no `isDefault`, since which list is the default is the
    /// server's to say.
    public static func encodeList(name: String, color: CategoryColor, sortOrder: Int) -> JSONValue {
        ["name": .string(name), "color": .string(color.cssName), "sortOrder": .number(Double(sortOrder))]
    }
}
