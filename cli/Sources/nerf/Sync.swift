import ArgumentParser
import Foundation
import Jinx
import NerfCore

struct SyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Push pending changes to the server and fetch what has changed there."
    )

    @OptionGroup var db: DatabaseOptions

    func run() async throws {
        let sync = try db.openSync()
        do {
            try await sync.engine.sync()
        } catch {
            throw CLIError("sync failed: \(describeSyncError(error))")
        }
        let status = try await sync.status()
        print(statusLines(status, settings: sync.settings).joined(separator: "\n"))
    }
}

struct SyncStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-status",
        abstract: "Show the sync engine's state and any todos the server refused, without syncing."
    )

    @OptionGroup var db: DatabaseOptions

    func run() async throws {
        let sync = try db.openSync()
        let status = try await sync.status()
        var lines = statusLines(status, settings: sync.settings)
        let failed = try await TaskReader(sync: sync).syncedTodos().filter { $0.lastError != nil }
        if !failed.isEmpty {
            lines.append("")
            lines.append("Refused by the server:")
            for item in failed {
                let error = item.lastError!
                var detail = error.type
                if let description = error.description { detail += ": \(description)" }
                if let properties = error.properties, !properties.isEmpty {
                    detail += " (\(properties.joined(separator: ", ")))"
                }
                lines.append("  \(item.id)  \(item.todo.title) — \(detail)")
            }
        }
        print(lines.joined(separator: "\n"))
    }
}

// Status as a short report. Timestamps are from this process, so a
// `sync-status` that did not sync shows "never" for them; the pending
// count is read from the shared store and is always current.
private func statusLines(_ status: SyncStatus, settings: SyncSettings) -> [String] {
    func stamp(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "never (this run)"
    }
    var lines = [
        "server:     \(settings.sessionURL.absoluteString)",
        "account:    \(settings.accountId)",
        "connected:  \(status.isConnected ? "yes" : "no")",
        "last fetch: \(stamp(status.lastSyncIn))",
        "last push:  \(stamp(status.lastSyncOut))",
        "pending:    \(status.pendingCount)",
    ]
    if let failure = status.lastFailure {
        lines.append("failure:    \(failure)")
    }
    return lines
}
