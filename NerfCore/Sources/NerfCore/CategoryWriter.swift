import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

// Writes categories, which are TaskLists, into the sync engine. Two of
// these go to the server before returning, because Jinx cannot yet carry a
// reference to a list the server has not acknowledged: a new list syncs so
// that Tasks can be filed in it, and a deleted list syncs the departure of
// its Tasks before the destroy, which would otherwise travel first and be
// refused. -- claude, 2026-10-28
public struct CategoryWriter: Sendable {
    public let sync: JournalSync

    public init(sync: JournalSync) {
        self.sync = sync
    }

    // Creates a list after the last category in order and pushes it. A
    // push that fails leaves the list pending, visible as a category but
    // not yet usable for filing; the engine keeps trying.
    @discardableResult
    public func create(name: String, color: CategoryColor) async throws -> LocalKey {
        let index = try await sync.listIndex()
        let sortOrder = (index.categoryEntries.map(\.sortOrder).max() ?? -1) + 1
        let key = try await sync.engine.create(
            JournalSync.listType.name,
            TaskListIndex.encodeList(name: name, color: color, sortOrder: sortOrder)
        )
        try? await sync.engine.sync()
        return key
    }

    public func rename(_ key: LocalKey, to name: String) async throws {
        try await setProperty(key, "name", .string(name))
    }

    public func setColor(_ key: LocalKey, to color: CategoryColor) async throws {
        try await setProperty(key, "color", .string(color.cssName))
    }

    // Gives the lists `sortOrder` by their position in `keys`, in one
    // batch. Lists not named keep their order.
    public func reorder(_ keys: [LocalKey]) async throws {
        try await sync.engine.write { writer in
            for (index, key) in keys.enumerated() {
                try writer.update(key) { current in
                    var list = current
                    list["sortOrder"] = .number(Double(index))
                    return list
                }
            }
        }
    }

    // Moves the category's Tasks to the default list, pushes that, then
    // destroys the list, and finally forgets the category in bundle todos
    // and export groups. If the push fails the category stays, Tasks and
    // all, and the error says why.
    public func delete(_ key: LocalKey) async throws {
        let index = try await sync.listIndex()
        guard let entry = index.entry(forCategory: key.rawValue) else { return }
        if let listId = entry.serverId {
            let members = try await sync.tasks().filter { object in
                object.pending != .destroy && object.value["taskListIds"]?[listId] == .bool(true)
            }.map(\.key)
            if !members.isEmpty {
                try await TaskWriter(sync: sync).updateMany(members) { $0.categoryID = nil }
                try await sync.engine.sync()
            }
        }
        try await sync.engine.destroy(key)
        let id = key.rawValue
        try await sync.writer.write { db in
            try db.execute(sql: "UPDATE bundleTodo SET categoryID = NULL WHERE categoryID = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM exportGroupMember WHERE categoryID = ?", arguments: [id])
        }
    }

    private func setProperty(_ key: LocalKey, _ name: String, _ value: JSONValue) async throws {
        try await sync.engine.update(key) { current in
            var list = current
            list[name] = value
            return list
        }
    }
}
