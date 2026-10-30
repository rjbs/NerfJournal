import ArgumentParser
import Foundation
import GRDB
import NerfCore

// Category moved into NerfCore, where it no longer shadows a same-named type in
// another imported module, so the bare name became ambiguous. The alias restores
// it for the CLI sources. -- claude, 2026-10-17
typealias Category = NerfCore.Category

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
    @Option(name: .long, help: "Override the default database path (also settable as NERF_DATABASE).")
    var database: String?

    // The installed app's database, unless NERF_DATABASE says otherwise. The
    // variable exists so a shell can be pointed at the dev build's container
    // (systems.semiotic.nerfjournal.dev) without passing --database to every command.
    // -- claude, 2026-10-28
    static func defaultPath() -> String {
        if let path = ProcessInfo.processInfo.environment["NERF_DATABASE"], !path.isEmpty {
            return path
        }
        let home = NSHomeDirectory()
        return "\(home)/Library/Containers/systems.semiotic.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite"
    }

    var path: String { database ?? Self.defaultPath() }

    // The preferences file of the app whose sandbox container holds the
    // database, so a database in the dev container reads the dev build's
    // settings. Nil for a database outside any container. The sandboxed
    // app's defaults domain cannot be read through UserDefaults from
    // outside the sandbox, hence the file. -- claude, 2026-10-30
    static func appPreferencesURL(forDatabaseAt path: String) -> URL? {
        let parts = URL(fileURLWithPath: path).pathComponents
        guard let i = parts.firstIndex(of: "Containers"), i + 2 < parts.count, parts[i + 2] == "Data" else {
            return nil
        }
        let container = URL(fileURLWithPath: "/").appending(path: parts[1...(i + 2)].joined(separator: "/"))
        return container.appending(path: "Library/Preferences/\(parts[i + 1]).plist")
    }

    func open() throws -> DatabaseQueue {
        var config = Configuration()
        config.busyMode = .timeout(5)
        do {
            return try DatabaseQueue(path: path, configuration: config)
        } catch {
            throw CLIError("could not open database at \(path): \(error)")
        }
    }

    // The database plus the sync engine over it, which is how todos are read
    // and written now. Server settings are the ones the app saved, so the
    // CLI follows the app's settings pane; NERF_JMAP_URL and
    // NERF_JMAP_ACCOUNT override them, and the prototype stands in when
    // there is nothing saved. Reads need no server; only a sync does.
    // -- claude, 2026-10-28; the saved settings 2026-10-30
    func openSync() throws -> JournalSync {
        let dbQueue = try open()
        let saved = Self.appPreferencesURL(forDatabaseAt: path)
            .flatMap { SyncSettings.from(preferencesAt: $0) } ?? .prototype
        do {
            return try JournalSync(
                writer: dbQueue,
                databasePath: path,
                settings: SyncSettings.from(environment: ProcessInfo.processInfo.environment, over: saved)
            )
        } catch {
            throw CLIError("could not set up sync for \(path): \(error)")
        }
    }
}
