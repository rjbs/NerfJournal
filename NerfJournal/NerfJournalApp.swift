import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TodoCommands: Commands {
    @FocusedValue(\.focusAddTodo) var focusAddTodo: Binding<Bool>?
    @FocusedValue(\.focusAddNote) var focusAddNote: Binding<Bool>?
    @FocusedObject var journalStore: JournalStore?
    @FocusedObject var categoryStore: CategoryStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Todo") { focusAddTodo?.wrappedValue = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(focusAddTodo == nil)
            Button("Add Note") { focusAddNote?.wrappedValue = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(focusAddNote == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Go to Today") {
                let today = Calendar.current.startOfDay(for: Date())
                Task { try? await journalStore?.selectDate(today) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(journalStore == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export Page…") {
                guard let journalStore, let page = journalStore.selectedPage else { return }
                let html = exportPageHTML(
                    date: page.date,
                    todos: journalStore.selectedTodos,
                    notes: journalStore.selectedNotes,
                    categories: categoryStore?.categories ?? []
                )
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd"
                let panel = NSSavePanel()
                panel.nameFieldStringValue = df.string(from: page.date) + ".html"
                panel.allowedContentTypes = [.html]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try? html.write(to: url, atomically: true, encoding: .utf8)
            }
            .disabled(journalStore?.selectedPage == nil)
        }
        CommandGroup(after: .windowArrangement) {
            Button("Open Work Journal") { openWindow(id: "journal") }
                .keyboardShortcut("1", modifiers: .command)
        }
    }
}

@main
struct NerfJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var pageStore = PageStore()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var bundleStore = BundleStore()
    @StateObject private var categoryStore = CategoryStore()

    var body: some Scene {
        WindowGroup(id: "journal") {
            JournalView()
                .environmentObject(journalStore)
                .environmentObject(pageStore)
                .environmentObject(bundleStore)
                .environmentObject(categoryStore)
                .focusedSceneObject(pageStore)
                .focusedSceneObject(journalStore)
                .focusedSceneObject(categoryStore)
        }
        .defaultSize(width: 700, height: 520)
        .commands {
            DebugCommands()
            TodoCommands()
        }

        Window("Bundle Manager", id: "bundle-manager") {
            BundleManagerView()
                .environmentObject(bundleStore)
                .environmentObject(categoryStore)
                .focusedSceneObject(pageStore)
        }
        .defaultSize(width: 600, height: 480)
    }
}
