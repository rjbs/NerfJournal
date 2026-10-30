import ArgumentParser
import Foundation
import GRDB
import NerfCore

struct Did: AsyncParsableCommand {
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

    func run() async throws {
        let title = self.title.joined(separator: " ")
        guard !title.isEmpty else {
            throw ValidationError("todo title is required")
        }

        let today = CivilDate.today

        let dbQueue = try db.open()
        let sync = try db.openSync()

        // A done thing lands on today's page, which the CLI never creates — so
        // require it to exist, like add-todo. -- claude, 2026-06-19
        guard try fetchTodayPage(dbQueue, date: today) != nil else {
            throw CLIError("no journal page for today — start one in NerfJournal first")
        }

        let categoryID = try await resolveCategory(sync, name: category, strict: strict)

        if let dup = await findOpenDuplicate(sync, title: title, url: url) {
            print("Didn't create todo for duplicate \(dup.field): \(dup.value) — use `nerf done` to complete it")
            return
        }

        let todo = Todo(
            id: nil,
            title: title,
            shouldMigrate: false,
            start: today,
            ending: TodoEnding(moment: .now(), kind: .done),
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
