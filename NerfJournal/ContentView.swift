import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LocalJournalStore
    @State private var isAddingTodo = false
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
        .toolbar {
            if store.page != nil {
                ToolbarItem {
                    Button {
                        isAddingTodo = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                }
            }
        }
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
                }
            }
            if isAddingTodo {
                Section {
                    HStack {
                        TextField("New task\u{2026}", text: $newTodoTitle)
                            .onSubmit { submitNewTodo() }
                        Button("Add", action: submitNewTodo)
                            .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            newTodoTitle = ""
                            isAddingTodo = false
                        }
                    }
                }
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
            isAddingTodo = false
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject private var store: LocalJournalStore
    let todo: Todo

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { try? await store.completeTodo(todo) }
            } label: {
                Image(systemName: todo.status == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.status == .done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(todo.status != .pending)

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
    }

    private var daysCarried: Int {
        let today = Calendar.current.startOfDay(for: Date())
        let added = Calendar.current.startOfDay(for: todo.firstAddedDate)
        return Calendar.current.dateComponents([.day], from: added, to: today).day ?? 0
    }
}
