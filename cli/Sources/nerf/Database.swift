import ArgumentParser
import Foundation
import GRDB

// MARK: - Model types (mirroring the app's Models.swift)

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

// GRDB's MutablePersistableRecord requires EncodableRecord, so encode(to:) is
// provided manually; FetchableRecord (below) adds the read side for `nerf todo`.
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

extension Todo: FetchableRecord {
    init(row: Row) {
        id            = row["id"]
        title         = row["title"]
        shouldMigrate = row["shouldMigrate"]
        start         = row["start"]
        ending        = row["ending"]
        categoryID    = row["categoryID"]
        externalURL   = row["externalURL"]
    }
}

struct Category: FetchableRecord, TableRecord, Decodable {
    var id: Int64?
    var name: String
    var color: String
    var sortOrder: Int

    static let databaseTableName = "category"
}

// MARK: - Errors

// A runtime failure with a message suitable for the user. ArgumentParser prints
// the description and exits non-zero when a command's run() throws.
struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

// MARK: - Shared options

// Mixed into each subcommand via @OptionGroup so they all accept --database.
struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "Override the default database path (for testing).")
    var database: String?

    static func defaultPath() -> String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Containers/org.rjbs.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite"
    }

    func open() throws -> DatabaseQueue {
        let path = database ?? Self.defaultPath()
        var config = Configuration()
        config.busyMode = .timeout(5)
        do {
            return try DatabaseQueue(path: path, configuration: config)
        } catch {
            throw CLIError("could not open database at \(path): \(error)")
        }
    }
}

// MARK: - Change notification

// Notify any running NerfJournal instance to refresh after a write.
func postExternalChangeNotification() {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
        object: nil,
        deliverImmediately: true
    )
}
