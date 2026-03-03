import AppKit
import SwiftUI

// Width of the date column: probed at launch using "Sep 29" — widest typical
// abbreviated-month + two-digit-day. -- claude, 2026-03-03
private let futureLogDateColumnWidth: CGFloat = {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 9; comps.day = 29
    let ref = Calendar.current.date(from: comps) ?? Date()
    let sample = ref.formatted(.dateTime.month(.abbreviated).day())
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .caption1)]
    return ceil((sample as NSString).size(withAttributes: attrs).width) + 2
}()

// MARK: - FutureLogView

struct FutureLogView: View {
    @EnvironmentObject private var pageStore: PageStore
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var selectedIDs: Set<Int64> = []

    var body: some View {
        Group {
            if pageStore.futureTodos.isEmpty {
                Text("No future work scheduled.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedIDs) {
                    ForEach(pageStore.futureTodos) { todo in
                        FutureLogRow(todo: todo, selectedIDs: selectedIDs)
                            .tag(todo.id!)
                    }
                }
            }
        }
        .navigationTitle("Future Log")
    }
}

// MARK: - FutureLogRow

struct FutureLogRow: View {
    @EnvironmentObject private var pageStore: PageStore
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.undoManager) private var undoManager

    let todo: Todo
    var selectedIDs: Set<Int64> = []

    @State private var showingSendToDateSheet = false
    @State private var pendingSendToDate: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    )
    @State private var sheetAffectedIDs: Set<Int64> = []

    @State private var todoToSetURL: Todo? = nil
    @State private var showingSetURLAlert = false
    @State private var urlText = ""
    @State private var showingInvalidURLAlert = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(categoryStore.categories.first(where: { $0.id == todo.categoryID })?.color.swatch ?? Color.gray)
                .frame(width: 8, height: 8)

            Text(todo.start.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: futureLogDateColumnWidth, alignment: .trailing)

            Text(todo.title)

            Spacer()

            if let urlString = todo.externalURL,
               let url = URL(string: urlString) {
                Link(destination: url) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
                .help(urlString)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            let affectedIDs: Set<Int64> = selectedIDs.contains(todo.id!) && selectedIDs.count > 1
                ? selectedIDs : [todo.id!]
            let affectedTodos = pageStore.futureTodos.filter { affectedIDs.contains($0.id!) }
            let today = Calendar.current.startOfDay(for: Date())

            if affectedTodos.count > 1 {
                Button("Send to today") {
                    Task { try? await pageStore.sendToDate(affectedTodos, date: today, undoManager: undoManager) }
                }
                Button("Send to date\u{2026}") {
                    pendingSendToDate = Calendar.current.startOfDay(
                        for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                    )
                    sheetAffectedIDs = affectedIDs
                    showingSendToDateSheet = true
                }

                Menu("Set Category") {
                    Button("None") {
                        Task { try? await pageStore.setBulkCategory(nil, forTodoIDs: affectedIDs, undoManager: undoManager) }
                    }
                    Divider()
                    ForEach(categoryStore.categories) { category in
                        Button(category.name) {
                            Task { try? await pageStore.setBulkCategory(category.id, forTodoIDs: affectedIDs, undoManager: undoManager) }
                        }
                    }
                }
            } else {
                Button("Send to today") {
                    Task { try? await pageStore.sendToDate(affectedTodos, date: today, undoManager: undoManager) }
                }
                Button("Send to date\u{2026}") {
                    pendingSendToDate = Calendar.current.startOfDay(
                        for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                    )
                    sheetAffectedIDs = affectedIDs
                    showingSendToDateSheet = true
                }

                Picker("Category", selection: Binding(
                    get: { todo.categoryID },
                    set: { newID in
                        Task { try? await pageStore.setCategory(newID, for: todo, undoManager: undoManager) }
                    }
                )) {
                    Text("None").tag(nil as Int64?)
                    ForEach(categoryStore.categories) { category in
                        Text(category.name).tag(category.id as Int64?)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Button("Set URL\u{2026}") {
                    todoToSetURL = todo
                    urlText = todo.externalURL ?? ""
                    showingSetURLAlert = true
                }
            }
        }
        .alert("Set URL", isPresented: $showingSetURLAlert) {
            TextField("URL", text: $urlText)
            Button("Set") { commitURL() }
            Button("Cancel", role: .cancel) {
                todoToSetURL = nil
                urlText = ""
            }
        }
        .alert("Invalid URL", isPresented: $showingInvalidURLAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please enter a valid URL (e.g. https://example.com) or clear the field to remove the URL.")
        }
        .sheet(isPresented: $showingSendToDateSheet) {
            let minDate = pageStore.page?.date ?? Calendar.current.startOfDay(for: Date())
            VStack(spacing: 16) {
                Text("Send to\u{2026}")
                    .font(.headline)
                DatePicker(
                    "Date",
                    selection: $pendingSendToDate,
                    in: minDate...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                HStack {
                    Button("Cancel") { showingSendToDateSheet = false }
                    Button("Send") {
                        let ids = sheetAffectedIDs
                        let targetDate = pendingSendToDate
                        Task {
                            let todos = pageStore.futureTodos.filter { ids.contains($0.id!) }
                            try? await pageStore.sendToDate(todos, date: targetDate, undoManager: undoManager)
                        }
                        showingSendToDateSheet = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 300)
        }
    }

    private func commitURL() {
        guard let todo = todoToSetURL else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Task { try? await pageStore.setURL(nil, for: todo) }
        } else if URL(string: trimmed)?.scheme != nil {
            Task { try? await pageStore.setURL(trimmed, for: todo) }
        } else {
            showingInvalidURLAlert = true
            return
        }
        todoToSetURL = nil
        urlText = ""
    }
}
