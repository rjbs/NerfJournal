import Foundation
import GRDB

// MARK: - Minimal model types (mirroring the app's Models.swift)

struct JournalPage: FetchableRecord, TableRecord, Decodable {
    var id: Int64?
    var date: Date

    static let databaseTableName = "journalPage"
}

// TodoEnding is stored as a JSON string in SQLite (matching the app exactly).
struct TodoEnding: DatabaseValueConvertible {
    enum Kind: String, Codable { case done, abandoned }
    var date: Date
    var kind: Kind

    var databaseValue: DatabaseValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try! enc.encode(Coded(date: date, kind: kind))
        return String(data: data, encoding: .utf8)!.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TodoEnding? {
        guard let s = String.fromDatabaseValue(dbValue),
              let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let coded = try? dec.decode(Coded.self, from: d) else { return nil }
        return TodoEnding(date: coded.date, kind: coded.kind)
    }

    private struct Coded: Codable {
        var date: Date
        var kind: Kind
    }
}

// Todo only needs to be inserted (not read), but GRDB's MutablePersistableRecord
// requires EncodableRecord, so encode(to:) is provided manually.
struct Todo: MutablePersistableRecord {
    var id: Int64?
    var title: String
    var shouldMigrate: Bool
    var start: Date
    var ending: TodoEnding?
    var categoryID: Int64?
    var externalURL: String?

    static let databaseTableName = "todo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"]            = id
        container["title"]         = title
        container["shouldMigrate"] = shouldMigrate
        container["start"]         = start
        container["ending"]        = ending
        container["categoryID"]    = categoryID
        container["externalURL"]   = externalURL
    }
}

struct Category: FetchableRecord, TableRecord, Decodable {
    var id: Int64?
    var name: String

    static let databaseTableName = "category"
}

// MARK: - Argument parsing

struct Args {
    var title: String
    var shouldMigrate: Bool = true
    var categoryName: String? = nil
    var externalURL: String? = nil
    var databasePath: String? = nil
}

func printUsage() {
    fputs("""
    Usage: nerf-add-todo [--no-migrate] [--category NAME] [--url URL] [--database PATH] TITLE...

    Adds a todo to today's NerfJournal page.

    Options:
      --no-migrate      Mark the todo as non-migratable (default: migratable)
      --category NAME   Assign to the named category (warn and continue if not found)
      --url URL         Set an external URL on the todo
      --database PATH   Override the default database path (for testing)

    The todo title is formed by joining all remaining positional arguments.

    """, stderr)
}

func parseArgs(_ argv: [String]) -> Args? {
    var args = Args(title: "")
    var remaining = argv.dropFirst()  // drop program name
    var titleWords: [String] = []

    while let arg = remaining.first {
        remaining = remaining.dropFirst()
        switch arg {
        case "--help", "-h":
            return nil
        case "--no-migrate":
            args.shouldMigrate = false
        case "--category":
            guard let val = remaining.first else {
                fputs("error: --category requires a value\n", stderr)
                return nil
            }
            remaining = remaining.dropFirst()
            args.categoryName = val
        case "--url":
            guard let val = remaining.first else {
                fputs("error: --url requires a value\n", stderr)
                return nil
            }
            remaining = remaining.dropFirst()
            args.externalURL = val
        case "--database":
            guard let val = remaining.first else {
                fputs("error: --database requires a value\n", stderr)
                return nil
            }
            remaining = remaining.dropFirst()
            args.databasePath = val
        default:
            if arg.hasPrefix("--") {
                fputs("error: unknown option: \(arg)\n", stderr)
                return nil
            }
            titleWords.append(arg)
        }
    }

    let title = titleWords.joined(separator: " ")
    guard !title.isEmpty else {
        fputs("error: todo title is required\n", stderr)
        return nil
    }
    args.title = title
    return args
}

// MARK: - Database path

func defaultDatabasePath() -> String {
    let home = NSHomeDirectory()
    return "\(home)/Library/Containers/org.rjbs.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite"
}

// MARK: - Main

guard let args = parseArgs(CommandLine.arguments) else {
    printUsage()
    exit(1)
}

let dbPath = args.databasePath ?? defaultDatabasePath()

let dbQueue: DatabaseQueue
do {
    var config = Configuration()
    config.busyMode = .timeout(5)
    dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
} catch {
    fputs("error: could not open database at \(dbPath): \(error)\n", stderr)
    exit(1)
}

let today = Calendar.current.startOfDay(for: Date())

// Find today's page.
let todayPage: JournalPage?
do {
    todayPage = try dbQueue.read { db in
        try JournalPage
            .filter(Column("date") == today)
            .fetchOne(db)
    }
} catch {
    fputs("error: could not query journal pages: \(error)\n", stderr)
    exit(1)
}

guard todayPage != nil else {
    fputs("error: no journal page for today — start one in NerfJournal first\n", stderr)
    exit(1)
}

// Resolve category, if requested.
var categoryID: Int64? = nil
if let name = args.categoryName {
    do {
        let categories = try dbQueue.read { db in try Category.fetchAll(db) }
        if let match = categories.first(where: { $0.name.lowercased() == name.lowercased() }) {
            categoryID = match.id
        } else {
            fputs("warning: category \"\(name)\" not found — adding todo without category\n", stderr)
        }
    } catch {
        fputs("warning: could not query categories: \(error) — adding todo without category\n", stderr)
    }
}

// Check for duplicates: skip if any open (ending IS NULL) todo has the same title or URL.
struct DuplicateFound {
    var field: String
    var value: String
}

let duplicate: DuplicateFound?
do {
    duplicate = try dbQueue.read { db -> DuplicateFound? in
        let titleDup = try Row.fetchOne(
            db,
            sql: "SELECT 1 FROM todo WHERE ending IS NULL AND title = ?",
            arguments: [args.title]
        )
        if titleDup != nil {
            return DuplicateFound(field: "title", value: args.title)
        }
        if let url = args.externalURL {
            let urlDup = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM todo WHERE ending IS NULL AND externalURL = ?",
                arguments: [url]
            )
            if urlDup != nil {
                return DuplicateFound(field: "url", value: url)
            }
        }
        return nil
    }
} catch {
    fputs("warning: could not check for duplicates: \(error)\n", stderr)
    duplicate = nil
}

if let dup = duplicate {
    print("Didn't create todo for duplicate \(dup.field): \(dup.value)")
    exit(0)
}

// Insert the todo.
do {
    try dbQueue.write { db in
        var todo = Todo(
            id: nil,
            title: args.title,
            shouldMigrate: args.shouldMigrate,
            start: today,
            ending: nil,
            categoryID: categoryID,
            externalURL: args.externalURL
        )
        try todo.insert(db)
    }
} catch {
    fputs("error: could not insert todo: \(error)\n", stderr)
    exit(1)
}

// Notify any running NerfJournal instance to refresh.
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
    object: nil,
    deliverImmediately: true
)

exit(0)
