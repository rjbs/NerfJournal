import ArgumentParser
import Foundation
import GRDB

struct Done: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done",
        abstract: "Mark a started, still-open todo as done, ending it now."
    )

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The id of the todo to mark done.")
    var id: Int64

    func run() throws { try endTodo(id: id, kind: .done, db: db) }
}

struct Abandon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "abandon",
        abstract: "Mark a started, still-open todo as abandoned, ending it now."
    )

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The id of the todo to abandon.")
    var id: Int64

    func run() throws { try endTodo(id: id, kind: .abandoned, db: db) }
}

// Ends a todo by setting its ending to (now, kind).  Fetch, validation, and
// update happen in one write transaction so a failed check leaves nothing
// changed and concurrent writers can't slip a state change in between.
private func endTodo(id: Int64, kind: TodoEnding.Kind, db: DatabaseOptions) throws {
    let dbQueue = try db.open()
    let today = Calendar.current.startOfDay(for: Date())
    let now = Date()

    do {
        try dbQueue.write { database in
            guard var todo = try Todo.filter(Column("id") == id).fetchOne(database) else {
                throw CLIError("no todo with id \(id)")
            }
            if todo.start > today {
                throw CLIError("todo \(id) hasn't started yet (starts \(dayString(todo.start)))")
            }
            if let ending = todo.ending {
                throw CLIError("todo \(id) is already \(ending.kind == .done ? "done" : "abandoned")")
            }
            todo.ending = TodoEnding(date: now, kind: kind)
            try todo.update(database)
        }
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError("could not update todo: \(error)")
    }

    postExternalChangeNotification()
}

private func dayString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
