import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

/// Writes categories, which are TaskLists, into the sync engine.
///
/// Two of these changes are sent to the server before they return, because
/// Jinx can't yet carry a reference to a list the server hasn't
/// acknowledged.  A new list is sent so that Tasks can be filed in it, and a
/// deleted list's Tasks are moved out of it and sent before its destruction,
/// which would otherwise travel first and be refused.
public struct CategoryWriter: Sendable {
    /// The engine written to.
    public let sync: JournalSync

    /// Makes a writer for the engine in `sync`.
    public init(sync: JournalSync) {
        self.sync = sync
    }

    /// Creates a category, sorted after all the others, sends it to the
    /// server, and returns its list's local key.
    ///
    /// If sending fails, the list is left waiting to be sent, so that it is
    /// a category but can't yet have todos filed in it.  The engine keeps
    /// trying.
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

    /// Renames the category whose list has the local key `key`.
    public func rename(_ key: LocalKey, to name: String) async throws {
        try await setProperty(key, "name", .string(name))
    }

    /// Changes the color of the category whose list has the local key
    /// `key`.
    public func setColor(_ key: LocalKey, to color: CategoryColor) async throws {
        try await setProperty(key, "color", .string(color.cssName))
    }

    /// Puts the categories whose lists have the local keys `keys` in that
    /// order, in one write.
    ///
    /// Each list's `sortOrder` becomes its position in `keys`.  Lists not
    /// named keep theirs.
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

    /// Deletes the category whose list has the local key `key`, leaving its
    /// todos uncategorized.
    ///
    /// The category's Tasks are moved to the default list and that is sent
    /// to the server.  Then the list is destroyed, and the category is
    /// cleared from bundle todos and removed from export groups.  If sending
    /// the move fails, the category stays, Tasks and all, and the error says
    /// why.
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
