---
title: "Unit 7: Persistence with GRDB"
nav_order: 70
---

# Unit 7: Persistence with GRDB

## Introduction

Every store in NerfJournal is a thin layer over one SQLite file. The stores hold
the *in-memory* picture — `@Published` arrays the views render — but the file on
disk is the source of truth, and the path between them runs through
[GRDB](https://github.com/groue/GRDB.swift), a Swift SQLite toolkit.

This unit is about that path. How a Swift `struct` becomes a row and back. How
GRDB's record protocols relate to Swift's own `Codable`. Why NerfJournal has
*two* distinct serialization stories riding on the same types — one for SQLite,
one for JSON export — and why keeping them separate matters. How schema changes
are managed through migrations, and why the early ones throw data away instead
of preserving it. And how the database, which lives off the main actor, hands
data across to the `@MainActor` stores safely.

If you come from Perl, the closest reference point is `DBIx::Class` or a hand-rolled
`DBI` layer; from Rust, think `diesel` or `rusqlite` with `serde`. GRDB sits
about where `rusqlite` plus a derive macro would: closer to the SQL than a full
ORM, but with enough protocol machinery that a plain `struct` becomes
round-trippable with almost no boilerplate.

---

## The Wrapper: `AppDatabase` and `DatabaseQueue`

`AppDatabase` is a `struct` with a single stored property:

```swift
struct AppDatabase {
    let dbQueue: DatabaseQueue
}
```

A [`DatabaseQueue`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasequeue)
is GRDB's core concurrency primitive. It owns the one open connection to the
SQLite file and *serializes* every access through it: reads and writes are
submitted as closures, and the queue runs them one at a time, in order. There is
no way to touch the database except by handing the queue a closure. That single
chokepoint is what makes "concurrent" access safe — there is never actually any
concurrency at the SQLite layer, only a queue of closures waiting their turn.

This is a different bargain than Perl's `DBI`, where `$dbh->do(...)` runs right
now on the current thread and concurrency is your problem. GRDB takes the
connection away from you and only lets you reach it through `read` and `write`.

`AppDatabase.shared` is a lazily-initialized `static let` that builds the file
path inside the app's sandboxed Application Support directory and opens the
queue. The `try!` calls there are deliberate: if the app cannot create its own
data directory, there is nothing sensible to do but crash at launch.

```swift
init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path)
    try migrate(dbQueue)
}
```

Opening the queue and migrating the schema happen together, every launch. We'll
come back to `migrate`.

---

## Records: `struct` ⇆ row

A Swift type becomes a database record by conforming to GRDB protocols. `Todo`
declares four:

```swift
struct Todo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var title: String
    var shouldMigrate: Bool
    var start: Date
    var ending: TodoEnding?
    var categoryID: Int64?
    var externalURL: String?

    static let databaseTableName = "todo"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

Each protocol does one job:

- [`FetchableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/fetchablerecord)
  — "can be built from a database row." Gives you `Todo.fetchAll(db)`,
  `Todo.fetchOne(db)`, and the query builder (`Todo.filter(...).order(...)`).
- [`PersistableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/persistablerecord)
  / `MutablePersistableRecord` — "can be written to the database." Gives you
  `insert(db)`, `update(db)`, `delete(db)`. The *Mutable* variant is for records
  whose identity is assigned *by* the database — exactly our case, where `id` is
  `nil` until SQLite picks an autoincrement value.
- `TableRecord` (implied by the two above) — supplies `databaseTableName`, the
  link from the type to its table.

The `id: Int64?` being **optional** is the whole identity story in one line. A
`Todo` you've just constructed in memory has `id == nil` — it doesn't exist in
the database yet, so it has no row ID. When you `insert(db)` it, GRDB calls
`didInsert`, and we copy the freshly-assigned `rowID` back into `id`. After that
the struct's `id` is non-nil and matches the row. This is the same pattern Rust's
diesel uses with `Option<i32>` for the primary key of an "insertable" versus a
"queryable" struct — except Swift lets one type play both roles, with `nil`
meaning "not yet persisted."

> A subtlety worth pausing on: `insert(db)` takes `var todo` (a mutable copy),
> not the original. Because `Todo` is a value type (Unit 1), the struct you pass
> in is copied; only the copy inside the `write` closure gets its `id` filled in.
> If you need the assigned id back out, you read it from the copy, or — as
> `applyBundle` does — return the inserted ids out of the `write` closure. The
> original value you started with is untouched.

### Where `Codable` comes in

`Todo` also conforms to [`Codable`](https://developer.apple.com/documentation/swift/codable).
GRDB notices this and, when a record is `Codable`, derives the row encoding and
decoding *from the `Codable` conformance* automatically. So you usually write no
mapping code at all: the synthesized `Codable` lists the stored properties, and
GRDB turns each into a column of the same name.

This is the convenience that makes the records above so short. But it also means
two things that look independent — "how does this struct serialize to JSON?" and
"how does this struct map to SQLite columns?" — are by default answered by the
*same* `Codable` machinery. Most of the time that's fine. The interesting cases
in NerfJournal are exactly where it isn't, and the two paths have to be pried
apart.

---

## Two serialization paths on one type

This is the part most worth understanding precisely, because two mechanisms here
look alike and are not the same thing.

NerfJournal serializes its data in two completely different situations:

1. **To SQLite**, constantly, as the app runs — via GRDB's record protocols.
2. **To JSON**, occasionally, for the export/import feature — via `Codable` and
   `JSONEncoder`/`JSONDecoder`.

`TodoEnding` is the type that makes the distinction vivid. It needs to be *one
column* in the `todo` table, but a *nested object* in the export JSON. It pulls
this off by conforming to both `Codable` and
[`DatabaseValueConvertible`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasevalueconvertible):

```swift
struct TodoEnding: Codable, DatabaseValueConvertible {
    enum Kind: String, Codable { case done, abandoned }
    var date: Date
    var kind: Kind

    // SQLite path: serialize the whole thing to a JSON string in one column.
    var databaseValue: DatabaseValue {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try! enc.encode(self)
        return String(data: data, encoding: .utf8)!.databaseValue
    }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> TodoEnding? {
        guard let s = String.fromDatabaseValue(dbValue),
              let d = s.data(using: .utf8) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(TodoEnding.self, from: d)
    }
}
```

The comment in the source says it exactly: *"Stored as a JSON string in SQLite
(via `DatabaseValueConvertible`); encoded as a nested object in export JSON (via
`Codable`). These are distinct code paths with no conflict."*

`DatabaseValueConvertible` is the hook GRDB consults to turn a custom type into a
single SQLite value. Because `TodoEnding` provides it, GRDB stores a `Todo`'s
`ending` as one text column holding `{"date":...,"kind":"done"}`. Meanwhile, when
`DatabaseExport` (which is plain `Codable`, no GRDB involved) is run through
`JSONEncoder`, the *same* `TodoEnding` is encoded structurally as a nested JSON
object, because that path uses `Codable`, not `DatabaseValueConvertible`.

`CategoryColor` (the eight-case enum) is the same idea in miniature: it's
`Codable` for export *and* `DatabaseValueConvertible` (storing its raw string) for
SQLite. Two paths, one type, no conflict — as long as you keep clear in your head
which one is running.

> The mental hook: `Codable` answers "what does this look like as JSON?";
> `DatabaseValueConvertible` answers "what does this look like as one SQLite
> value?" A type can answer both questions differently. When you read
> `try enc.encode(self)`, you are on the JSON path; when GRDB reads
> `record.databaseValue`, you are on the SQLite path. They never run at the same
> time and never consult each other.

### Customizing the `Codable` path without disturbing the record

When the `start` column was renamed from `added` (migration v5), old export
files still said `"added"`. Rather than break those imports, `Todo` overrides its
`Codable` conformance to accept either key on decode and always write `start` on
encode:

```swift
extension Todo {
    // Custom coding in an extension so the memberwise init is still synthesized.
    private enum CodingKeys: String, CodingKey {
        case id, title, shouldMigrate, start, added, ending, categoryID, externalURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ...
        if let s = try c.decodeIfPresent(Date.self, forKey: .start) {
            start = s
        } else {
            start = try c.decode(Date.self, forKey: .added)   // legacy export
        }
        // ...
    }

    func encode(to encoder: Encoder) throws { /* writes .start, never .added */ }
}
```

Two details are load-bearing here. First, the custom `init(from:)` and
`encode(to:)` live in an **extension**, not the main `struct` body. Swift only
synthesizes the memberwise initializer (`Todo(id:title:...)`) when you *don't*
write your own initializer in the type's body; putting the `Codable` init in an
extension keeps the synthesized memberwise init available, which the rest of the
app relies on. (This is a recurring Swift idiom: put custom inits in extensions
to keep the free one.)

Second — and this connects back to the two-paths idea — overriding `Codable`
changes *both* the JSON path *and* the GRDB-derived row mapping, since GRDB's
mapping is built on `Codable`. Here that's harmless because the actual SQLite
column is already named `start` (the rename happened in the schema via migration
v5), so the encoder writing `start` lines up with the column. The `added`
fallback only ever fires on the JSON import path, where old files are the only
source of that key.

---

## Migrations: versioned, one-way, and sometimes destructive

Schema changes go through a
[`DatabaseMigrator`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations).
Each migration is registered under a name and a closure; GRDB records which
migrations a given database file has already run (in a `grdb_migrations` table)
and, on every launch, applies only the ones not yet seen, in registration order.

```swift
var migrator = DatabaseMigrator()
migrator.registerMigration("v1") { db in /* create tables */ }
migrator.registerMigration("v2") { db in /* ... */ }
// ...
try migrator.migrate(db)
```

The key property: **migrations are append-only and run exactly once per
database.** You never edit a migration that has shipped — a file that already ran
v3 will never run it again, so editing v3 would change history only for fresh
databases and silently diverge from existing ones. You add v7. This is the same
discipline as Rails/Ecto/diesel migrations.

NerfJournal's migration list shows three distinct strategies, escalating in
gentleness as the app matured:

**Wipe-and-recreate (v2, v3).** The early migrations *delete every row and drop
the table*, then recreate it with the new shape:

```swift
migrator.registerMigration("v3") { db in
    try db.execute(sql: "DELETE FROM note")
    try db.execute(sql: "DELETE FROM todo")
    // ... delete the rest, in FK order ...
    try db.execute(sql: "DROP TABLE todo")
    // ... recreate every table with the new schema ...
}
```

Why throw the data away? Because during early development the data *was*
disposable — there were no real journals to protect, and a wipe is far simpler
and less error-prone than writing column-by-column data-preserving SQL. The
choice is a judgment call about what the data is worth at that moment, not a
technical limitation.

Two things in that destructive code are not optional, though:

- **Delete order matters.** Rows are deleted children-first (`note`, then `todo`,
  then `journalPage`, …) because of foreign keys. The v2 comment spells out the
  trap: *"GRDB defers FK checks during migrations, so cascade actions don't fire.
  Delete in dependency order so FK checks pass at commit."* You cannot lean on
  `onDelete: .cascade` here — inside a migration the cascade is suppressed, so you
  must honor the dependency graph by hand.
- **The whole migration is one transaction.** GRDB wraps each migration in a
  transaction by default, so if any statement throws, the entire migration rolls
  back and the file stays at the previous version. A half-applied schema is not a
  state you can reach.

**`ALTER TABLE` (v4, v5).** Once the schema stabilized, later changes preserve
data:

```swift
migrator.registerMigration("v4") { db in
    try db.execute(sql: "ALTER TABLE note DROP COLUMN relatedTodoID")
}
migrator.registerMigration("v5") { db in
    try db.execute(sql: "ALTER TABLE todo RENAME COLUMN added TO start")
}
```

These are the gentle ones: drop a column that was never used, rename a column in
place. No data lost.

**Additive (v1, v6).** The cheapest kind — create new tables that didn't exist
(`exportGroup` and `exportGroupMember` in v6). Nothing existing is touched.

Reading the migrations top to bottom is a compressed history of the app's data
model: a v1 schema with `pageID`/`groupName`/`status` columns, a v2 redesign that
made todos page-spanning, a v3 that introduced categories, and a v6 that added
export groups. The schema you see in `Models.swift` today is the *sum* of all
these migrations, not any single one.

---

## Crossing the actor boundary

`PageStore` is `@MainActor`-isolated (Unit 4; the actor model itself is Unit 9).
The `DatabaseQueue` is not — it runs its closures on its own background queue.
Every database call therefore crosses an isolation boundary, and that's why they
are all `await`ed:

```swift
func addTodo(title: String, shouldMigrate: Bool, categoryID: Int64? = nil) async throws {
    guard page != nil else { return }
    let today = Self.startOfToday
    try await db.dbQueue.write { db in
        var todo = Todo(id: nil, title: title, shouldMigrate: shouldMigrate,
                        start: today, ending: nil, categoryID: categoryID, externalURL: nil)
        try todo.insert(db)
    }
    try await refreshContents()
}
```

`dbQueue.write { ... }` is `async`: the call suspends, the closure runs on the
database queue, and control returns to the main actor when it finishes. The
`await` is the visible seam where the main actor lets go and later picks back up.

What actually travels across that seam is worth being precise about, because it's
the same reference-vs-value question from earlier units. The values *captured*
into the closure (`title`, `today`, the ints) are value types — they're copied
across, so the background queue is working on its own data, not aliasing the main
actor's. And the result that comes *back* (`Todo` arrays, in the read methods) is
likewise a tree of value types: when `refreshContents` does `todos = allTodos`,
it's assigning copies that no longer share anything with the database queue.
There's no shared mutable buffer straddling the boundary — which is precisely why
this is safe, and why Swift's concurrency checker is willing to allow it. (Unit 9
makes the `Sendable` rules behind this explicit; for now, the takeaway is that
value semantics are what make the hand-off clean.)

### `refreshContents`: the two-set read

The read that rebuilds the store's published state issues three queries in one
`read` block, then post-processes on the main actor:

```swift
let (allTodos, fetchedNotes, ft) = try await db.dbQueue.read { db in
    let t = try Todo.filter(Column("start") <= pageDate).fetchAll(db)
    let n = try Note.filter(Column("pageID") == pageID).order(Column("timestamp")).fetchAll(db)
    let f = try Todo.filter(Column("start") > pageDate)
                    .filter(Column("ending") == nil)
                    .order(Column("start"), Column("id")).fetchAll(db)
    return (t, n, f)
}
```

The two `Todo` queries split the table at `pageDate`:

- **`start <= pageDate`** — todos that have appeared on or before this page's day.
  These become the page's `todos` (after one more main-actor filter: a todo whose
  `ending.date` is *before* this page is dropped, so completed-and-gone work
  doesn't linger).
- **`start > pageDate && ending == nil`** — todos scheduled to first appear on a
  *future* day and not yet ended. These become `futureTodos`, which the Future
  Log window and the calendar's orange dots render.

This is the database expression of the "a todo spans pages" model from
`Models.swift`: there's no per-day copy of a todo. A single row, with a `start`
date and an optional `ending`, is *interpreted* against whatever page you're
looking at. The query is where that interpretation happens.

Note `Column("ending") == nil` compiles to SQL `ending IS NULL`. Because the
`ending` column is a JSON string when present and `NULL` when the todo is open,
"is this todo still pending?" is just a null check on that column — no JSON
parsing needed to answer it. The choice to store `nil` as SQL `NULL` (rather than,
say, a JSON `null` string) is what makes that cheap.

Finally, `refreshContents` posts `.nerfJournalTodosDidChange` (Unit 6) so other
stores can react. The full mutation shape is therefore: `await` a `write`,
`await` a `refreshContents` read, assign the `@Published` arrays, post the
notification. Every mutating method on `PageStore` follows that template.

---

## The CLI: GRDB without `Codable`

The `nerf-add-todo` command-line tool (Unit 6's distributed-notification sender)
talks to the *same* SQLite file, but it is a separate Swift package that does not
import the app's `Models.swift`. It re-declares the handful of types it needs —
and in doing so it exposes what `Codable` was quietly doing for the app.

The CLI's `Todo` conforms to `MutablePersistableRecord` but **not** `Codable`:

```swift
struct Todo: MutablePersistableRecord {
    var id: Int64?
    var title: String
    // ...
    static let databaseTableName = "todo"

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    // GRDB's MutablePersistableRecord requires EncodableRecord; without Codable
    // to synthesize it, encode(to:) is written by hand.
    func encode(to container: inout PersistenceContainer) throws {
        container["id"]            = id
        container["title"]         = title
        container["shouldMigrate"] = shouldMigrate
        container["start"]         = start
        container["ending"]        = ending
        container["categoryID"]    = categoryID
        container["externalURL"]   = externalURL
    }
}
```

In the app, GRDB derived this column-mapping for free *because* `Todo` was
`Codable`. The CLI's `Todo` isn't `Codable`, so it must supply the
`encode(to container:)` method explicitly — listing each column by name. This is
the "encoding quirk in a Swift Package" the architecture notes refer to: the
moment a record stops being `Codable`, the convenience evaporates and you write
the mapping yourself. It's not hard, but it's a useful demonstration of where the
magic was coming from — `Codable` synthesis, not GRDB clairvoyance.

The CLI also shows GRDB's *raw SQL* escape hatch for its duplicate check, where
the query builder would be more awkward than a literal statement:

```swift
let titleDup = try Row.fetchOne(
    db,
    sql: "SELECT 1 FROM todo WHERE ending IS NULL AND title = ?",
    arguments: [args.title]
)
```

`Row.fetchOne` with a `?`-placeholder and an `arguments:` array is GRDB's
parameterized-SQL API — the same shape as `DBI`'s `$dbh->selectrow_array($sql,
undef, @bind)`, with the bind values kept separate from the SQL string so there's
no injection surface. The query builder (`Todo.filter(...)`) and raw SQL coexist;
you reach for raw SQL when it reads more clearly, as here.

Two processes, one file, opened by two independently-built `DatabaseQueue`s —
this works because SQLite's own file locking arbitrates between them, and the CLI
sets `config.busyMode = .timeout(5)` so that if the app holds a write lock, the
CLI waits up to five seconds rather than failing immediately. After inserting, it
posts the distributed notification that pokes the running app to re-read.

---

## Reading

- [GRDB](https://github.com/groue/GRDB.swift) — the library; the README is the
  best single reference
- [`DatabaseQueue`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasequeue)
  — serialized access to one connection
- [`FetchableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/fetchablerecord)
  / [`PersistableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/persistablerecord)
  — read and write a struct as a row
- [`DatabaseValueConvertible`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasevalueconvertible)
  — store a custom type as one SQLite value
- [Migrations](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/migrations)
  — `DatabaseMigrator` and the append-only discipline
- [`Codable`](https://developer.apple.com/documentation/swift/codable)
  — Swift's built-in serialization; GRDB rides on it
- [Encoding and Decoding Custom Types](https://developer.apple.com/documentation/foundation/archives-and-serialization/encoding-and-decoding-custom-types)
  — `CodingKeys`, `init(from:)`, `encode(to:)`

---

## Code Tour

### `AppDatabase.swift` lines 54–74: the wrapper and `shared`

The whole database surface is one `DatabaseQueue` property. Read how `shared`
builds the sandboxed path and why `try!` is acceptable at that one spot. Note
that `init` migrates immediately on open.

### `AppDatabase.swift` lines 76–246: the migrator

Read all six migrations in order as a history of the schema. Compare the
destructive v2/v3 (delete-in-FK-order, drop, recreate) against the gentle v4/v5
(`ALTER TABLE`) and additive v1/v6. Re-read the v2 comment about deferred FK
checks until it's clear why the deletes are hand-ordered.

### `Models.swift` lines 109–163: `Todo` as a record

The four-protocol conformance and `didInsert`, then the custom `Codable`
extension. Confirm for yourself why the custom coding lives in an extension
(memberwise init), and trace which key the decoder tries first.

### `Models.swift` lines 85–104: `TodoEnding`, two paths

The cleanest example of `Codable` (export) and `DatabaseValueConvertible`
(SQLite) on one type. Read the comment, then the two method pairs, and identify
which runs on which path.

### `PageStore.swift` lines 475–510: `refreshContents`

The three-query read block and the `start <= pageDate` / `start > pageDate` split.
Map each query to the `@Published` property it fills. Note the extra main-actor
`filter` on `ending.date` and the `.nerfJournalTodosDidChange` post at the end.

### `cli/Sources/nerf-add-todo/main.swift` lines 43–67: a non-`Codable` record

The CLI's `Todo` with a hand-written `encode(to container:)`. Compare it to the
app's `Todo`, which gets the same mapping for free from `Codable`. Then read the
duplicate-check (lines ~215–250) for GRDB's raw-SQL API.

---

## Exercises

**1.** `Todo.id` is `Int64?`. Construct a `Todo` in your head with `id: nil`,
`insert(db)` it, and describe exactly when and how `id` becomes non-nil. What
would break if `didInsert` were not implemented?

**2.** `TodoEnding` stores as a JSON string in one column but exports as a nested
JSON object. Suppose you wanted `ending` to instead occupy two real columns
(`endingDate`, `endingKind`) in the `todo` table. Which protocol conformance
would you change, would it affect the export JSON, and what migration would you
write?

**3.** The v3 migration deletes rows before dropping tables, in a specific order.
What error would you expect if you dropped `journalPage` *before* deleting from
`todo`? Why does `onDelete: .cascade` not save you here?

**4.** `refreshContents` filters todos with `start <= pageDate` in SQL, then
applies a second `ending.date >= pageDate` filter in Swift on the main actor. Why
isn't that second condition pushed into the SQL query like the others? (Hint:
where does `ending` live, and what would it cost to filter on it in SQL?)

**5.** The CLI opens its own `DatabaseQueue` against the same file the app has
open. What does `config.busyMode = .timeout(5)` change about what happens when
both try to write at once? What would happen with the default busy mode?
