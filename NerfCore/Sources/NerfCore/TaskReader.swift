import Foundation
import Jinx
import JinxJSON
import JinxStore
import JinxWire

/// A todo as read from the sync engine, with the state of its Task's sync.
///
/// The todo's ``Todo/id`` is the Task's local key.  The rest is what a view
/// may want to show about the Task's journey to the server.
public struct SyncedTodo: Sendable, Equatable, Identifiable {
    /// The Task's local key in the sync engine.
    public var key: LocalKey

    /// The todo, decoded from the Task.
    public var todo: Todo

    /// The Task's uid, chosen when it was created, or nil for a Task another
    /// client created without one.
    public var uid: String?

    /// The Task's JMAP id, once the server has assigned one.
    public var serverId: String?

    /// The change to the Task still waiting to be sent to the server, if
    /// any.
    public var pending: PendingOperation?

    /// Why the server refused the last change sent, if it did.
    public var lastError: SetError?

    /// The local key, as a number, so that a list of these can be keyed by
    /// the same ids as todos.
    public var id: Int64 { key.rawValue }
}

/// Reads todos out of the sync engine's store.
///
/// Every read decodes every Task, with ``TaskCodec``, against the lists as
/// they stand.  The journal is small enough that filtering is done in memory
/// by the caller.  A Task whose destruction is still waiting to be sent to
/// the server is already gone as far as the journal is concerned, and is
/// left out.
public struct TaskReader: Sendable {
    /// The engine read from.
    public let sync: JournalSync

    /// Makes a reader for the engine in `sync`.
    public init(sync: JournalSync) {
        self.sync = sync
    }

    /// Every todo, with the state of its Task's sync, in local key order.
    ///
    /// `zone` is the time zone in which a Task with no start day, written
    /// by another client, has an instant turned into one.
    public func syncedTodos(zone: TimeZone = .current) async throws -> [SyncedTodo] {
        let lists = try await sync.listIndex()
        return try await sync.tasks().compactMap { object in
            guard object.pending != .destroy else { return nil }
            return SyncedTodo(
                key: object.key,
                todo: TaskCodec.decode(object.value, id: object.key.rawValue, lists: lists, zone: zone),
                uid: object.value["uid"]?.stringValue,
                serverId: object.id,
                pending: object.pending,
                lastError: object.lastError
            )
        }
    }

    /// Every todo, in local key order.  See ``syncedTodos(zone:)``.
    public func todos(zone: TimeZone = .current) async throws -> [Todo] {
        try await syncedTodos(zone: zone).map(\.todo)
    }
}
