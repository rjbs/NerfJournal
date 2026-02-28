import Foundation
import GRDB

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
}
