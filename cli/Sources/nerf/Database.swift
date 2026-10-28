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
    // (org.rjbs.nerfjournal.dev) without passing --database to every command.
    // -- claude, 2026-10-28
    static func defaultPath() -> String {
        if let path = ProcessInfo.processInfo.environment["NERF_DATABASE"], !path.isEmpty {
            return path
        }
        let home = NSHomeDirectory()
        return "\(home)/Library/Containers/org.rjbs.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite"
    }

    var path: String { database ?? Self.defaultPath() }

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
    // and written now. Server settings come from NERF_JMAP_URL and
    // NERF_JMAP_ACCOUNT, defaulting to the prototype. Reads need no server;
    // only a sync does. -- claude, 2026-10-28
    func openSync() throws -> JournalSync {
        let dbQueue = try open()
        do {
            return try JournalSync(
                writer: dbQueue,
                databasePath: path,
                settings: SyncSettings.from(environment: ProcessInfo.processInfo.environment)
            )
        } catch {
            throw CLIError("could not set up sync for \(path): \(error)")
        }
    }
}
