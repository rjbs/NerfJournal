import Foundation
import Jinx
import JinxJSON
import JinxStore
import JinxWire

// A todo as read from the sync engine: the decoded Todo, whose id is the
// engine's local key, plus the sync facts a view may want to show.
public struct SyncedTodo: Sendable, Equatable, Identifiable {
    public var key: LocalKey
    public var todo: Todo
    // The Task's uid, chosen at creation; nil only for a Task another
    // client created without one.
    public var uid: String?
    // The JMAP id, once the server has assigned one.
    public var serverId: String?
    public var pending: PendingOperation?
    public var lastError: SetError?

    public var id: Int64 { key.rawValue }
}

// Reads todos out of the sync engine's store. Every read decodes every Task
// through the codec against the current categories; the journal is small
// enough that filtering happens in memory, as it always has. A Task whose
// destroy is still waiting to be pushed is already gone as far as the
// journal is concerned. -- claude, 2026-10-28
public struct TaskReader: Sendable {
    public let sync: JournalSync

    public init(sync: JournalSync) {
        self.sync = sync
    }

    public func syncedTodos(zone: TimeZone = .current) async throws -> [SyncedTodo] {
        // A keyword naming a category this client has never seen becomes a
        // local Category first, so no Task reads as uncategorized merely
        // because another client named the category.
        try await sync.adoptUnknownCategories()
        let categories = try await sync.categories()
        return try await sync.tasks().compactMap { object in
            guard object.pending != .destroy else { return nil }
            return SyncedTodo(
                key: object.key,
                todo: TaskCodec.decode(object.value, id: object.key.rawValue, categories: categories, zone: zone),
                uid: object.value["uid"]?.stringValue,
                serverId: object.id,
                pending: object.pending,
                lastError: object.lastError
            )
        }
    }

    public func todos(zone: TimeZone = .current) async throws -> [Todo] {
        try await syncedTodos(zone: zone).map(\.todo)
    }
}
