import Foundation
import GRDB

// NOTE: Named TaskBundle rather than Bundle to avoid shadowing Foundation.Bundle.
struct TaskBundle: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int
    var todosShouldMigrate: Bool

    static let databaseTableName = "taskBundle"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct BundleTodo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var bundleID: Int64
    var title: String
    var sortOrder: Int
    var externalURL: String?

    static let databaseTableName = "bundleTodo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct JournalPage: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var date: Date

    static let databaseTableName = "journalPage"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

enum TodoStatus: String, Codable, DatabaseValueConvertible {
    case pending, done, abandoned, migrated

    var databaseValue: DatabaseValue { rawValue.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TodoStatus? {
        String.fromDatabaseValue(dbValue).flatMap(Self.init(rawValue:))
    }
}

struct Todo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var pageID: Int64
    var title: String
    var shouldMigrate: Bool
    var status: TodoStatus
    var sortOrder: Int
    var groupName: String?
    var externalURL: String?
    var firstAddedDate: Date

    static let databaseTableName = "todo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct Note: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var pageID: Int64
    var timestamp: Date
    var text: String?
    var relatedTodoID: Int64?

    static let databaseTableName = "note"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
