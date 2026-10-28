import Foundation
import Jinx
import JinxJSON
import JinxPatch
import JinxStore

// Writes todos into the sync engine. Each method is one engine write, so a
// change touching several todos is one transaction and one batch on the
// wire. A change to an existing todo decodes the Task as it stands,
// applies the change to the Todo, and encodes it back against that same
// value, so another client's properties ride through untouched and the
// engine's diff names only what actually changed. -- claude, 2026-10-28
public struct TaskWriter: Sendable {
    public let sync: JournalSync

    public init(sync: JournalSync) {
        self.sync = sync
    }

    // MARK: - Creating

    public func create(_ todo: Todo, now: Date = Date()) async throws -> LocalKey {
        try await createMany([todo], now: now)[0]
    }

    // Keys come back in the order of `todos`. Each new Task gets a fresh
    // uid, which is what makes a create safe to resend.
    public func createMany(_ todos: [Todo], now: Date = Date()) async throws -> [LocalKey] {
        guard !todos.isEmpty else { return [] }
        let categories = try await sync.categories()
        let listId = try await sync.taskListId()
        let encodings = todos.map {
            TaskCodec.encodeNew($0, categories: categories, uid: UUID().uuidString.lowercased(), taskListId: listId, now: now)
        }
        return try await sync.engine.write { writer in
            try writer.adopt(JournalSync.taskType.name, encodings)
        }
    }

    // MARK: - Changing

    public func update(_ key: LocalKey, now: Date = Date(), _ change: @Sendable (inout Todo) -> Void) async throws {
        try await updateMany([key], now: now, change)
    }

    public func updateMany(_ keys: [LocalKey], now: Date = Date(), _ change: @Sendable (inout Todo) -> Void) async throws {
        guard !keys.isEmpty else { return }
        let categories = try await sync.categories()
        try await sync.engine.write { writer in
            for key in keys {
                try writer.update(key) { current in
                    var todo = TaskCodec.decode(current, id: key.rawValue, categories: categories)
                    change(&todo)
                    let encoding = TaskCodec.encode(todo, categories: categories, existing: current, now: now)
                    return try current.mergingOwnedProperties(TaskCodec.ownedProperties, from: encoding)
                }
            }
        }
    }

    public func destroy(_ keys: [LocalKey]) async throws {
        guard !keys.isEmpty else { return }
        try await sync.engine.write { writer in
            for key in keys {
                try writer.destroy(key)
            }
        }
    }

    // MARK: - The sweep

    // Cancels every pending todo that does not migrate and started before
    // `today`, as of its start day: a non-migrating todo is live on exactly
    // one day, so that is the day it was abandoned. Idempotent, and
    // independent of journal pages, so any client may run it. Returns the
    // keys it cancelled.
    @discardableResult
    public func sweep(asOf today: CivilDate, now: Date = Date()) async throws -> [LocalKey] {
        let categories = try await sync.categories()
        let stale = try await sync.tasks().filter { object in
            guard object.pending != .destroy else { return false }
            let todo = TaskCodec.decode(object.value, id: object.key.rawValue, categories: categories)
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
