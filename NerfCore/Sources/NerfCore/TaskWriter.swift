import Foundation
import Jinx
import JinxJSON
import JinxPatch
import JinxStore

/// Writes todos into the sync engine, which sends them to the server.
///
/// Each method is one write to the engine, so a change to several todos is
/// one transaction, and one batch on the wire.  A change to an existing todo
/// decodes the Task as it stands, applies the change to the ``Todo``, and
/// encodes it back against that same Task, so that properties set by other
/// clients ride through untouched, and the engine's diff names only what
/// actually changed.
///
/// A `now` parameter is the time recorded as the write's, and is there so
/// that tests can fix it.
public struct TaskWriter: Sendable {
    /// The engine written to.
    public let sync: JournalSync

    /// Makes a writer for the engine in `sync`.
    public init(sync: JournalSync) {
        self.sync = sync
    }

    // MARK: - Creating

    /// Creates a Task for `todo`, and returns its local key.  See
    /// ``createMany(_:now:)``.
    public func create(_ todo: Todo, now: Date = Date()) async throws -> LocalKey {
        try await createMany([todo], now: now)[0]
    }

    /// Creates a Task for each of `todos`, and returns their local keys in
    /// the same order.
    ///
    /// The todos' ids are ignored.  Each new Task gets a fresh uid, which is
    /// what makes a create safe to send again.  A todo filed in a category
    /// whose list hasn't reached the server yet can't be created, and the
    /// error is ``JournalSyncError/categoryNotSynced(_:)``.
    public func createMany(_ todos: [Todo], now: Date = Date()) async throws -> [LocalKey] {
        guard !todos.isEmpty else { return [] }
        let lists = try await sync.listIndex()
        let encodings = try todos.map {
            try TaskCodec.encodeNew($0, lists: lists, uid: UUID().uuidString.lowercased(), now: now)
        }
        return try await sync.engine.write { writer in
            try writer.adopt(JournalSync.taskType.name, encodings)
        }
    }

    /// Creates Tasks for todos that already have uids, as from an export
    /// file.
    ///
    /// The caller must check that no Task in the store has any of these
    /// uids.  The server would refuse a duplicate, and its create would sit
    /// in the engine as a failure.
    public func adopt(_ todos: [(uid: String, todo: Todo)], now: Date = Date()) async throws {
        guard !todos.isEmpty else { return }
        let lists = try await sync.listIndex()
        let encodings = try todos.map {
            try TaskCodec.encodeNew($0.todo, lists: lists, uid: $0.uid, now: now)
        }
        try await sync.engine.write { writer in
            _ = try writer.adopt(JournalSync.taskType.name, encodings)
        }
    }

    // MARK: - Changing

    /// Changes the todo with the local key `key`.  See
    /// ``updateMany(_:now:_:)``.
    public func update(_ key: LocalKey, now: Date = Date(), _ change: @Sendable (inout Todo) -> Void) async throws {
        try await updateMany([key], now: now, change)
    }

    /// Changes each of the todos with the local keys `keys`, in one write.
    ///
    /// `change` is called with each todo as it stands in the store, and
    /// changes it in place.  Only the properties NerfJournal owns, which are
    /// ``TaskCodec/ownedProperties``, are written back.
    public func updateMany(_ keys: [LocalKey], now: Date = Date(), _ change: @Sendable (inout Todo) -> Void) async throws {
        guard !keys.isEmpty else { return }
        let lists = try await sync.listIndex()
        try await sync.engine.write { writer in
            for key in keys {
                try writer.update(key) { current in
                    var todo = TaskCodec.decode(current, id: key.rawValue, lists: lists)
                    change(&todo)
                    let encoding = try TaskCodec.encode(todo, lists: lists, existing: current, now: now)
                    return try current.mergingOwnedProperties(TaskCodec.ownedProperties, from: encoding)
                }
            }
        }
    }

    /// Destroys the Tasks with the local keys `keys`, in one write.
    public func destroy(_ keys: [LocalKey]) async throws {
        guard !keys.isEmpty else { return }
        try await sync.engine.write { writer in
            for key in keys {
                try writer.destroy(key)
            }
        }
    }

    // MARK: - The sweep

    /// Abandons every pending todo that doesn't migrate and started before
    /// `today`, and returns the local keys of those it abandoned.
    ///
    /// Each is abandoned as of its start day, with no moment: a todo that
    /// doesn't migrate is live on exactly one day, so that is the day it was
    /// abandoned.  Running the sweep again does nothing more, and it doesn't
    /// depend on journal pages, so any client may run it.
    @discardableResult
    public func sweep(asOf today: CivilDate, now: Date = Date()) async throws -> [LocalKey] {
        let lists = try await sync.listIndex()
        let stale = try await sync.tasks().filter { object in
            guard object.pending != .destroy else { return false }
            let todo = TaskCodec.decode(object.value, id: object.key.rawValue, lists: lists)
            return todo.isPending && !todo.shouldMigrate && todo.start < today
        }
        guard !stale.isEmpty else { return [] }
        let keys = stale.map(\.key)
        try await updateMany(keys, now: now) { todo in
            todo.ending = TodoEnding(day: todo.start, kind: .abandoned)
        }
        return keys
    }
}
