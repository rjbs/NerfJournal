import Foundation
import GRDB

extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("org.rjbs.nerfjournal.databaseDidChange")
}

// Snapshot of the entire database, used for export and import.
struct DatabaseExport: Codable {
    // version mirrors the DB schema version at export time. Not currently
    // consumed on import, but retained so future code can gate on it if
    // schema versions diverge. -- claude, 2026-03-02
    let version: Int
    // exportedAt is informational metadata in the JSON; not used by the
    // importer, but useful to a human inspecting an export file. -- claude, 2026-03-02
    let exportedAt: Date
    let categories: [Category]
    let taskBundles: [TaskBundle]
    let bundleTodos: [BundleTodo]
    let journalPages: [JournalPage]
    let todos: [Todo]
    let notes: [Note]

    init(version: Int, exportedAt: Date, categories: [Category], taskBundles: [TaskBundle],
         bundleTodos: [BundleTodo], journalPages: [JournalPage], todos: [Todo], notes: [Note]) {
        self.version      = version
        self.exportedAt   = exportedAt
        self.categories   = categories
        self.taskBundles  = taskBundles
        self.bundleTodos  = bundleTodos
        self.journalPages = journalPages
        self.todos        = todos
        self.notes        = notes
    }

    // Custom decoder so that imports of pre-v3 exports (lacking `categories`)
    // succeed with an empty category list rather than a decode error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version     = try c.decode(Int.self,           forKey: .version)
        exportedAt  = try c.decode(Date.self,          forKey: .exportedAt)
        categories  = try c.decodeIfPresent([Category].self,    forKey: .categories)  ?? []
        taskBundles = try c.decode([TaskBundle].self,  forKey: .taskBundles)
        bundleTodos = try c.decode([BundleTodo].self,  forKey: .bundleTodos)
        journalPages = try c.decode([JournalPage].self, forKey: .journalPages)
        todos       = try c.decode([Todo].self,        forKey: .todos)
        notes       = try c.decode([Note].self,        forKey: .notes)
    }
}

struct AppDatabase {
    let dbQueue: DatabaseQueue

    static let shared: AppDatabase = {
        let fm = FileManager.default
        let support = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("NerfJournal", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("journal.sqlite").path
        return try! AppDatabase(path: path)
    }()

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrate(dbQueue)
    }

    private func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "taskBundle") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("todosShouldMigrate", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "bundleTodo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleID", .integer).notNull()
                    .references("taskBundle", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("externalURL", .text)
            }

            try db.create(table: "journalPage") { t in
                t.autoIncrementedPrimaryKey("id")
                // Stored as start-of-day in the local timezone; must be normalized
                // before insert to ensure the unique constraint behaves correctly.
                t.column("date", .datetime).notNull().unique()
            }

            try db.create(table: "todo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pageID", .integer).notNull()
                    .references("journalPage", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("shouldMigrate", .boolean).notNull().defaults(to: true)
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("groupName", .text)
                t.column("externalURL", .text)
                t.column("firstAddedDate", .datetime).notNull()
            }

            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pageID", .integer).notNull()
                    .references("journalPage", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull()
                t.column("text", .text)
                t.column("relatedTodoID", .integer)
                    .references("todo", onDelete: .setNull)
            }
        }

        migrator.registerMigration("v2") { db in
            // GRDB defers FK checks during migrations, so cascade actions
            // don't fire. Delete in dependency order so FK checks pass at
            // commit: note first (references both todo and journalPage),
            // then todo (references journalPage), then journalPage.
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM todo")
            try db.execute(sql: "DELETE FROM journalPage")
            try db.execute(sql: "DROP TABLE todo")
            try db.create(table: "todo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("shouldMigrate", .boolean).notNull().defaults(to: true)
                // Start-of-day timestamp for the day the todo was first created.
                t.column("added", .datetime).notNull()
                // JSON-encoded TodoEnding; NULL means still pending.
                t.column("ending", .text)
                t.column("groupName", .text)
                t.column("externalURL", .text)
            }
        }

        migrator.registerMigration("v3") { db in
            // Wipe in FK-dependency order (children first).
            try db.execute(sql: "DELETE FROM note")
            try db.execute(sql: "DELETE FROM todo")
            try db.execute(sql: "DELETE FROM bundleTodo")
            try db.execute(sql: "DELETE FROM journalPage")
            try db.execute(sql: "DELETE FROM taskBundle")
            try db.execute(sql: "DROP TABLE note")
            try db.execute(sql: "DROP TABLE todo")
            try db.execute(sql: "DROP TABLE bundleTodo")
            try db.execute(sql: "DROP TABLE journalPage")
            try db.execute(sql: "DROP TABLE taskBundle")

            // category is new; todo loses groupName and gains categoryID;
            // bundleTodo gains categoryID.
            try db.create(table: "category") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("color", .text).notNull().defaults(to: "blue")
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "taskBundle") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("todosShouldMigrate", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "bundleTodo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleID", .integer).notNull()
                    .references("taskBundle", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("externalURL", .text)
                t.column("categoryID", .integer)
                    .references("category", onDelete: .setNull)
            }

            try db.create(table: "journalPage") { t in
                t.autoIncrementedPrimaryKey("id")
                // Stored as start-of-day in the local timezone; must be normalized
                // before insert to ensure the unique constraint behaves correctly.
                t.column("date", .datetime).notNull().unique()
            }

            try db.create(table: "todo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("shouldMigrate", .boolean).notNull().defaults(to: true)
                // Start-of-day timestamp for the day the todo was first created.
                t.column("added", .datetime).notNull()
                // JSON-encoded TodoEnding; NULL means still pending.
                t.column("ending", .text)
                t.column("categoryID", .integer)
                    .references("category", onDelete: .setNull)
                t.column("externalURL", .text)
            }

            try db.create(table: "note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("pageID", .integer).notNull()
                    .references("journalPage", onDelete: .cascade)
                t.column("timestamp", .datetime).notNull()
                t.column("text", .text)
                t.column("relatedTodoID", .integer)
                    .references("todo", onDelete: .setNull)
            }
        }

        migrator.registerMigration("v4") { db in
            // relatedTodoID was never wired up (addNote was never called with a
            // todo argument). All existing rows have NULL; drop the column.
            try db.execute(sql: "ALTER TABLE note DROP COLUMN relatedTodoID")
        }

        migrator.registerMigration("v5") { db in
            try db.execute(sql: "ALTER TABLE todo RENAME COLUMN added TO start")
        }

        try migrator.migrate(db)
    }

    func exportData() async throws -> Data {
        let snapshot = try await dbQueue.read { db in
            DatabaseExport(
                version: 5,
                exportedAt: Date(),
                categories: try Category.order(Column("sortOrder")).fetchAll(db),
                taskBundles: try TaskBundle.order(Column("id")).fetchAll(db),
                bundleTodos: try BundleTodo.order(Column("id")).fetchAll(db),
                journalPages: try JournalPage.order(Column("date")).fetchAll(db),
                todos: try Todo.order(Column("id")).fetchAll(db),
                notes: try Note.order(Column("id")).fetchAll(db)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    // Replaces all data with the contents of the export. The entire operation
    // runs in one transaction, so a malformed import leaves the database unchanged.
    func importData(_ data: Data) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DatabaseExport.self, from: data)
        try await dbQueue.write { db in
            try Note.deleteAll(db)
            try Todo.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            try Category.deleteAll(db)
            for var r in snapshot.categories   { try r.insert(db) }
            for var r in snapshot.taskBundles  { try r.insert(db) }
            for var r in snapshot.bundleTodos  { try r.insert(db) }
            for var r in snapshot.journalPages { try r.insert(db) }
            for var r in snapshot.todos        { try r.insert(db) }
            for var r in snapshot.notes        { try r.insert(db) }
        }
    }

    func factoryReset() async throws {
        try await dbQueue.write { db in
            try Note.deleteAll(db)
            try Todo.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            try Category.deleteAll(db)
            return
        }
    }
}
