import CryptoKit
import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore
import JinxTypes
import JinxWire

// Where the journal's Tasks live. The app reads this from UserDefaults and
// the CLI from the environment; both default to the prototype server.
public struct SyncSettings: Sendable, Hashable {
    public var sessionURL: URL
    public var accountId: String

    public init(sessionURL: URL, accountId: String) {
        self.sessionURL = sessionURL
        self.accountId = accountId
    }

    public static let prototype = SyncSettings(
        sessionURL: URL(string: "http://127.0.0.1:8080/.well-known/jmap")!,
        accountId: "rjbs"
    )

    public static let sessionURLDefaultsKey = "jmapSessionURL"
    public static let accountIdDefaultsKey = "jmapAccountId"
    public static let sessionURLEnvironmentKey = "NERF_JMAP_URL"
    public static let accountIdEnvironmentKey = "NERF_JMAP_ACCOUNT"

    public static func from(_ defaults: UserDefaults) -> SyncSettings {
        var settings = prototype
        if let s = defaults.string(forKey: sessionURLDefaultsKey), let url = URL(string: s) {
            settings.sessionURL = url
        }
        if let account = defaults.string(forKey: accountIdDefaultsKey), !account.isEmpty {
            settings.accountId = account
        }
        return settings
    }

    public static func from(environment: [String: String]) -> SyncSettings {
        var settings = prototype
        if let s = environment[sessionURLEnvironmentKey], let url = URL(string: s) {
            settings.sessionURL = url
        }
        if let account = environment[accountIdEnvironmentKey], !account.isEmpty {
            settings.accountId = account
        }
        return settings
    }
}

public enum JournalSyncError: Error, CustomStringConvertible, Sendable {
    // The account has no TaskList, so there is nowhere to create a Task.
    case noTaskList

    public var description: String {
        switch self {
        case .noTaskList: "the account has no task list"
        }
    }
}

// The journal's sync engine, assembled the one way the app and the CLI both
// need: Jinx's GRDB store inside the journal database, the TaskList and
// Task types, and the Task type owning exactly the properties TaskCodec
// writes. Every process on the same database file uses the same Darwin
// notification name, derived from the path, so each learns of the others'
// commits. -- claude, 2026-10-28
public actor JournalSync {
    public typealias Engine = SyncEngine<GRDBSyncStore>

    public static let taskType = TaskTypes.task(ownedProperties: TaskCodec.ownedProperties)
    public static let types = [TaskTypes.taskList, taskType]

    public nonisolated let engine: Engine
    public nonisolated let settings: SyncSettings
    private var cachedTaskListId: String?

    // The production wiring: an HTTP client against `settings`, signalled
    // to other processes on `databasePath`.
    public init(writer: any DatabaseWriter, databasePath: String, settings: SyncSettings) throws {
        try self.init(
            writer: writer,
            settings: settings,
            transport: JMAPClient(sessionUrl: settings.sessionURL, authenticator: NoAuthentication()),
            signalName: Self.signalName(forDatabaseAt: databasePath)
        )
    }

    // The wiring with the transport supplied, for tests against a scripted
    // server. A nil signal name disables cross-process notification.
    public init(writer: any DatabaseWriter, settings: SyncSettings, transport: any JMAPTransport, signalName: String?) throws {
        self.settings = settings
        let configuration = SyncConfiguration(
            accountId: settings.accountId,
            types: Self.types,
            signalName: signalName
        )
        self.engine = try Engine(configuration: configuration, transport: transport, store: GRDBSyncStore(writer: writer))
    }

    // A notification name no other database's processes will use. The
    // path's digest rather than the path itself, since the name must be a
    // short plain token.
    public static func signalName(forDatabaseAt path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "org.rjbs.nerfjournal.jinx.\(hex)"
    }

    // The id of the TaskList new Tasks go into, read from the store once and
    // kept. The first call on a fresh store syncs to fetch the lists.
    public func taskListId() async throws -> String {
        if let cachedTaskListId { return cachedTaskListId }
        if let id = try await storedTaskListId() {
            cachedTaskListId = id
            return id
        }
        try await engine.sync()
        guard let id = try await storedTaskListId() else { throw JournalSyncError.noTaskList }
        cachedTaskListId = id
        return id
    }

    private func storedTaskListId() async throws -> String? {
        try await engine.objects(type: TaskTypes.taskList.name).compactMap(\.id).first
    }

    // MARK: - Convenience

    // Every Task in the store, in local key order.
    public func tasks() async throws -> [SyncedObject] {
        try await engine.objects(type: Self.taskType.name)
    }

    public func status() async throws -> SyncStatus {
        try await engine.currentStatus()
    }
}
