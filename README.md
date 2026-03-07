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
on any day from its `start` date until it ends. Key fields:
- `shouldMigrate`: if true, the todo carries forward indefinitely until
  completed or explicitly abandoned. If false, pressing "Start Today"
  automatically abandons it.
- `start`: the date the task first becomes active. Todos with a `start`
  date beyond the current page appear only in the Future Log.
- `ending`: nil if still pending; otherwise a `TodoEnding` with a `date`
  and `kind` (`.done` or `.abandoned`).
- `categoryID`: optional FK to a `Category` for display grouping.
- `externalURL`: optional URL, shown as a clickable link icon on the row.

**Category** — a named, colored grouping. Fields: `name`,
`color` (one of eight named swatches: blue, red, green, orange, purple,
pink, teal, yellow), `sortOrder`. Todos on a page are grouped by
category, sorted by `sortOrder`, with uncategorized todos in an "Other"
section at the end.

**Note** — a timestamped freeform text entry attached to a page.

**TaskBundle** — a named collection of todos that can be applied to
today's page all at once. Examples: "Daily", "Sprint Start", "On-Call
Handoff". Has a `todosShouldMigrate` flag that sets `shouldMigrate` on
all todos it creates.

**BundleTodo** — one item within a TaskBundle. Has `categoryID` and
`externalURL`, both carried over to the live Todo when the bundle is
applied.

## Architecture

- **`AppDatabase`** — wraps a GRDB `DatabaseQueue`, owns the SQLite
  file, and runs schema migrations. The file lives under the app's
  sandbox container:
  `~/Library/Containers/org.rjbs.nerfjournal/Data/Library/Application Support/NerfJournal/journal.sqlite`
- **`PageStore`** — `@MainActor ObservableObject` that publishes the
  current page's todos, notes, and future-scheduled todos (`futureTodos`),
  and exposes mutating actions: start today, complete/uncomplete/abandon/
  mark-pending todo, add todo, delete todo, rename todo, set category,
  set URL, send to date, apply bundle. "Start Today" creates a new page
  and abandons any pending non-migratable todos from before today in one
  atomic transaction. Also observes `DistributedNotificationCenter` for
  `org.rjbs.nerfjournal.externalChange` and refreshes when it fires, so
  external writers (such as the CLI tool below) update the UI live.
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

Storage is local SQLite only. No iCloud sync or server component.

## CLI Tool

`cli/` contains a standalone Swift Package, `nerf-add-todo`, that
inserts a todo into today's journal page directly via SQLite, then
notifies the running app to refresh immediately. Useful for scripts that
gather work items (GitHub PRs, Linear tickets, etc.) and add them
programmatically with proper exit-code feedback.

```
cd cli && swift build -c release
cp .build/release/nerf-add-todo /usr/local/bin/
```

```
nerf-add-todo [--no-migrate] [--category NAME] [--url URL] TITLE...
```

- `--no-migrate`: mark the todo as non-migratable (default: migratable)
- `--category NAME`: assign to a named category (case-insensitive; warns
  and continues without category if not found)
- `--url URL`: set an `externalURL` on the todo
- `--database PATH`: override the default database path (for testing)

Exits 0 on success (quiet), 1 on any error (message to stderr). The
tool requires today's journal page to already exist.

From Perl:
```perl
system('nerf-add-todo', '--category', 'GitHub', "Review PR #$pr_number")
    == 0 or die "nerf-add-todo failed: $?";
```

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

No automated tests exist yet. The architecture is amenable to them; here is
where to start.

**Store / mutation tests** (highest value) — `AppDatabase` accepts a `path:`
argument; pass `":memory:"` to get a fresh in-memory SQLite for each test.
The stores can then be exercised against a real database without touching disk
or launching the UI. Good candidates: `completeTodo`, `abandonTodo`,
`bulkDelete`, `applyBundle`, `setEndingTime`; assert DB state and undo
behavior. Stores are `@MainActor`, so test methods should also be `@MainActor`
or use `await MainActor.run { ... }`.

**Export tests** — `exportPageHTML` and `exportPageMrkdwn` are pure functions;
exercise them with known todo/category fixtures and assert the output strings.

**Migration tests** — create a pre-migration DB via raw SQL, run the migrator,
verify the target tables exist and any preserved data survived correctly.

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

Requires macOS 14+, Xcode 15+. Uses [GRDB](https://github.com/groue/GRDB.swift)
for local persistence, added as a Swift Package dependency. No other
external dependencies.

The app is sandboxed. Set your Development Team in Xcode's Signing &
Capabilities tab before building.
