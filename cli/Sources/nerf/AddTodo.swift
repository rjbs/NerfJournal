import ArgumentParser
import Foundation
import GRDB
import NerfCore

struct AddTodo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-todo",
        abstract: "Add a todo to today's NerfJournal page."
    )

    @Flag(name: .customLong("no-migrate"),
          help: "Mark the todo as non-migratable (default: migratable).")
    var noMigrate = false

    @Option(name: .long,
            help: "Assign to the named category, matched case-insensitively (warn and continue if not found, unless --strict).")
    var category: String?

    @Flag(name: .long,
          help: "Fail without creating the todo if --category names an unknown category.")
    var strict = false

    @Option(name: .long, help: "Set an external URL on the todo.")
    var url: String?

    @Option(name: .long,
            help: "Start date for the todo (e.g. \"tomorrow\", \"wed\", \"+3d\", \"+2w\"). Future dates land in the Future Log.")
    var start: String?

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The todo title (all words are joined into one title).")
    var title: [String]

    func run() async throws {
        let title = self.title.joined(separator: " ")
        guard !title.isEmpty else {
            throw ValidationError("todo title is required")
        }

        let today = CivilDate.today

        let startDay: CivilDate
        if let start = self.start {
            guard let parsed = DateParser.parse(start) else {
                throw ValidationError("could not understand start date: \(start)")
            }
            startDay = CivilDate(instant: parsed, in: .current)
        } else {
            startDay = today
        }

        let dbQueue = try db.open()
        let sync = try db.openSync()

        // A todo starting today must land on today's page, which the CLI never
        // creates — so require it to exist.  A future-dated todo lives in the
        // Future Log instead, so it needs no page and can be filed any day. -- claude, 2026-06-13
        if startDay <= today {
            let todayPage = try fetchTodayPage(dbQueue, date: today)
            guard todayPage != nil else {
                throw CLIError("no journal page for today — start one in NerfJournal first")
            }
        }

        let categoryID = try resolveCategory(dbQueue, name: category, strict: strict)

        if let dup = await findOpenDuplicate(sync, title: title, url: url) {
            print("Didn't create todo for duplicate \(dup.field): \(dup.value)")
            return
        }

        let todo = Todo(
            id: nil,
            title: title,
            shouldMigrate: !noMigrate,
            start: startDay,
            ending: nil,
            categoryID: categoryID,
            externalURL: url
        )
        do {
            _ = try await TaskWriter(sync: sync).create(todo)
        } catch {
            throw CLIError("could not create todo: \(error)")
        }

        await pushAfterWrite(sync)
    }
}
