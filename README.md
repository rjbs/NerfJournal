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
- `groupName`: set when a todo is instantiated from a Bundle; used for
  display grouping.

**Note** — a timestamped log entry on a page. Can be freeform text, or
a system event (like task completion) linked back to a Todo via
`relatedTodoID`. Completing a todo automatically creates a Note, which
the user can later annotate.

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
  publishes the current page's todos and notes, and exposes actions
  (start today, complete/abandon todo, add todo/note). The core
  day-start logic runs atomically: previous page todos are
  migrated/abandoned, and carried-over items are inserted on the new
  page, all in one transaction.
- **`ContentView`** — SwiftUI view showing today's page. Todos are
  grouped by bundle name; ungrouped one-offs follow.

Storage is local SQLite only. No iCloud sync or server component yet.

## Future Plans

Roughly in priority order:

**Near term**
- Bundle management UI (create bundles, add/remove todos, apply to page)
- Mark a todo as abandoned manually (not just at day-close)
- Notes UI (view and add notes on a page)
- Work diary view (read-only log of past pages)

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
