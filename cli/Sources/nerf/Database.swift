import ArgumentParser
import Foundation
import GRDB

// MARK: - Model types (mirroring the app's Models.swift)

struct JournalPage: FetchableRecord, TableRecord, Decodable {
    var id: Int64?
    var date: CivilDate

    static let databaseTableName = "journalPage"
}

// TodoEnding is stored as a JSON string in SQLite (matching the app's Models.swift
// byte-for-byte). `day` is always present; `time` is a real moment when known.
struct TodoEnding: Codable, DatabaseValueConvertible, Hashable {
    enum Kind: String, Codable { case done, abandoned }
    var day: CivilDate
    var time: Moment?
    var kind: Kind

    init(day: CivilDate, time: Moment? = nil, kind: Kind) {
        self.day = day
        self.time = time
        self.kind = kind
    }

    init(moment: Moment, kind: Kind) {
        self.init(day: moment.civilDate, time: moment, kind: kind)
    }

    private enum CodingKeys: String, CodingKey { case day, time, kind }
    private enum LegacyKeys: String, CodingKey { case date, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let day = try c.decodeIfPresent(CivilDate.self, forKey: .day) {
            self.day = day
            self.time = try c.decodeIfPresent(Moment.self, forKey: .time)
            self.kind = try c.decode(Kind.self, forKey: .kind)
        } else {
            let lc = try decoder.container(keyedBy: LegacyKeys.self)
            let instant = try lc.decode(Date.self, forKey: .date)
            let split = LegacyEnding.classify(
                instant: instant, assuming: TimeZone(identifier: "America/New_York")!)
            self.day = split.day
            self.time = split.moment
            self.kind = try lc.decode(Kind.self, forKey: .kind)
        }
    }

    var databaseValue: DatabaseValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try! enc.encode(self)
        return String(data: data, encoding: .utf8)!.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TodoEnding? {
        guard let s = String.fromDatabaseValue(dbValue),
              let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TodoEnding.self, from: d)
    }
}

// GRDB's MutablePersistableRecord requires EncodableRecord, so encode(to:) is
// provided manually; FetchableRecord (below) adds the read side for `nerf todo`.
struct Todo: MutablePersistableRecord {
    var id: Int64?
    var title: String
    var shouldMigrate: Bool
    var start: CivilDate
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
