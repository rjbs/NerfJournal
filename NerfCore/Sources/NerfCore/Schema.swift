import Foundation
import GRDB
import JinxStore

// The journal's SQLite schema, as the ordered list of GRDB migrations that
// produce it. The app runs these at launch; the CLI assumes they have run.
public enum NerfSchema {
    // The schema version an export file records. Bump alongside a new migration.
    public static let currentVersion = 8

    public static func migrate(_ db: DatabaseQueue) throws {
        try migrate(db, upTo: nil)
    }

    // Stops after the named migration, for tests that need a database in an
    // older shape. -- claude, 2026-10-28
    public static func migrate(_ db: DatabaseQueue, upTo lastIdentifier: String?) throws {
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
            // GRDB runs migrations with foreign keys off (the default
            // foreignKeyChecks: .deferred) and does a single foreign_key_check
            // at commit. Because this wipes every related table, that check
            // sees an empty database no matter what order we delete in — so the
            // children-first ordering here is defensive habit, not a
            // requirement, and cascades wouldn't fire even if we relied on them.
            // -- claude, 2026-06-13
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
            // Wipe everything. As in v2, foreign keys are off during the
            // migration, so the children-first order here is defensive, not
            // required. -- claude, 2026-06-13
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

        migrator.registerMigration("v6") { db in
            try db.create(table: "exportGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "exportGroupMember") { t in
                t.column("groupID", .integer).notNull()
                    .references("exportGroup", onDelete: .cascade)
                // NULL categoryID represents uncategorized ("Other") todos.
                t.column("categoryID", .integer)
                    .references("category", onDelete: .cascade)
            }
        }

        migrator.registerMigration("v7") { db in
            // Notes are gone. Each text-bearing note becomes a todo that was
            // born already done: start = its page's date, ending = (its
            // timestamp, .done). Notes with NULL text were never shown, so
            // they're discarded. This writes the *legacy* instant-based row
            // format (datetime start, {date,kind} ending JSON) via raw SQL, so
            // that v8's one-shot instant→civil-date conversion sees uniform data
            // rather than a mix of old and new shapes. -- claude, 2026-07-25
            struct LegacyEndingRow: Encodable { let date: Date; let kind: String }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.date AS date, n.timestamp AS timestamp, n.text AS text
                FROM note n JOIN journalPage p ON n.pageID = p.id
                WHERE n.text IS NOT NULL
                """)
            for row in rows {
                let date: Date = row["date"]
                let timestamp: Date = row["timestamp"]
                let text: String = row["text"]
                let endingData = try enc.encode(LegacyEndingRow(date: timestamp, kind: "done"))
                let endingJSON = String(data: endingData, encoding: .utf8)!
                try db.execute(sql: """
                    INSERT INTO todo (title, shouldMigrate, start, ending)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [text, false, date, endingJSON])
            }
            try db.execute(sql: "DROP TABLE note")
        }

        // Civil dates land. journalPage.date and todo.start were instants stored
        // at the writing zone's local midnight; endings were a single instant.
        // Interpreting everything in the only zone this data was ever written in —
        // America/New_York — we rebuild both tables with TEXT day anchors and
        // convert each ending to the day-or-moment shape (the noon / 23:59:59
        // sentinels collapse to day-only; real completions keep their instant and
        // offset — see LegacyEnding). -- claude, 2026-07-25
        migrator.registerMigration("v8") { db in
            let ny = TimeZone(identifier: "America/New_York")!

            try db.create(table: "journalPage_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("date", .text).notNull().unique()
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, date FROM journalPage") {
                let id: Int64 = row["id"]
                let instant: Date = row["date"]
                try db.execute(
                    sql: "INSERT INTO journalPage_new (id, date) VALUES (?, ?)",
                    arguments: [id, CivilDate(instant: instant, in: ny)])
            }
            try db.execute(sql: "DROP TABLE journalPage")
            try db.execute(sql: "ALTER TABLE journalPage_new RENAME TO journalPage")

            try db.create(table: "todo_new") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("shouldMigrate", .boolean).notNull().defaults(to: true)
                // Civil date "YYYY-MM-DD": the first day the todo appears.
                t.column("start", .text).notNull()
                // JSON-encoded TodoEnding (day + optional moment); NULL = pending.
                t.column("ending", .text)
                t.column("categoryID", .integer)
                    .references("category", onDelete: .setNull)
                t.column("externalURL", .text)
            }
            let todoRows = try Row.fetchAll(db, sql: """
                SELECT id, title, shouldMigrate, start, ending, categoryID, externalURL FROM todo
                """)
            for row in todoRows {
                let id: Int64 = row["id"]
                let title: String = row["title"]
                let shouldMigrate: Bool = row["shouldMigrate"]
                let startInstant: Date = row["start"]
                let categoryID: Int64? = row["categoryID"]
                let externalURL: String? = row["externalURL"]
                // The legacy ending JSON decodes straight into the new shape via
                // TodoEnding's lenient decoder, which interprets its instant in
                // New York; re-binding re-encodes it in the new form.
                let ending: TodoEnding? = row["ending"]
                try db.execute(sql: """
                    INSERT INTO todo_new (id, title, shouldMigrate, start, ending, categoryID, externalURL)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        id, title, shouldMigrate,
                        CivilDate(instant: startInstant, in: ny),
                        ending, categoryID, externalURL,
                    ])
            }
            try db.execute(sql: "DROP TABLE todo")
            try db.execute(sql: "ALTER TABLE todo_new RENAME TO todo")
        }

        // Todos move to the JMAP server, by way of the sync engine's tables.
        // This migration only stages them: each row gets the uid it will
        // carry as a Task, and the table steps aside as todo_legacy so that
        // nothing reads it as live data. JournalSync.adoptLegacyTodos then
        // turns the rows into pending creates and drops the table, keyed by
        // uid so a launch that dies partway is harmless. -- claude, 2026-10-28
        migrator.registerMigration("v9") { db in
            try db.create(table: "todo_legacy") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("shouldMigrate", .boolean).notNull().defaults(to: true)
                t.column("start", .text).notNull()
                t.column("ending", .text)
                t.column("categoryID", .integer)
                t.column("externalURL", .text)
                t.column("uid", .text).notNull().unique()
            }
            for id in try Int64.fetchAll(db, sql: "SELECT id FROM todo ORDER BY id") {
                try db.execute(sql: """
                    INSERT INTO todo_legacy (id, title, shouldMigrate, start, ending, categoryID, externalURL, uid)
                    SELECT id, title, shouldMigrate, start, ending, categoryID, externalURL, ? FROM todo WHERE id = ?
                    """, arguments: [UUID().uuidString.lowercased(), id])
            }
            try db.execute(sql: "DROP TABLE todo")
        }

        // The sync engine's own tables (jinx_object, jinx_pending, ...) live
        // in the same file as the journal, so one migrator owns both. Jinx's
        // migrations go last so that any later journal migration can still be
        // slotted in before them. -- claude, 2026-10-28
        GRDBSyncStore.registerMigrations(in: &migrator)

        if let lastIdentifier {
            try migrator.migrate(db, upTo: lastIdentifier)
        } else {
            try migrator.migrate(db)
        }
    }
}
