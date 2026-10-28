import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

// A todo in an export file: the Todo's own fields plus the uid its Task
// carries, flattened into one object so files written before the JMAP
// backend (which have no uid) still decode. -- claude, 2026-10-28
public struct ExportedTodo: Codable, Sendable, Equatable {
    public var uid: String?
    public var todo: Todo

    public init(uid: String?, todo: Todo) {
        self.uid = uid
        self.todo = todo
    }

    private enum CodingKeys: String, CodingKey { case uid }

    public init(from decoder: Decoder) throws {
        todo = try Todo(from: decoder)
        uid = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .uid)
    }

    public func encode(to encoder: Encoder) throws {
        try todo.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(uid, forKey: .uid)
    }
}

public struct ImportReport: Sendable, Hashable {
    public var adopted: Int
    public var alreadyPresent: Int
    // Categories in the file that became new TaskLists.
    public var categoriesCreated: Int

    public init(adopted: Int, alreadyPresent: Int, categoriesCreated: Int = 0) {
        self.adopted = adopted
        self.alreadyPresent = alreadyPresent
        self.categoriesCreated = categoriesCreated
    }
}

// Export, import, and reset against the split store: pages, bundles and
// export groups in the journal's own tables, todos and categories in the
// sync engine. Nothing here ever destroys server data; a reset empties
// this client, and the next sync fetches the server's lists and Tasks
// afresh. -- claude, 2026-10-28
extension JournalSync {
    public func exportSnapshot() async throws -> DatabaseExport {
        let todos = try await TaskReader(sync: self).syncedTodos().map { ExportedTodo(uid: $0.uid, todo: $0.todo) }
        let categories = try await categories()
        return try await writer.read { db in
            DatabaseExport(
                version: NerfSchema.currentVersion,
                exportedAt: Date(),
                categories: categories,
                taskBundles: try TaskBundle.order(Column("id")).fetchAll(db),
                bundleTodos: try BundleTodo.order(Column("id")).fetchAll(db),
                journalPages: try JournalPage.order(Column("date")).fetchAll(db),
                todos: todos
            )
        }
    }

    public func exportData() async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(try await exportSnapshot())
    }

    // Gives every category in the file a list, matching by name and
    // creating the rest, then replaces the client-only tables with the
    // file's (bundle todos pointed at the lists) and adopts every todo
    // whose uid the store does not already hold. New lists must reach the
    // server before todos can be filed in them, so the import syncs in the
    // middle. A todo with no uid (a file from before the JMAP backend)
    // gets a fresh one, so importing such a file twice duplicates its
    // todos; that is the price of having no identity to match on.
    @discardableResult
    public func importSnapshot(_ snapshot: DatabaseExport) async throws -> ImportReport {
        var index = try await listIndex()
        var mapping: [Int64: Int64] = [:]
        var created = 0
        for category in snapshot.categories.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard let fileId = category.id else { continue }
            if let existing = index.entry(named: category.name) {
                mapping[fileId] = existing.key.rawValue
            } else {
                let sortOrder = (index.categoryEntries.map(\.sortOrder).max() ?? -1) + 1
                let key = try await engine.create(
                    Self.listType.name,
                    TaskListIndex.encodeList(name: category.name, color: category.color, sortOrder: sortOrder)
                )
                mapping[fileId] = key.rawValue
                index = try await listIndex()
                created += 1
            }
        }
        if created > 0 {
            try await engine.sync()
        }

        try await writer.write { [mapping] db in
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            for var r in snapshot.taskBundles  { try r.insert(db) }
            for var r in snapshot.bundleTodos {
                r.categoryID = r.categoryID.flatMap { mapping[$0] }
                try r.insert(db)
            }
            for var r in snapshot.journalPages { try r.insert(db) }
        }
        let present = Set(try await tasks().compactMap { $0.value["uid"]?.stringValue })
        let fresh = snapshot.todos.filter { $0.uid.map { !present.contains($0) } ?? true }
        try await TaskWriter(sync: self).adopt(fresh.map { exported in
            var todo = exported.todo
            todo.categoryID = todo.categoryID.flatMap { mapping[$0] }
            return (exported.uid ?? UUID().uuidString.lowercased(), todo)
        })
        return ImportReport(adopted: fresh.count, alreadyPresent: snapshot.todos.count - fresh.count,
                            categoriesCreated: created)
    }

    public func importData(_ data: Data) async throws -> ImportReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await importSnapshot(try decoder.decode(DatabaseExport.self, from: data))
    }

    // Empties this client: the journal's own tables and the engine's whole
    // local state, pending changes included. The server keeps everything.
    public func resetLocalData() async throws {
        try await writer.write { db in
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            try db.execute(sql: "DELETE FROM exportGroupMember")
            try db.execute(sql: "DELETE FROM exportGroup")
        }
        try await engine.wipe()
    }
}
