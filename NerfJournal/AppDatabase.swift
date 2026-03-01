import Foundation
import GRDB

extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("org.rjbs.nerfjournal.databaseDidChange")
}

// Snapshot of the entire database, used for export and import.
struct DatabaseExport: Codable {
    let version: Int
    let exportedAt: Date
    let taskBundles: [TaskBundle]
    let bundleTodos: [BundleTodo]
    let journalPages: [JournalPage]
    let todos: [Todo]
    let notes: [Note]
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

        try migrator.migrate(db)
    }

    func exportData() async throws -> Data {
        let snapshot = try await dbQueue.read { db in
            DatabaseExport(
                version: 1,
                exportedAt: Date(),
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
            try JournalPage.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try TaskBundle.deleteAll(db)
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
            try JournalPage.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try TaskBundle.deleteAll(db)
            return
        }
    }
}
