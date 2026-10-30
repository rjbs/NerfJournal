import Foundation
import GRDB
import JinxStore

// The journal's SQLite schema. Todos and categories live on the JMAP
// server, held locally in the sync engine's own tables; these are the
// client-only tables beside them. The app runs this at launch; the CLI
// assumes it has run.
public enum NerfSchema {
    // The export file format version, recorded in each export. Bump when
    // the export shape changes.
    public static let currentVersion = 10

    public static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("schema") { db in
            try db.create(table: "taskBundle") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("todosShouldMigrate", .boolean).notNull().defaults(to: true)
            }

            // categoryID is a sync-engine local key for a TaskList, so no
            // foreign key: CategoryWriter.delete clears it.
            try db.create(table: "bundleTodo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleID", .integer).notNull()
                    .references("taskBundle", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("externalURL", .text)
                t.column("categoryID", .integer)
            }

            try db.create(table: "journalPage") { t in
                t.autoIncrementedPrimaryKey("id")
                // A civil date, "YYYY-MM-DD".
                t.column("date", .text).notNull().unique()
            }

            try db.create(table: "exportGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // NULL categoryID represents uncategorized ("Other") todos.
            try db.create(table: "exportGroupMember") { t in
                t.column("groupID", .integer).notNull()
                    .references("exportGroup", onDelete: .cascade)
                t.column("categoryID", .integer)
            }
        }

        // The sync engine's own tables (jinx_object, jinx_pending, ...) live
        // in the same file as the journal, so one migrator owns both. Jinx's
        // migrations go last so that any later journal migration can still be
        // slotted in before them. -- claude, 2026-10-28
        GRDBSyncStore.registerMigrations(in: &migrator)

        try migrator.migrate(db)
    }
}
