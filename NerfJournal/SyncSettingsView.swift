import Jinx
import JinxWire
import NerfCore
import SwiftUI

// What the settings pane shows about the engine: its status, and the
// todos whose last push the server refused. Polled while the pane is
// open; nothing else in the app needs it. -- claude, 2026-10-28
@MainActor
final class SyncStatusStore: ObservableObject {
    @Published var status: SyncStatus?
    @Published var failed: [SyncedTodo] = []
    @Published var loadError: String?

    private let sync: JournalSync

    init(sync: JournalSync = AppDatabase.shared.sync) {
        self.sync = sync
    }

    func refresh() async {
        do {
            status = try await sync.status()
            failed = try await TaskReader(sync: sync).syncedTodos().filter { $0.lastError != nil }
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    // Refreshes every couple of seconds until the task is cancelled, which
    // SwiftUI does when the pane goes away.
    func keepRefreshing() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func syncNow() async {
        await sync.engine.requestSync()
    }
}

struct SyncSettingsView: View {
    @AppStorage(SyncSettings.sessionURLDefaultsKey) private var sessionURL = SyncSettings.prototype.sessionURL.absoluteString
    @AppStorage(SyncSettings.accountIdDefaultsKey) private var accountId = SyncSettings.prototype.accountId
    @StateObject private var store = SyncStatusStore()

    var body: some View {
        Form {
            Section("Server") {
                TextField("Session URL", text: $sessionURL)
                TextField("Account", text: $accountId)
                Text("Changes take effect the next time NerfJournal launches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                if let status = store.status {
                    LabeledContent("Connected", value: status.isConnected ? "Yes" : "No")
                    LabeledContent("Last fetch", value: timestamp(status.lastSyncIn))
                    LabeledContent("Last push", value: timestamp(status.lastSyncOut))
                    LabeledContent("Waiting to send", value: "\(status.pendingCount)")
                    if let failure = status.lastFailure {
                        LabeledContent("Last failure", value: failure)
                    }
                    ForEach(status.initialSync.sorted(by: { $0.key < $1.key }), id: \.key) { type, progress in
                        LabeledContent("Fetching \(type)", value: "\(progress.fetched) of \(progress.total.map(String.init) ?? "?")")
                    }
                } else if let error = store.loadError {
                    Text(error).foregroundStyle(.red)
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }
                Button("Sync Now") {
                    Task { await store.syncNow() }
                }
            }

            Section("Refused by the server") {
                if store.failed.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(store.failed) { item in
                        VStack(alignment: .leading) {
                            Text(item.todo.title)
                            Text(describe(item.lastError))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .task { await store.keepRefreshing() }
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func describe(_ error: SetError?) -> String {
        guard let error else { return "" }
        var parts = [error.type]
        if let description = error.description { parts.append(description) }
        if let properties = error.properties, !properties.isEmpty {
            parts.append("(" + properties.joined(separator: ", ") + ")")
        }
        return parts.joined(separator: " ")
    }
}
