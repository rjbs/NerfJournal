import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

/// A todo in an export file, with its Task's uid.
///
/// In the file, the uid is one more property of the todo's own object.
public struct ExportedTodo: Codable, Sendable, Equatable {
    /// The Task's uid, or nil for a Task another client created without one.
    public var uid: String?

    /// The todo.
    public var todo: Todo

    /// Makes an exported todo from its parts.
    public init(uid: String?, todo: Todo) {
        self.uid = uid
        self.todo = todo
    }

    private enum CodingKeys: String, CodingKey { case uid }

    /// Decodes a todo, and its uid from the same object.
    public init(from decoder: Decoder) throws {
        todo = try Todo(from: decoder)
        uid = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(String.self, forKey: .uid)
    }

    /// Encodes the todo, with its uid in the same object.
    public func encode(to encoder: Encoder) throws {
        try todo.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(uid, forKey: .uid)
    }
}

/// What an import did.
public struct ImportReport: Sendable, Hashable {
    /// How many todos in the file became new Tasks.
    public var adopted: Int

    /// How many todos in the file were left alone, since a Task with their
    /// uid was already in the store.
    public var alreadyPresent: Int

    /// How many categories in the file became new TaskLists.
    public var categoriesCreated: Int

    /// Makes a report from its parts.
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
// afresh.
extension JournalSync {
    /// The whole journal, as it stands in this client, for an export file.
    ///
    /// Export groups are not included.
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

    /// The whole journal as an export file: the JSON of
    /// ``exportSnapshot()``, pretty-printed with sorted keys.
    public func exportData() async throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(try await exportSnapshot())
    }

    /// Imports an export, adding its todos to the store, and returns what it
    /// did.
    ///
    /// Each category in the file is matched by name to a category in the
    /// store, or else created.  Then the bundles and pages in the journal's
    /// own tables are replaced with those in the file, with the bundle
    /// todos' categories pointed at the matching ones, and every todo whose
    /// uid isn't already in the store is created there.  New lists must
    /// reach the server before todos can be filed in them, so the import
    /// syncs in the middle.
    ///
    /// A todo with no uid gets a fresh one, so importing it twice makes two
    /// of it.  That is the price of having nothing to match it on.  Nothing
    /// is ever destroyed on the server.
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

    /// Imports an export file.  See ``importSnapshot(_:)``.
    public func importData(_ data: Data) async throws -> ImportReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await importSnapshot(try decoder.decode(DatabaseExport.self, from: data))
    }

    /// Empties this client: the journal's own tables, and the engine's whole
    /// local state, including changes not yet sent.
    ///
    /// The server keeps everything, and the next sync fetches its lists and
    /// Tasks afresh.
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
