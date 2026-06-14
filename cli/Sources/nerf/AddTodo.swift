import ArgumentParser
import Foundation
import GRDB

struct AddTodo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-todo",
        abstract: "Add a todo to today's NerfJournal page."
    )

    @Flag(name: .customLong("no-migrate"),
          help: "Mark the todo as non-migratable (default: migratable).")
    var noMigrate = false

    @Option(name: .long,
            help: "Assign to the named category (warn and continue if not found).")
    var category: String?

    @Option(name: .long, help: "Set an external URL on the todo.")
    var url: String?

    @Option(name: .long,
            help: "Start date for the todo (e.g. \"tomorrow\", \"wed\", \"+3d\", \"+2w\"). Future dates land in the Future Log.")
    var start: String?

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The todo title (all words are joined into one title).")
    var title: [String]

    func run() throws {
        let title = self.title.joined(separator: " ")
        guard !title.isEmpty else {
            throw ValidationError("todo title is required")
        }

        let today = Calendar.current.startOfDay(for: Date())

        let startDate: Date
        if let start = self.start {
            guard let parsed = DateParser.parse(start) else {
                throw ValidationError("could not understand start date: \(start)")
            }
            startDate = parsed
        } else {
            startDate = today
        }

        let dbQueue = try db.open()

        // Today's page must already exist; the CLI never creates pages.  A future
        // todo lives in the Future Log rather than on today's page, but we still
        // require an active journal so scripted callers fail loudly on a fresh DB.
        let todayPage = try fetchTodayPage(dbQueue, date: today)
        guard todayPage != nil else {
            throw CLIError("no journal page for today — start one in NerfJournal first")
        }

        let categoryID = resolveCategory(dbQueue)

        if let dup = try findDuplicate(dbQueue, title: title) {
            print("Didn't create todo for duplicate \(dup.field): \(dup.value)")
            return
        }

        do {
            try dbQueue.write { database in
                var todo = Todo(
                    id: nil,
                    title: title,
                    shouldMigrate: !noMigrate,
                    start: startDate,
                    ending: nil,
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

    private func fetchTodayPage(_ dbQueue: DatabaseQueue, date: Date) throws -> JournalPage? {
        do {
            return try dbQueue.read { database in
                try JournalPage
                    .filter(Column("date") == date)
                    .fetchOne(database)
            }
        } catch {
            throw CLIError("could not query journal pages: \(error)")
        }
    }

    // Resolves --category to an id, warning (but not failing) on a miss, since a
    // miscategorized todo is better than a lost one for scripted callers.
    private func resolveCategory(_ dbQueue: DatabaseQueue) -> Int64? {
        guard let name = category else { return nil }
        do {
            let categories = try dbQueue.read { db in try Category.fetchAll(db) }
            if let match = categories.first(where: { $0.name.lowercased() == name.lowercased() }) {
                return match.id
            }
            fputs("warning: category \"\(name)\" not found — adding todo without category\n", stderr)
        } catch {
            fputs("warning: could not query categories: \(error) — adding todo without category\n", stderr)
        }
        return nil
    }

    private struct DuplicateFound {
        var field: String
        var value: String
    }

    // Skip insertion if any open (ending IS NULL) todo already has this title or URL.
    private func findDuplicate(_ dbQueue: DatabaseQueue, title: String) throws -> DuplicateFound? {
        do {
            return try dbQueue.read { database -> DuplicateFound? in
                let titleDup = try Row.fetchOne(
                    database,
                    sql: "SELECT 1 FROM todo WHERE ending IS NULL AND title = ?",
                    arguments: [title]
                )
                if titleDup != nil {
                    return DuplicateFound(field: "title", value: title)
                }
                if let url = url {
                    let urlDup = try Row.fetchOne(
                        database,
                        sql: "SELECT 1 FROM todo WHERE ending IS NULL AND externalURL = ?",
                        arguments: [url]
                    )
                    if urlDup != nil {
                        return DuplicateFound(field: "url", value: url)
                    }
                }
                return nil
            }
        } catch {
            fputs("warning: could not check for duplicates: \(error)\n", stderr)
            return nil
        }
    }
}
