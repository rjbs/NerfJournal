import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LocalJournalStore
    @State private var newTodoTitle = ""

    var body: some View {
        Group {
            if store.page == nil {
                startPrompt
            } else {
                pageView
            }
        }
        .navigationTitle(navigationTitle)
        .task {
            try? await store.load()
        }
    }

    private var navigationTitle: String {
        let date = store.page?.date ?? Date()
        return date.formatted(date: .long, time: .omitted)
    }

    private var startPrompt: some View {
        VStack(spacing: 16) {
            Text("No journal page for today.")
                .foregroundStyle(.secondary)
            Button("Start Today") {
                Task { try? await store.startToday() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageView: some View {
        List {
            ForEach(todoGroups, id: \.name) { group in
                Section(group.name ?? "Tasks") {
                    ForEach(group.todos) { todo in
                        TodoRow(todo: todo)
                    }
                    .onMove { offsets, destination in
                        Task {
                            try? await store.moveTodos(
                                in: group.name,
                                from: offsets,
                                to: destination
                            )
                        }
                    }
                }
            }
            Section {
                TextField("Add task\u{2026}", text: $newTodoTitle)
                    .onSubmit { submitNewTodo() }
            }
        }
    }

    // Named groups (sorted) appear before the ungrouped "Tasks" section.
    private var todoGroups: [(name: String?, todos: [Todo])] {
        let grouped = Dictionary(grouping: store.todos, by: \.groupName)
        let named = grouped
            .compactMap { key, value in key.map { (name: $0, todos: value) } }
            .sorted { $0.name < $1.name }
        let ungrouped = grouped[nil].map { [(name: nil as String?, todos: $0)] } ?? []
        return named + ungrouped
    }

    private func submitNewTodo() {
        let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            try? await store.addTodo(title: title, shouldMigrate: true)
            newTodoTitle = ""
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var store: LocalJournalStore
    @Environment(\.undoManager) private var undoManager
    @State private var showingNewGroupAlert = false
    @State private var newGroupName = ""
    let todo: Todo

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if todo.status == .pending {
                        try? await store.completeTodo(todo, undoManager: undoManager)
                    } else if todo.status == .done {
                        try? await store.uncompleteTodo(todo, undoManager: undoManager)
                    }
                }
            } label: {
                statusIcon
            }
            .buttonStyle(.plain)
            .disabled(todo.status == .abandoned)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .strikethrough(todo.status == .done)
                    .foregroundStyle(todo.status == .abandoned ? .secondary : .primary)
                if daysCarried > 0 {
                    Text("Carried over \u{b7} \(daysCarried) day\(daysCarried == 1 ? "" : "s") ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Menu("Mark") {
                if todo.status != .pending {
                    Button("Pending") {
                        Task { try? await store.setStatus(.pending, for: todo, undoManager: undoManager) }
                    }
                }
                if todo.status != .done {
                    Button("Complete") {
                        Task { try? await store.setStatus(.done, for: todo, undoManager: undoManager) }
                    }
                }
                if todo.status != .abandoned {
                    Button("Abandoned") {
                        Task { try? await store.setStatus(.abandoned, for: todo, undoManager: undoManager) }
                    }
                }
            }

            Menu("Add to group") {
                ForEach(existingGroups, id: \.self) { group in
                    Button(group) {
                        Task { try? await store.setGroup(group, for: todo, undoManager: undoManager) }
                    }
                }
                if !existingGroups.isEmpty {
                    Divider()
                }
                Button("New group\u{2026}") {
                    showingNewGroupAlert = true
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                Task { try? await store.deleteTodo(todo, undoManager: undoManager) }
            }
        }
        .alert("New Group Name", isPresented: $showingNewGroupAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Add") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    Task { try? await store.setGroup(name, for: todo, undoManager: undoManager) }
                }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch todo.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
        case .abandoned:
            Image(systemName: "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.4))
        default:
            Image(systemName: "circle")
                .foregroundStyle(Color.secondary)
        }
    }

    private var daysCarried: Int {
        let today = Calendar.current.startOfDay(for: Date())
        let added = Calendar.current.startOfDay(for: todo.firstAddedDate)
        return Calendar.current.dateComponents([.day], from: added, to: today).day ?? 0
    }

    private var existingGroups: [String] {
        Array(Set(store.todos.compactMap(\.groupName))).sorted()
    }
}
