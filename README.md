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
on any day from its `added` date until it ends. Key fields:
- `shouldMigrate`: if true, the todo carries forward indefinitely until
  completed or explicitly abandoned. If false, pressing "Start Today"
  automatically abandons it.
- `added`: the date the task was first created.
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
- **`LocalJournalStore`** — `@MainActor ObservableObject` that
  publishes the current page's todos and notes, and exposes mutating
  actions: start today, complete/uncomplete/abandon/mark-pending todo,
  add todo, delete todo, rename todo, set category, set URL, apply
  bundle. "Start Today" creates a new page and abandons any pending
  non-migratable todos from before today in one atomic transaction.
  Also observes `DistributedNotificationCenter` for
  `org.rjbs.nerfjournal.externalChange` and refreshes when it fires,
  so external writers (such as the CLI tool below) update the UI live.
- **`DiaryStore`** — `@MainActor ObservableObject` that indexes all
  pages and provides read-only access to any past page's todos and
  notes. Drives the calendar sidebar's highlighted dates.
- **`BundleStore`** — `@MainActor ObservableObject` that manages
  TaskBundles and their BundleTodos.
- **`CategoryStore`** — `@MainActor ObservableObject` that manages
  Categories: add, delete, rename, recolor, reorder.
- **`DiaryView`** — the main window. A calendar sidebar (toggleable)
  sits beside a detail pane. Today's page is editable via
  `LocalJournalStore`; older pages are shown read-only from
  `DiaryStore`. Todos are grouped by category. Keyboard navigation:
  arrow keys select rows, Return edits a title, Cmd-Return toggles
  done/pending, Escape deselects, Cmd-N focuses the add-todo field,
  Cmd-T jumps to today.
- **`BundleManagerView`** — a separate window for managing bundles and
  categories. The left panel is split: bundles on top, categories below
  (drag to reorder, color and name editable via context menu). The right
  panel shows the selected bundle's todos, grouped by category, with
  drag-to-reorder within each group. Bundles are applied to today's page
  from a toolbar menu in the main window.

Storage is local SQLite only. No iCloud sync or server component.

## CLI Tool

`cli/` contains a standalone Swift Package, `add-nerf-todo`, that
inserts a todo into today's journal page directly via SQLite, then
notifies the running app to refresh immediately. Useful for scripts that
gather work items (GitHub PRs, Linear tickets, etc.) and add them
programmatically with proper exit-code feedback.

```
cd cli && swift build -c release
cp .build/release/add-nerf-todo /usr/local/bin/
```

```
add-nerf-todo [--no-migrate] [--category NAME] [--url URL] TITLE...
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
system('add-nerf-todo', '--category', 'GitHub', "Review PR #$pr_number")
    == 0 or die "add-nerf-todo failed: $?";
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
- Global keyboard shortcut to log a freeform note from anywhere, without
  switching to the app

**Longer term**
- Linear sprint integration: show your current sprint, pick tasks to add
  as todos
- Notion publishing: generate a "work diary" page summarizing a day's
  page and post it to a configured Notion database

## Building

Requires macOS 14+, Xcode 15+. Uses [GRDB](https://github.com/groue/GRDB.swift)
for local persistence, added as a Swift Package dependency. No other
external dependencies.

The app is sandboxed. Set your Development Team in Xcode's Signing &
Capabilities tab before building.
