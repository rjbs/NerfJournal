import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DebugCommands: Commands {
    @FocusedObject var store: PageStore?

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Export…") {
                Task { await exportDatabase() }
            }
            .disabled(store == nil)

            Button("Import…") {
                Task { await importDatabase() }
            }
            .disabled(store == nil)

            Divider()

            Button("Factory Reset…") {
                Task { await factoryReset() }
            }
            .disabled(store == nil)
        }
    }

    @MainActor
    private func exportDatabase() async {
        guard let store else { return }
        let data: Data
        do {
            data = try await store.exportData()
        } catch {
            showError("Export failed: \(error.localizedDescription)")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultExportFilename()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            showError("Could not write file: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func importDatabase() async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            try await store.importDatabase(data)
        } catch {
            showError("Import failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func factoryReset() async {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Factory Reset"
        alert.informativeText = """
            This will permanently delete all journal pages, todos, notes, \
            task bundles, and categories. This cannot be undone.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Delete Everything")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try await store.factoryReset()
        } catch {
            showError("Factory reset failed: \(error.localizedDescription)")
        }
    }

    private func defaultExportFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "NerfJournal-\(fmt.string(from: Date())).json"
    }

    @MainActor
    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        _ = alert.runModal()
    }
}
