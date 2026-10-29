# NerfJournal

A macOS bullet-journal app for tracking daily work. Each morning you
start a new page, declare what you're going to do, and check things off
through the day. The app keeps a permanent record of what was intended,
what got done, and what was deferred.

## Concept

The workflow it supports:

- Some tasks are **habitual** — things you do every day (or every Monday,
  or at the start of a sprint). If you don't do them, they just didn't
  happen; they don't follow you to the next day.
- Some tasks are **one-offs** — specific things chosen for that day. If
  you don't finish them, they carry forward until you do.
- At the end of the day (or the start of the next one), the record is
  permanent. You can see what was on your list, what you completed, and
  how long a deferred task has been kicking around.

This maps loosely to the [Bullet Journal](https://bulletjournal.com/)
method, where tasks can be completed (×), migrated forward (>), or
abandoned (struck through).

## Data Model

**JournalPage** — one per calendar day. Created when you press "Start
Today".

**Todo** — a task. A todo is not duplicated across pages; it is visible
on any day from its `start` date until it ends. Todos live on a JMAP for
Tasks server as JSCalendar Tasks, encoded as `JMAP-SPEC.md` describes,
and the app works from a local copy kept in sync by the
[Jinx](../Jinx) engine (see `SYNC-DESIGN.md`). A todo's `id` is the sync
engine's local key for its Task; its Task also carries a `uid`, chosen
at creation, which is the identity that survives export and import. Key
fields:
- `shouldMigrate`: if true, the todo carries forward indefinitely until
  completed or explicitly abandoned. If false, pressing "Start Today"
  automatically abandons it.
- `start`: the date the task first becomes active. Todos with a `start`
  date beyond the current page appear only in the Future Log.
- `ending`: nil if still pending; otherwise a `TodoEnding` with a `date`
  and `kind` (`.done` or `.abandoned`).
- `categoryID`: optional reference to a `Category` for display grouping.
  On the server this is which TaskList the Task is in.
- `externalURL`: optional URL, shown as a clickable link icon on the row.

**Category** — a named, colored grouping. Fields: `name`,
`color` (one of eight named swatches: blue, red, green, orange, purple,
pink, teal, yellow), `sortOrder`. Todos on a page are grouped by
category, sorted by `sortOrder`, with uncategorized todos in an "Other"
section at the end. A category is a TaskList on the server: the list
flagged default is "no category," every other list is a category, and
the list's name, color and sort order are the category's. A category's
`id` is the sync engine's local key for its list, as a todo's is for
its Task. Creating a category pushes its list to the server at once,
and deleting one moves its todos to the default list first, because a
Task can only be filed in a list the server already knows.

Pages, bundles, and export groups are client-only and stay in the local
SQLite database. Todos and categories sync.

**TaskBundle** — a named collection of todos that can be applied to
today's page all at once. Examples: "Daily", "Sprint Start", "On-Call
Handoff". Has a `todosShouldMigrate` flag that sets `shouldMigrate` on
all todos it creates.

**BundleTodo** — one item within a TaskBundle. Has `categoryID` and
`externalURL`, both carried over to the live Todo when the bundle is
applied.

## Architecture

- **`AppDatabase`** — wraps a GRDB `DatabaseQueue`, owns the SQLite
  file, creates the schema, and builds the process's one
  `JournalSync`. The file lives under the app's sandbox container:
  `~/Library/Containers/org.rjbs.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite`
  and holds both the client-only tables and the sync engine's `jinx_`
  tables. `AppDelegate` starts the engine at launch, which runs push,
  pull, EventSource push notifications, and journal tailing until quit.
- **`PageStore`** — `@MainActor ObservableObject` that publishes the
  current page's todos and future-scheduled todos (`futureTodos`),
  and exposes mutating actions: start today, complete/uncomplete/abandon/
  mark-pending todo, add todo, delete todo, rename todo, set category,
  set URL, send to date, apply bundle. Every mutation is one engine
  write through `TaskWriter`; reads go through `TaskReader`. "Start
  Today" creates a new page and sweeps: every pending non-migratable
  todo that started before today is abandoned as of its start day. The
  store reloads on the engine's change stream, which carries its own
  writes, what syncs in from the server, and what another process on
  the same database (such as the CLI tool below) commits, so the UI
  updates live without any notification from the writer.
- **`JournalStore`** — `@MainActor ObservableObject` that indexes all
  pages and provides read-only access to any past page's todos and
  notes. Drives the calendar popover's highlighted dates.
- **`BundleStore`** — `@MainActor ObservableObject` that manages
  TaskBundles and their BundleTodos.
- **`CategoryStore`** — `@MainActor ObservableObject` that manages
  Categories: add, delete, rename, recolor, reorder.
- **`JournalView`** — the main window (Cmd-1). A calendar popover
  (toolbar button) shows the month with highlighted dots for days that
  have pages (blue) or future-scheduled work (orange). The detail pane
  shows today's page as editable via `PageStore`; older pages are shown
  read-only from `JournalStore`. When a date has no page, the pane shows
  any future-log todos for that day (with full context-menu controls) and
  a "Start Today" prompt when applicable. Todos are grouped by category.
  Keyboard navigation: arrow keys select rows, Return edits a title,
  Cmd-Return toggles done/pending, Escape deselects, Cmd-N focuses the
  add-todo field, Cmd-T jumps to today, Cmd-L jumps to the most recent page.
- **`FutureLogView`** — a separate window (Cmd-2) listing all pending
  todos whose `start` date is beyond the current page. Rows show a
  category pip, abbreviated date, and title. Context menu: send to
  today, send to a chosen date, set category, set URL, delete. Title
  editing and multi-select work the same as the main journal view.
- **`BundleManagerView`** — a separate window (Cmd-3) for managing
  bundles and categories. The left panel is split: bundles on top,
  categories below (drag to reorder, color and name editable via context
  menu). The right panel shows the selected bundle's todos, grouped by
  category, with drag-to-reorder within each group. Bundles are applied
  to today's page from a toolbar menu in the main window.

Todos are stored on a JMAP for Tasks server; everything else is local
SQLite. The server's session URL and account id are set in the app's
Settings window (Cmd-,), which also shows the engine's status: connection,
last fetch and push, the count waiting to send, the last failure, and any
todos the server refused with their errors. Settings take effect at the
next launch. The app works offline: writes queue locally and push when
the server is reachable. Factory Reset (Debug menu) empties this Mac,
pending changes included, and never touches the server; the next sync
fetches its tasks again.

## Shared Package

`NerfCore/` is a Swift package holding everything the app and the CLI
both need and nothing that is UI: `CivilDate` and `Moment`, the record
types, the schema (`NerfSchema`), the export snapshot type,
the quick-entry date parser, and the whole JMAP side: `TaskCodec` (the
Todo-to-Task encoding from `JMAP-SPEC.md`), `TaskListIndex` (the
lists as categories), `JournalSync` (the Jinx engine assembled for the
journal, plus export, import, and reset),
`TaskReader`, `TaskWriter`, and `CategoryWriter`.
It depends on [Jinx](../Jinx), expected as a sibling checkout at
`../Jinx`. The app links NerfCore as a local package dependency; the
CLI depends on it by path. Its tests run against Jinx's in-process
scripted JMAP server, with no network, via `cd NerfCore && swift test`.

## CLI Tool

`cli/` contains a Swift Package, `nerf`, that opens the same journal
database as the app and reads and writes todos through the same sync
engine. A write lands in the shared local store, is pushed to the server
once (a server that cannot be reached is a warning, not a failure; the
app pushes later), and reaches a running app through the engine's
cross-process journal, so the UI updates with no notification from the
CLI. Server settings come from `NERF_JMAP_URL` and `NERF_JMAP_ACCOUNT`,
defaulting to the prototype server. It is built with
[swift-argument-parser](https://github.com/apple/swift-argument-parser)
and dispatches to subcommands, so it grows as new chores come up. Useful
for scripts that gather work items (GitHub PRs, Linear tickets, etc.) and
add them programmatically with proper exit-code feedback.

```
cd cli && swift build -c release
cp .build/release/nerf ~/bin
```

Run `nerf --help` for the subcommand list, or `nerf help <subcommand>`
for the details of one.

### `nerf add-todo`

```
nerf add-todo [--no-migrate] [--category NAME] [--strict] [--url URL] [--start WHEN] TITLE...
```

- `--no-migrate`: mark the todo as non-migratable (default: migratable)
- `--category NAME`: assign to a named category (case-insensitive; warns
  and continues without category if not found)
- `--strict`: when `--category` names an unknown category, create nothing
  and exit nonzero instead of warning and continuing
- `--url URL`: set an `externalURL` on the todo
- `--start WHEN`: set the todo's start date. Accepts the same shorthand as
  the app's `~` quick-entry — `today`, `tomorrow`, a weekday (`wed`), `+Nd`
  (days), or `+Nw` (weeks) — as well as an ISO 8601 date (`2026-07-20`) or
  timestamp (`2026-07-20T09:00:00Z`). Since a todo's start is a day rather
  than a moment, a timestamp is reduced to the start of its day in the local
  calendar. A future date lands the todo in the Future Log; omitting
  `--start` starts it today as before.
- `--database PATH`: override the default database path. The `NERF_DATABASE`
  environment variable sets the default instead, so a shell can be pointed
  at another database (such as the dev build's container, see Building)
  for a whole session.

Exits 0 on success (quiet), 1 on any error (message to stderr). A todo
starting today requires today's journal page to already exist; a
future-dated todo (`--start tomorrow`, etc.) is filed into the Future Log
and needs no page, so you can queue Monday's work on a Saturday.

From Perl:
```perl
system('nerf', 'add-todo', '--category', 'GitHub', "Review PR #$pr_number")
    == 0 or die "nerf add-todo failed: $?";
```

### `nerf categories`

```
nerf categories [--json] [--database PATH]
```

Lists the defined categories in display order, one per line, each
prefixed with a filled circle (●) drawn in the category's color via a
24-bit-color ANSI escape, followed by the name and color name.

- `--json`: emit a JSON array of `{"name", "color"}` objects instead,
  where `color` is a CSS `#aabbcc` string. Handy for piping to other
  tools.

### `nerf todo`

```
nerf todo [--json] [--database PATH]
```

Prints today's remaining (still-open) todos — including work carried
forward from earlier days, but not Future Log items dated ahead — grouped
by category in the same order as the journal page view: categories by
their sort order, then an "Other" group for uncategorized work. Each group
header is the category's colored circle (●) and name; each todo whose
`externalURL` is set has its title hyperlinked via an OSC 8 terminal
escape. If today has no journal page yet, the items are printed anyway.

- `--json`: emit a JSON array of `{"id", "title", "category", "start",
  "url"}` objects instead (in the same order), with `category` and `url`
  null when unset and `start` as an ISO 8601 timestamp.

### `nerf done` / `nerf abandon`

```
nerf done ID [--database PATH]
nerf abandon ID [--database PATH]
```

End the todo with the given id (the same ids `nerf todo --json` reports),
setting its ending to the current time — `done` or `abandoned`
respectively. Both exit nonzero with a message, changing nothing, if the
id matches no todo, if the todo hasn't started yet (a Future Log item), or
if it has already been ended.

### `nerf sync` / `nerf sync-status`

```
nerf sync [--database PATH]
nerf sync-status [--database PATH]
```

`sync` runs one pass of the engine, pushing whatever is waiting and
fetching what changed on the server, then prints the status report:
server, account, connection, last fetch and push, and the count still
waiting to send. It exits nonzero if the server could not be reached.
`sync-status` prints the same report without syncing (so the timestamps
read "never (this run)"), followed by any todos the server refused and
the error it gave for each.

## Future Plans

Roughly in priority order:

**Near term**
- Bundle auto-apply: apply selected bundles automatically on "Start
  Today" based on day of week, rather than requiring manual application
  each morning
- Calendar-aware migration routing: a todo could specify which days of
  the week it migrates to, so e.g. a Friday work task carries to Monday
  rather than Saturday, while a personal task carries to Saturday.

**Medium term**
- Slack integration: post today's one-off todos to a configured channel
  at the start of the day; individual items can be marked private to
  exclude them

**Longer term**
- Linear sprint integration: show your current sprint, pick tasks to add
  as todos
- Notion publishing: generate a "work diary" page summarizing a day's
  page and post it to a configured Notion database

## Testing

NerfCore has a test suite (`cd NerfCore && swift test`): the date types,
the Task codec against the spec's worked examples and every lenient-read
rule, and the engine wiring, list index, reader, writers, and
export/import/reset, all against Jinx's in-process scripted JMAP
server. Test cases are written as calls to named helpers that take the
inputs and expected outputs, with the rig construction hidden.

The app itself has no automated tests. The architecture is amenable to
them; here is where to start.

**Store / mutation tests** (highest value) — `AppDatabase` accepts a `path:`
argument; pass `":memory:"` to get a fresh in-memory SQLite for each test.
The stores can then be exercised against a real database without touching disk
or launching the UI. Good candidates: `completeTodo`, `abandonTodo`,
`bulkDelete`, `applyBundle`, `setEndingTime`; assert DB state and undo
behavior. Stores are `@MainActor`, so test methods should also be `@MainActor`
or use `await MainActor.run { ... }`.

**Export tests** — `exportPageHTML` and `exportPageMrkdwn` are pure functions;
exercise them with known todo/category fixtures and assert the output strings.

**UI tests** (`XCUITest`) — slow, brittle, and require the app to inject a test
database via a launch argument. Probably not worth the effort for a personal app.

## Refactoring Queue

Known structural improvements that aren't urgent but are worth doing:

- **`CategoryHeaderView` component** — `JournalView` and
  `BundleManagerView` each contain a private function that renders the
  same `HStack { colored dot + category name/"Other" }` header. Extract
  to a shared view.

- **Category-grouping helper** — the logic that groups items by
  `categoryID`, sorts named groups by `sortOrder`, and collects orphaned
  IDs into "Other" appears independently in `JournalView`,
  `BundleManagerView`, and `HTMLExport`. A generic free function
  (constrained to types with `categoryID: Int64?`) would centralize it.

- **Undo boilerplate in `PageStore`** — the half-dozen mutating methods
  all follow the same pattern: capture old value → write DB → register
  undo closure → refresh. A helper that takes forward and reverse
  operations and handles the `Task { @MainActor in … }` dance would
  reduce the repetition.

## Building

Requires macOS 27+, Xcode 27+. Uses [GRDB](https://github.com/groue/GRDB.swift)
for local persistence and [Jinx](../Jinx) for JMAP sync, the former a
remote Swift Package dependency and the latter a local one that must be
checked out beside this repository as `../Jinx`. At runtime the app needs
a JMAP for Tasks server; the default is the prototype on
`http://127.0.0.1:8080`, account `rjbs`.

The app is sandboxed. Set your Development Team in Xcode's Signing &
Capabilities tab before building.

There are two shared schemes. `NerfJournal` builds the app you install
(Debug or Release, bundle id `org.rjbs.nerfjournal`). `NerfJournal Dev`
builds the `Dev` configuration: bundle id `org.rjbs.nerfjournal.dev`,
displayed as "NerfJournal Dev", compiled with the `DEV` condition. The
sandbox gives it its own container, so its database is
`~/Library/Containers/org.rjbs.nerfjournal.dev/Data/Library/Application Support/NerfJournal/journal.sqlite`
and it can run beside the installed app without touching its data. Under
`DEV` the app does not register the global quick-entry hot key, which
only one process can own. Point the CLI at the dev database with
`NERF_DATABASE`.
