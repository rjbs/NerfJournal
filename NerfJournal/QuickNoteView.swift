import SwiftUI
import GRDB

@MainActor
final class QuickNoteStore: ObservableObject {
    @Published var todayPageID: Int64? = nil
    @Published var loaded = false
    @Published var isTodo = false
    @Published var categories: [Category] = []

    func load() async {
        let today = Calendar.current.startOfDay(for: Date())
        let result = try? await AppDatabase.shared.dbQueue.read { db -> (Int64?, [Category]) in
            let pageID = try JournalPage.filter(Column("date") == today).fetchOne(db)?.id
            let cats = try Category.order(Column("sortOrder")).fetchAll(db)
            return (pageID, cats)
        }
        todayPageID = result?.0
        categories = result?.1 ?? []
        loaded = true
    }

    func addNote(text: String) async {
        guard let pageID = todayPageID else { return }
        try? await AppDatabase.shared.dbQueue.write { db in
            var note = Note(id: nil, pageID: pageID, timestamp: Date(), text: text)
            try note.insert(db)
        }
        notify()
    }

    func addTodo(title: String, categoryID: Int64?) async {
        let today = Calendar.current.startOfDay(for: Date())
        try? await AppDatabase.shared.dbQueue.write { db in
            var todo = Todo(
                id: nil,
                title: title,
                shouldMigrate: true,
                start: today,
                ending: nil,
                categoryID: categoryID,
                externalURL: nil
            )
            try todo.insert(db)
        }
        notify()
    }

    private func notify() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
            object: nil, deliverImmediately: true
        )
    }
}

struct QuickNoteView: View {
    var dismiss: () -> Void
    @ObservedObject var store: QuickNoteStore

    @State private var text = ""
    @State private var selectedCategoryID: Int64? = nil
    @State private var categoryPickerActive = false
    @State private var categoryPickerQuery = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if !store.loaded {
                Color.clear
            } else if store.todayPageID == nil {
                Text("No journal page for today")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            store.isTodo.toggle()
                            focused = true
                        } label: {
                            Image(systemName: store.isTodo ? "circle" : "bubble.left")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)
                        .help(store.isTodo ? "Switch to note" : "Switch to todo")

                        TextField(store.isTodo ? "Add todo\u{2026}" : "Add note\u{2026}", text: $text)
                            .font(.system(size: 20))
                            .focused($focused)
                            .onSubmit { submit() }
                            .onKeyPress(.escape) {
                                if categoryPickerActive { cancelCategoryPicker(); return .handled }
                                dismiss()
                                return .handled
                            }
                            .onChange(of: text) { _, newText in updateCategoryPicker(for: newText) }

                        if store.isTodo, let catID = selectedCategoryID,
                           let cat = store.categories.first(where: { $0.id == catID }) {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(cat.color.swatch)
                                    .frame(width: 8, height: 8)
                                Text(cat.name)
                                    .font(.caption)
                                Button { selectedCategoryID = nil } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(cat.color.swatch.opacity(0.15))
                                    .overlay(Capsule().stroke(cat.color.swatch.opacity(0.4), lineWidth: 1))
                            )
                            .foregroundStyle(cat.color.swatch)
                        }
                    }

                    if store.isTodo && categoryPickerActive && !filteredCategories.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(filteredCategories) { cat in
                                Button { selectCategory(cat) } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(cat.color.swatch)
                                            .frame(width: 8, height: 8)
                                        Text(cat.name).font(.caption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(cat.color.swatch.opacity(0.15)))
                                    .foregroundStyle(cat.color.swatch)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.leading, 28)
                    }
                }
            }
        }
        .padding()
        .frame(width: 500, height: 130, alignment: .top)
        .task { await store.load() }
        .onChange(of: store.loaded) {
            if store.todayPageID != nil { focused = true }
        }
        .onChange(of: store.isTodo) { _, isTodo in
            if !isTodo {
                selectedCategoryID = nil
                categoryPickerActive = false
                categoryPickerQuery = ""
            }
        }
    }

    private var filteredCategories: [Category] {
        guard categoryPickerActive else { return [] }
        let all = store.categories
        return categoryPickerQuery.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(categoryPickerQuery) }
    }

    private func submit() {
        if categoryPickerActive && !filteredCategories.isEmpty {
            selectCategory(filteredCategories[0])
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        if store.isTodo {
            let catID = selectedCategoryID
            Task { await store.addTodo(title: trimmed, categoryID: catID) }
        } else {
            Task { await store.addNote(text: trimmed) }
        }
        dismiss()
    }

    private func updateCategoryPicker(for text: String) {
        guard store.isTodo else { categoryPickerActive = false; return }
        let words = text.components(separatedBy: " ")
        if let last = words.last, last.hasPrefix("#") {
            categoryPickerActive = true
            categoryPickerQuery = String(last.dropFirst())
        } else {
            categoryPickerActive = false
            categoryPickerQuery = ""
        }
    }

    private func selectCategory(_ category: Category) {
        var words = text.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        text = words.joined(separator: " ")
        if !text.isEmpty { text += " " }
        selectedCategoryID = category.id
        categoryPickerActive = false
        categoryPickerQuery = ""
        focused = true
    }

    private func cancelCategoryPicker() {
        var words = text.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        text = words.joined(separator: " ")
        categoryPickerActive = false
        categoryPickerQuery = ""
    }
}
