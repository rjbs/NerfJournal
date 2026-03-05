import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TodoCommands: Commands {
    @FocusedValue(\.focusAddTodo) var focusAddTodo: Binding<Bool>?
    @FocusedValue(\.focusAddNote) var focusAddNote: Binding<Bool>?
    @FocusedObject var journalStore: JournalStore?
    @FocusedObject var pageStore: PageStore?
    @FocusedObject var categoryStore: CategoryStore?
    @FocusedObject var exportGroupStore: ExportGroupStore?
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
            Button("Go to Most Recent") {
                guard let latest = journalStore?.pageDates.max() else { return }
                Task { try? await journalStore?.selectDate(latest) }
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(journalStore?.pageDates.isEmpty != false)
        }
        CommandGroup(replacing: .saveItem) {
            Menu("Export Page") {
                exportSubMenu(groupName: "Everything", memberIDs: nil)
                if let store = exportGroupStore, !store.groups.isEmpty {
                    Divider()
                    ForEach(store.groups) { group in
                        exportSubMenu(groupName: group.name, memberIDs: store.groupMembers[group.id!])
                    }
                }
            }
            .disabled(journalStore?.selectedPage == nil)

            Button("Export Groups\u{2026}") {
                openWindow(id: "export-groups")
            }
        }
    }

    @ViewBuilder
    private func exportSubMenu(groupName: String, memberIDs: Set<Int64?>?) -> some View {
        Menu(groupName) {
            Button("Save as HTML\u{2026}") {
                saveAsHTML(memberIDs: memberIDs)
            }
            Button("Copy as mrkdwn") {
                copyAsMrkdwn(memberIDs: memberIDs)
            }
        }
    }

    private func saveAsHTML(memberIDs: Set<Int64?>?) {
        guard let page = journalStore?.selectedPage else { return }
        let todos = filteredTodos(memberIDs: memberIDs)
        let notes = pageStore?.notes ?? []
        let categories = categoryStore?.categories ?? []
        let html = exportPageHTML(date: page.date, todos: todos, notes: notes, categories: categories)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = df.string(from: page.date) + ".html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? html.write(to: url, atomically: true, encoding: .utf8)
    }

    private func copyAsMrkdwn(memberIDs: Set<Int64?>?) {
        let todos = filteredTodos(memberIDs: memberIDs)
        let categories = categoryStore?.categories ?? []
        let mrkdwn = exportPageMrkdwn(todos: todos, categories: categories)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mrkdwn, forType: .string)
    }

    private func filteredTodos(memberIDs: Set<Int64?>?) -> [Todo] {
        let todos = pageStore?.todos ?? []
        guard let memberIDs else { return todos }
        return todos.filter { memberIDs.contains($0.categoryID) }
    }
}

@main
struct NerfJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var pageStore = PageStore()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var bundleStore = BundleStore()
    @StateObject private var categoryStore = CategoryStore()
    @StateObject private var exportGroupStore = ExportGroupStore()

    var body: some Scene {
        Window("Journal", id: "journal") {
            JournalView()
                .environmentObject(journalStore)
                .environmentObject(pageStore)
                .environmentObject(bundleStore)
                .environmentObject(categoryStore)
                .environmentObject(exportGroupStore)
                .focusedSceneObject(pageStore)
                .focusedSceneObject(journalStore)
                .focusedSceneObject(categoryStore)
                .focusedSceneObject(exportGroupStore)
        }
        .defaultSize(width: 540, height: 520)
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

        Window("Future Log", id: "future-log") {
            FutureLogView()
                .environmentObject(pageStore)
                .environmentObject(categoryStore)
        }
        .defaultSize(width: 480, height: 400)

        Window("Export Groups", id: "export-groups") {
            ExportGroupManagerView()
                .environmentObject(exportGroupStore)
                .environmentObject(categoryStore)
        }
        .defaultSize(width: 480, height: 360)
    }
}
