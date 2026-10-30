---
title: "Coda: The Software Moved On"
nav_order: 140
---

# Coda: The Software Moved On

Units 1 through 11 describe NerfJournal as a self-contained Mac app: one SQLite file in
its sandbox, a companion CLI that wrote to the same file, and a distributed notification
to tell the app something had changed. That app is preserved, together with the text
written against it, at the git tag
[`edition-local-sqlite`](https://github.com/rjbs/NerfJournal/tree/edition-local-sqlite).
Every file path and line range in those units' Code Tours is accurate at that tag.

After it, the app moved to a new foundation. Units 12 and 13 cover the Swift that came
with the move. This coda covers the rest: what changed, why, and which statements in
Units 1–11 are no longer true of the code.

---

## What changed, and why

The question NerfJournal started with was whether it could be built on an existing task
store rather than its own. Apple's `EKReminder` was the first candidate, and it was
rejected: the type isn't rich enough for NerfJournal's model, and it offers no way to
attach extra properties, even though the iCalendar `VTODO` format underneath would allow
them. JMAP for Tasks was considered next and also set aside as not quite suitable. So
NerfJournal kept its own SQLite database, and Units 1–11 describe that design.

The later insight was that NerfJournal's todo model could be expressed as a standard
JSCalendar `Task` (RFC 8984) with very little invention. A todo's day is the Task's
`start`, marked `showWithoutTime`. Done and abandoned are the standard `progress`
values `completed` and `failed`. A category is the `TaskList` the Task is filed in, with
the default list meaning "no category." The external URL is a standard link. What's left
over takes exactly **two vendor properties**: `autoCancel`, which is the inverse of
`shouldMigrate`, and `endedAt`, which records an ending's day and, when known, its time
of day. The encoding, along with its principles (the server is the source of truth,
only NerfJournal's own properties are ever written, foreign Tasks are read leniently),
is written up in `JMAP-SPEC.md`.

Three new pieces of software made it real:

- **Jinx**, a JMAP sync engine in Swift. It keeps a local copy of the server's objects
  in the app's own SQLite file, queues writes made offline, pushes and fetches,
  listens for the server's push notifications, and watches the shared database for
  commits by other processes on the same Mac. Its design is in `SYNC-DESIGN.md`.
- **TaskMaster**, a JMAP for Tasks server.
- **NerfCore**, the Swift package now shared by the app and the CLI, which holds the
  model types and the code that translates between a `Todo` and a Task (Unit 13).

Journal pages, task bundles, and export groups had no natural home in JMAP for Tasks.
They're client-only state, and they stay in local SQLite tables as before. Todos and
categories moved to the server.

The payoff is that NerfJournal's data is no longer a private file. Any JMAP for Tasks
client, script, or automated agent can file new work, and it appears in the journal on
the next sync, already in the right category. An iOS version can share the same data
without NerfJournal having to build a sync service of its own. The app still works
offline: writes queue locally and go out when the server is reachable.

`MIGRATION-PLAN.md` and `CATEGORY-LISTS-PLAN.md` record the cutover step by step. After
it, the legacy code paths and the whole migration history were deleted, leaving a
single `"schema"` migration for the client-only tables, followed by Jinx's own.

---

## How to read Units 1–11 now

Most of the Swift those units teach is unaffected. Value types, optionals, protocols,
views as values, state and binding, view identity, focus, the AppKit interop of Unit 10,
and swift-argument-parser's declarative model are all as they were, and in many cases
the code that illustrates them hasn't changed either. What aged is the plumbing:
persistence, cross-process notification, the concurrency details, and how the CLI gets
at the model. Where a unit's *concept* still holds but its *example* moved, the map
below says where the example lives now.

Units 6, 7, 9, and 11 changed most. Units 1, 2, 5, and 10 have drifted in details.
Unit 3 is still accurate.

---

## Unit by unit

### Unit 1 — Swift as a Language

- The model types left the app. `NerfJournal/Models.swift` is gone, and the types now
  live, all `public`, in `NerfCore/Sources/NerfCore/Models.swift`.
- `Todo` and `Category` are no longer GRDB records. `Todo` is
  `Identifiable, Codable, Equatable, Sendable` with an explicit `public init`, and it's
  stored as a JMAP Task through `TaskCodec`. Its custom `Codable` extension, and the
  fallback for decoding the old `added` field, are deleted. `TaskBundle`, `BundleTodo`,
  `JournalPage`, and `ExportGroup` are still records.
- `TodoEnding` is now a day plus an optional moment
  (`day: CivilDate`, `time: Moment?`, `kind`), no longer a JSON string in a SQLite
  column.
- `CategoryColor`'s SwiftUI `swatch` moved into an app-side extension,
  `NerfJournal/CategoryColor+Swatch.swift` (Unit 13).
- The Modules section says the CLI "can't reach into the app's Swift code at all."
  It still can't reach the app, but both now import NerfCore, and the CLI writes todos
  through the sync engine, not SQL.

### Unit 2 — Views as Values

- Dates throughout the calendar are `CivilDate` values: `MonthCalendarView` takes
  `today: CivilDate` from the new `DayClock` and sets of `CivilDate`, and `DayCell`'s
  call site compares civil dates instead of calling `isSameDay`.
- `FutureLogRow` formats `todo.start.date()`, since `start` is a `CivilDate`.
- Modifiers, `@ViewBuilder`, composition, and `CategoryLabel` are unchanged.

### Unit 3 — Local State and Binding

Still accurate. `Todo.id` is now the sync engine's local key for the Task, but it's still
an `Int64` and still a stable identity, which is all the unit relies on.

### Unit 4 — Observable Objects and Stores

- There are six stores: `DayClock` publishes the current civil day so views notice
  midnight. `AppDatabase` is a struct that holds a `sync: JournalSync` alongside its
  `dbQueue`, and delegates its schema to `NerfSchema` in NerfCore.
- Stores no longer write todos or categories with `dbQueue.write`. They go through
  `TaskWriter` and `CategoryWriter`, and read through `TaskReader` and
  `sync.categories()`. The "database is the source of truth" principle now has a
  different subject: the JMAP server is authoritative for todos and categories, and the
  local file is the engine's cache.
- `refreshContents` makes one `reader.todos()` call and filters the result twice in
  memory, where it used to run two queries.
- `PageStore` and `CategoryStore` reload from the engine's change stream (Unit 12)
  instead of a distributed-notification observer.

### Unit 5 — App Structure and Multiple Windows

- A fifth scene, `Settings { SyncSettingsView() }`, holds the server settings and the
  engine's status.
- `AppDelegate` now has two jobs at launch: it starts the sync engine (Unit 12's
  `Task.detached`) and, except in the Dev build, registers the global hot key.
- Factory Reset empties only this Mac. The server keeps its data, and the next sync
  fetches it again.

### Unit 6 — Focus, Cross-Window Communication, and Notifications

- The focus material is unchanged.
- The in-process notification names moved to the new bundle id prefix,
  `systems.semiotic.nerfjournal.…`. The notifications still exist for whole-database
  events like import and reset.
- **The cross-process section no longer applies.** `DistributedNotificationCenter`
  is gone from the codebase. Each process's sync engine posts a Darwin notification
  named after the database file's path when it commits, other engines on the same file
  read the new entries from the database's change journal, and every committed change
  reaches the stores through `engine.changes()`. The chain the unit's last exercise
  traces is now: CLI write → Darwin notification → the app's engine reads the journal →
  `changes()` → `refreshContents()`.

### Unit 7 — Persistence with GRDB

- GRDB still holds the client-only tables, but there's no `todo` or `category` table.
  Todos and categories live in Jinx's tables (`jinx_object`, `jinx_pending`, …) in the
  same file, as Task and TaskList objects.
- The migration history the unit walks through (wipe-and-recreate, `ALTER TABLE`,
  additive, Swift-side transforms) has been deleted. One migration, `"schema"`,
  creates the client tables, followed by Jinx's own migrations. The `DatabaseMigrator`
  concepts are still right, but nothing in the code illustrates them any more.
- `TodoEnding` and `CategoryColor` no longer conform to `DatabaseValueConvertible`. The
  two-serialization-paths idea is still well illustrated by `CivilDate`
  (`NerfCore/Sources/NerfCore/CivilDate.swift`), which is both `Codable` and
  `DatabaseValueConvertible` as `"YYYY-MM-DD"`. `TaskCodec` adds a third mapping, from a
  `Todo` to a JSCalendar Task.
- The CLI section's hand-written `encode(to container:)` and re-declared records are
  gone: the CLI imports NerfCore (Unit 13).

### Unit 8 — Undo, Transactions, and Correctness

- Mutations now read `writer.update(key) { $0.ending = … }`. `defaultEndingDate` became
  `defaultEnding(kind:)`, which gives a day-only ending on a past page.
- **The identity argument no longer holds.** `restoreTodo` and `restoreBulkTodos` can't
  re-insert a todo with its original `id`, because a destroyed Task can't come back.
  As the code puts it, undo "recreates the todos as new Tasks: same content, new
  identity." Both consequences the unit says the old design avoided now happen: a
  restored todo sorts as new, and earlier undo steps that refer to the old id no
  longer find it.
- Bulk operations are still atomic, now as one engine write per `TaskWriter` call, which
  is also one batch to the server.
- The scheduling of undo actions, the redo discussion, and `setBulkCategory`'s use of
  `todos + futureTodos` are unchanged.

### Unit 9 — Swift Concurrency

- **"No custom actors" and "exactly two isolation domains" are no longer true.**
  NerfCore's `JournalSync` and Jinx's `SyncEngine` are actors (Unit 12).
- The app builds in Swift 6 mode with a main-actor default, so the explicit
  `@MainActor` on the stores is now redundant (Unit 12).
- The GRDB `write` signature at the center of "Crossing the seam" is now one step
  removed: store mutations cross into the `JournalSync` and `SyncEngine` actors through
  `TaskWriter`, whose change closures are `@Sendable (inout Todo) -> Void`. The
  `Sendable` reasoning is the same.
- `JournalStore.selectDate` now awaits twice, once for the page and once for the todos,
  though its published properties are still assigned together after both.
- `Todo` is a public type in another module, so its `Sendable` conformance is declared,
  not inferred (Unit 12).
- The observer-plus-`Task` pattern survives for in-process notifications. The change
  stream's `for await` loop, cancelled by an `isolated deinit`, is the newer pattern.
- In `AppDelegate`, only the Carbon callback's `assumeIsolated` remains. `DayClock` has
  three more.

### Unit 10 — AppKit Interoperability and the Quick-Entry Panel

- `applicationDidFinishLaunching` also starts the sync engine.
- `QuickNoteStore.addTodo` creates the todo with `TaskWriter`, writing a page to
  `dbQueue` only for a done todo, and no longer posts a notification. The ownership
  argument (only a done thing needs a page) is unchanged.
- `DateParser` is no longer vendored into two targets. It lives once, `public`, in
  `NerfCore/Sources/NerfCore/DateParser.swift`, and both programs import it. The
  framework-free-module lesson is better illustrated than before.
- The panel, the nonactivating style, the Combine resize pipeline, and the lazy load
  are unchanged.

### Unit 11 — The Command-Line Tool

- The manifest depends on `../NerfCore` by path, takes GRDB `from: "7.0.0"` (not a
  branch), declares tools version 6.2, and enables two upcoming features (Unit 12).
- Every command is an `AsyncParsableCommand` with `run() async throws`, and there are
  two more: `nerf sync` and `nerf sync-status`.
- `DatabaseOptions` honors `NERF_DATABASE`, and its `openSync()` builds a `JournalSync`
  from the app's saved server settings.
- **"Two programs, one schema: deliberate duplication" no longer applies.** The model
  types moved into NerfCore, which is the change the unit's fifth exercise imagines.
  The CLI keeps only `typealias Category = NerfCore.Category`, for the reason Unit 13
  explains.
- `done` and `abandon` no longer fetch, check, and update inside one transaction. They
  read the todos, check them, and then issue a separate `TaskWriter.update`. The race
  described in the unit's fourth exercise therefore applies to the current code.
- The property-wrapper parser, `@OptionGroup`, `ValidationError`, `CLIError`, the
  `--json` explicit nulls, OSC 8 links, and `Palette`'s use of SwiftUI colors are
  unchanged.
