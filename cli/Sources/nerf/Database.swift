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
