import CryptoKit
import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore
import JinxTypes
import JinxWire

/// Where the journal's Tasks live: a JMAP server and an account on it.
///
/// The app reads these from its defaults, and the CLI from the app's
/// preferences file and then the environment.  Each starts from
/// ``prototype``.
public struct SyncSettings: Sendable, Hashable {
    /// The URL of the server's JMAP session resource.
    public var sessionURL: URL

    /// The id of the account the journal is kept in.
    public var accountId: String

    /// Makes settings from their parts.
    public init(sessionURL: URL, accountId: String) {
        self.sessionURL = sessionURL
        self.accountId = accountId
    }

    /// The settings to use when nothing else says: a server on this
    /// machine, at port 8080.
    public static let prototype = SyncSettings(
        sessionURL: URL(string: "http://127.0.0.1:8080/.well-known/jmap")!,
        accountId: "rjbs"
    )

    /// The defaults key for ``sessionURL``.
    public static let sessionURLDefaultsKey = "jmapSessionURL"

    /// The defaults key for ``accountId``.
    public static let accountIdDefaultsKey = "jmapAccountId"

    /// The environment variable for ``sessionURL``.
    public static let sessionURLEnvironmentKey = "NERF_JMAP_URL"

    /// The environment variable for ``accountId``.
    public static let accountIdEnvironmentKey = "NERF_JMAP_ACCOUNT"

    /// The settings in `defaults`, over those in `base`.
    ///
    /// Each of the `from` methods reads settings from one source, and a
    /// setting that is absent or unusable there leaves the one in `base`
    /// standing.  So they can be layered, each over the last.
    public static func from(_ defaults: UserDefaults, over base: SyncSettings = .prototype) -> SyncSettings {
        from(values: [
            sessionURLDefaultsKey: defaults.string(forKey: sessionURLDefaultsKey),
            accountIdDefaultsKey: defaults.string(forKey: accountIdDefaultsKey),
        ], over: base)
    }

    /// The settings in the preferences file at `url`, over those in `base`,
    /// or nil if there is no property list there to read.
    ///
    /// This is how the CLI reads the app's settings, since the app is
    /// sandboxed, and its defaults can't be read by `UserDefaults` from
    /// outside the sandbox.  See ``from(_:over:)``.
    public static func from(preferencesAt url: URL, over base: SyncSettings = .prototype) -> SyncSettings? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any]
        else { return nil }
        return from(values: [
            sessionURLDefaultsKey: values[sessionURLDefaultsKey] as? String,
            accountIdDefaultsKey: values[accountIdDefaultsKey] as? String,
        ], over: base)
    }

    /// The settings in `environment`, over those in `base`.  See
    /// ``from(_:over:)``.
    public static func from(environment: [String: String], over base: SyncSettings = .prototype) -> SyncSettings {
        from(values: [
            sessionURLDefaultsKey: environment[sessionURLEnvironmentKey],
            accountIdDefaultsKey: environment[accountIdEnvironmentKey],
        ], over: base)
    }

    private static func from(values: [String: String?], over base: SyncSettings) -> SyncSettings {
        var settings = base
        if let s = values[sessionURLDefaultsKey] ?? nil, let url = URL(string: s) {
            settings.sessionURL = url
        }
        if let account = values[accountIdDefaultsKey] ?? nil, !account.isEmpty {
            settings.accountId = account
        }
        return settings
    }
}

/// An error in writing the journal to the sync engine.
public enum JournalSyncError: Error, CustomStringConvertible, Sendable {
    /// The account has no TaskList, so there is nowhere to create a Task.
    case noTaskList

    /// The list of the category with this name hasn't reached the server,
    /// so no Task can be filed in it yet.
    case categoryNotSynced(String)

    /// The error in words, for a person.
    public var description: String {
        switch self {
        case .noTaskList: "the account has no task list"
        case .categoryNotSynced(let name): "the category \"\(name)\" has not reached the server yet"
        }
    }
}

/// The journal's sync engine, put together the one way that the app and
/// the CLI both need.
///
/// Its store is Jinx's GRDB store, inside the journal's database, and it
/// syncs TaskLists and Tasks, with the Task type owning exactly the
/// properties ``TaskCodec`` writes.  Every process using the same database
/// file signals the others with the same Darwin notification name, made
/// from the file's path, so each learns of the others' changes.
///
/// Todos are read and written with ``TaskReader`` and ``TaskWriter``, and
/// categories with ``CategoryWriter``.
public actor JournalSync {
    /// The type of the sync engine.
    public typealias Engine = SyncEngine<GRDBSyncStore>

    /// The Task type, owning ``TaskCodec/ownedProperties``.
    public static let taskType = TaskTypes.task(ownedProperties: TaskCodec.ownedProperties)

    /// The TaskList type.
    public static let listType = TaskTypes.taskList

    /// The types the engine syncs, lists first.
    public static let types = [listType, taskType]

    /// The sync engine.
    public nonisolated let engine: Engine

    /// Where the engine syncs to.
    public nonisolated let settings: SyncSettings
    nonisolated let writer: any DatabaseWriter
    private var fetchedListsOnce = false

    /// Makes the engine as the app and the CLI use it, syncing over HTTP to
    /// the server in `settings`.
    ///
    /// `databasePath` is the path of the database file that `writer`
    /// writes, from which the notification name is made.
    public init(writer: any DatabaseWriter, databasePath: String, settings: SyncSettings) throws {
        try self.init(
            writer: writer,
            settings: settings,
            transport: JMAPClient(sessionUrl: settings.sessionURL, authenticator: NoAuthentication()),
            signalName: Self.signalName(forDatabaseAt: databasePath)
        )
    }

    /// Makes the engine with the transport supplied, as for tests against a
    /// scripted server.
    ///
    /// With a nil `signalName`, other processes are neither signaled nor
    /// listened to.
    public init(writer: any DatabaseWriter, settings: SyncSettings, transport: any JMAPTransport, signalName: String?) throws {
        self.settings = settings
        self.writer = writer
        let configuration = SyncConfiguration(
            accountId: settings.accountId,
            types: Self.types,
            signalName: signalName
        )
        self.engine = try Engine(configuration: configuration, transport: transport, store: GRDBSyncStore(writer: writer))
    }

    /// The notification name for the database file at `path`, which no
    /// other database's processes will use.
    ///
    /// It is made from a digest of the path, since the name must be a short
    /// plain token.
    public static func signalName(forDatabaseAt path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "systems.semiotic.nerfjournal.jinx.\(hex)"
    }

    // MARK: - Lists

    /// An index of the TaskLists in the store.
    ///
    /// If the store has none, the engine syncs once, the first time this is
    /// called, to fetch them, so that a new client can file its first Task.
    /// After that, the lists are whatever the store holds, and the engine's
    /// own syncing keeps them current.
    public func listIndex() async throws -> TaskListIndex {
        var index = TaskListIndex(objects: try await lists())
        if index.entries.isEmpty, !fetchedListsOnce {
            fetchedListsOnce = true
            try await engine.sync()
            index = TaskListIndex(objects: try await lists())
        }
        return index
    }

    /// The JMAP id of the list that Tasks with no category go into.
    ///
    /// If there is none, the error is ``JournalSyncError/noTaskList``.
    public func defaultListId() async throws -> String {
        guard let id = try await listIndex().defaultListId else { throw JournalSyncError.noTaskList }
        return id
    }

    /// The categories, which are the lists other than the default, in
    /// display order.
    public func categories() async throws -> [Category] {
        try await listIndex().categories
    }

    // MARK: - Convenience

    /// Every TaskList in the store, in local key order.
    public func lists() async throws -> [SyncedObject] {
        try await engine.objects(type: Self.listType.name)
    }

    /// Every Task in the store, in local key order.
    public func tasks() async throws -> [SyncedObject] {
        try await engine.objects(type: Self.taskType.name)
    }

    /// The state of the engine's syncing.
    public func status() async throws -> SyncStatus {
        try await engine.currentStatus()
    }
}
