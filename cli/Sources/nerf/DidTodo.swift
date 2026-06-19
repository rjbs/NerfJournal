import ArgumentParser
import Foundation
import GRDB

struct Did: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "did",
        abstract: "Record an unplanned thing you already did as a done todo on today's page."
    )

    @Option(name: .long,
            help: "Assign to the named category, matched case-insensitively (warn and continue if not found, unless --strict).")
    var category: String?

    @Flag(name: .long,
          help: "Fail without creating the todo if --category names an unknown category.")
    var strict = false

    @Option(name: .long, help: "Set an external URL on the todo.")
    var url: String?

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The todo title (all words are joined into one title).")
    var title: [String]

    func run() throws {
        let title = self.title.joined(separator: " ")
        guard !title.isEmpty else {
            throw ValidationError("todo title is required")
        }

        let today = Calendar.current.startOfDay(for: Date())
        let now = Date()

        let dbQueue = try db.open()

        // A done thing lands on today's page, which the CLI never creates — so
        // require it to exist, like add-todo. -- claude, 2026-06-19
        guard try fetchTodayPage(dbQueue, date: today) != nil else {
            throw CLIError("no journal page for today — start one in NerfJournal first")
        }

        let categoryID = try resolveCategory(dbQueue, name: category, strict: strict)

        if let dup = try findOpenDuplicate(dbQueue, title: title, url: url) {
            print("Didn't create todo for duplicate \(dup.field): \(dup.value) — use `nerf done` to complete it")
            return
        }

        do {
            try dbQueue.write { database in
                var todo = Todo(
                    id: nil,
                    title: title,
                    shouldMigrate: false,
                    start: today,
                    ending: TodoEnding(date: now, kind: .done),
                    categoryID: categoryID,
                    externalURL: url
                )
                try todo.insert(database)
            }
        } catch {
            throw CLIError("could not insert todo: \(error)")
        }

        postExternalChangeNotification()
    }
}
