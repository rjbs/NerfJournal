import SwiftUI
import GRDB

@MainActor
final class QuickNoteStore: ObservableObject {
    @Published var todayPageID: Int64? = nil
    @Published var loaded = false

    func load() async {
        let today = Calendar.current.startOfDay(for: Date())
        todayPageID = try? await AppDatabase.shared.dbQueue.read { db in
            try JournalPage.filter(Column("date") == today).fetchOne(db)?.id
        }
        loaded = true
    }

    func addNote(text: String) async {
        guard let pageID = todayPageID else { return }
        try? await AppDatabase.shared.dbQueue.write { db in
            var note = Note(id: nil, pageID: pageID, timestamp: Date(), text: text)
            try note.insert(db)
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
            object: nil, deliverImmediately: true
        )
    }
}

struct QuickNoteView: View {
    var dismiss: () -> Void
    @StateObject private var store = QuickNoteStore()
    @State private var text = ""
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
                TextEditor(text: $text)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onKeyPress(.return) { submit(); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
        }
        .padding()
        .frame(width: 500, height: 140)
        .task { await store.load() }
        .onChange(of: store.loaded) {
            if store.todayPageID != nil { focused = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        Task { await store.addNote(text: trimmed) }
        dismiss()
    }
}
