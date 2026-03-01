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

**JournalPage** — one per calendar day. Created manually with "Start
Today", which closes out the previous page.

**Todo** — a task on a page. Key fields:
- `shouldMigrate`: if true and left pending at day-close, a fresh copy
  appears on tomorrow's page. If false, it's marked abandoned.
- `status`: `pending`, `done`, `abandoned`, or `migrated`.
- `firstAddedDate`: the date this task was *originally* added, carried
  forward across migrations. Shows how long a task has been deferred.
- `groupName`: used for display grouping; set automatically when a todo
  is instantiated from a Bundle.

**Note** — a timestamped log entry on a page. Can be freeform text, or
a system event (like task completion) linked back to a Todo via
`relatedTodoID`. Completing a todo automatically creates a Note.

**TaskBundle** — a named collection of todos that can be applied to a
page all at once. Examples: "Daily" (applied every work day), "Monday"
(applied on Mondays), "Sprint Start". Each bundle has a
`todosShouldMigrate` flag that determines carryover behavior for all
its todos.

**BundleTodo** — one item within a TaskBundle.

## Architecture

- **`AppDatabase`** — wraps a GRDB `DatabaseQueue`, owns the SQLite
  file at `~/Library/Application Support/NerfJournal/journal.sqlite`,
  and runs schema migrations.
- **`LocalJournalStore`** — `@MainActor ObservableObject` that
  publishes the current (most recent) page's todos and notes, and
  exposes mutating actions: start today, complete/uncomplete/abandon
  todo, add todo, move todos, rename todo, apply bundle. The day-start
  logic runs atomically: previous page todos are migrated/abandoned and
  carried-over items are inserted on the new page in one transaction.
- **`DiaryStore`** — `@MainActor ObservableObject` that indexes all
  pages and provides read-only access to any past page's todos and
  notes. Drives the calendar sidebar's highlighted dates.
- **`BundleStore`** — `@MainActor ObservableObject` that manages
  TaskBundles and their BundleTodos.
- **`DiaryView`** — the main window. A calendar sidebar (toggleable,
  state persisted, window expands left when shown into a narrow window)
  sits beside a detail pane. The most recent page is editable via
  `LocalJournalStore`; older pages are shown read-only from
  `DiaryStore`. Keyboard navigation: arrow keys select rows, Return
  edits a title, cmd-Return toggles done/pending, cmd-N focuses the
  add-todo field.
- **`BundleManagerView`** — a separate window for creating and editing
  bundles. Bundles can be applied to today's page from a toolbar menu
  in the main window.

Storage is local SQLite only. No iCloud sync or server component yet.

## Future Plans

Roughly in priority order:

**Near term**
- Notes UI: ability to add freeform notes to the current page (the data
  model and display are in place; only the add UI is missing)
- Bundle auto-apply: apply selected bundles automatically on "Start
  Today" based on day of week, rather than requiring manual application
  each morning
- Calendar-aware migration routing: a todo could specify which days of
  the week it migrates to, so e.g. a Friday work task carries to Monday
  rather than Saturday, while a personal task carries to Saturday.
  Likely expressed as a property on the todo or its source bundle.

**Medium term**
- Slack integration: post today's one-off todos to a configured channel
  at the start of the day; individual items can be marked private to
  exclude them
- Global keyboard shortcut to log a freeform note from anywhere, without
  switching to the app

**Longer term**
- Linear sprint integration: show your current sprint, pick tasks to add
  as todos
- External ticket linking: associate a todo with a Linear, GitHub, or
  GitLab issue URL
- Notion publishing: generate a "work diary" page summarizing a day's
  page and post it to a configured Notion database
- Server sync: a small personal server component to allow other agents
  or devices to add todos; would unlock mobile access and automation

## Building

Requires macOS 14+, Xcode 15+. Uses [GRDB](https://github.com/groue/GRDB.swift)
for local persistence, added as a Swift Package dependency. No other
external dependencies.

No App Sandbox. TCC still gates any future permissions
(Reminders, Contacts, etc.) via the generated Info.plist.
