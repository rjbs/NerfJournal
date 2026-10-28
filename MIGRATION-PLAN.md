# Migration plan: SQLite todos to JMAP Tasks via Jinx

Companion to JMAP-SPEC.md (the encoding) and SYNC-DESIGN.md (the engine
requirements, implemented by Jinx).  This is the ordered list of
deliverable chunks for NerfJournal.  Each is mergeable on its own and
leaves the app and the CLI working against the existing SQLite data.

Revised 2026-10-28, after chunks 1 and 1b landed and Jinx reached a
usable state (builds, 156 tests pass, API as agreed).

## Ground rules

*   **The installed app keeps working throughout.**  Development happens
    in a separate build with its own bundle identifier, so its sandbox
    container, and therefore its `journal.sqlite`, is separate from the
    installed app's.  Nothing in the plan touches the installed
    container until the cutover step, and that step begins with a file
    copy of the database.
*   **The server is the prototype** at `http://127.0.0.1:8080`, account
    `rjbs`, no authentication.  Development will leave junk tasks there;
    the cutover wipes them before the real data is adopted.
*   **Jinx is consumed as a local package** at `../Jinx`, pinned by
    path, so NerfJournal always builds against the checkout.
*   **Legacy data migration is a schema migration plus a startup step**,
    not a separate tool.  Any launch of the new code on an old database
    performs it, idempotently.  That is what makes the cutover a single
    launch, and what lets it be rehearsed on a copy first.

## Done

*   Chunk 1: `NerfCore` package (models, CivilDate and Moment, the
    migrations as `NerfSchema`, export type, date parser).
*   Chunk 1b: Swift 6 language mode for the app (main-actor default),
    NerfCore, and the CLI (nonisolated default, since ArgumentParser's
    `run()` is a nonisolated synchronous requirement).
*   macOS 27 floor.

## Chunk 0: groundwork (done 2026-10-28)

Small, independent changes that every later chunk assumes.  All landed:
GRDB resolves to 7.11.1 everywhere, NerfCore depends on Jinx (its test
target on the scripted server too), the CLI honors `NERF_DATABASE`, the
sandbox allows outgoing connections, and the `NerfJournal Dev` shared
scheme builds the `Dev` configuration.  The dev build was launched
beside the installed app and created its own container.

*   **GRDB requirement.**  NerfCore, the CLI, and the app all depend on
    GRDB by `branch: master`; Jinx depends on it `from: "7.0.0"`.  One
    package graph cannot hold both.  Switch all three to the version
    requirement.
*   **Dev build.**  A `Dev` build configuration duplicating Debug with
    `PRODUCT_BUNDLE_IDENTIFIER = org.rjbs.nerfjournal.dev`, display name
    "NerfJournal Dev", and `SWIFT_ACTIVE_COMPILATION_CONDITIONS` adding
    `DEV`.  A shared scheme "NerfJournal Dev" selects it.  Under `DEV`
    the global quick-entry hotkey is not registered, so the dev and
    installed apps can run at once.  Debug and Release are untouched, so
    the installed app's workflow does not change.
*   **CLI database selection.**  `nerf` honors a `NERF_DATABASE`
    environment variable as the default for `--database`, so a shell
    can be pointed at the dev container:
    `~/Library/Containers/org.rjbs.nerfjournal.dev/Data/Library/Application Support/NerfJournal/journal.sqlite`.
*   **Network entitlement.**  `com.apple.security.network.client`, which
    the sandboxed app lacks today.
*   **Jinx dependency.**  NerfCore depends on `JinxJSON`, `JinxPatch`,
    `JinxWire`, `JinxStore`, `Jinx`, and `JinxTypes`; the app and CLI get
    them transitively.  Confirm the whole graph resolves and all three
    build.

## Chunk 2: codec (done 2026-10-28)

In NerfCore, pure functions over `JSONValue`:

*   `TaskCodec.encode(_ todo: Todo, categories:) -> JSONValue`
    implementing every write rule in JMAP-SPEC.md: floating `start`
    with `showWithoutTime`, `progress`, `progressUpdated`, the vendor
    `autoCancel` and `endedAt`, the category keyword, the fixed-key
    link, and `taskListIds` on create only.
*   `TaskCodec.decode(_ value: JSONValue, key: LocalKey, categories:)
    -> Todo` implementing every lenient-read rule: `autoCancel` true
    only for JSON `true`, `endedAt` parsed or ignored, the fallback
    chain through `progressUpdated`, `updated`, then start, `failed`
    read as abandoned, first matching keyword by sort order, lone
    foreign link shown.
*   `TaskCodec.ownedProperties: Set<String>`, the exact list from the
    spec, passed to `TaskTypes.task(ownedProperties:)`.
*   `Todo.id` becomes the Jinx local key's `Int64`.  No type change.
*   Tests: the spec's worked examples as fixtures, round-trip on our own
    encodings, and each lenient-read rule against a hand-built foreign
    Task.

## Chunk 3: engine wiring (done 2026-10-28)

In NerfCore, so the app and the CLI share it:

*   `JournalSync`: given a database writer, server session URL, and
    account id, builds `JMAPClient` with `NoAuthentication`,
    `GRDBSyncStore(writer:)`, and `SyncEngine` with
    `TaskTypes.taskList` and `TaskTypes.task(ownedProperties:)`, a
    process id, and a Darwin signal name derived from the database
    path.
*   `NerfSchema` registers Jinx's migrations after v8 so the `jinx_`
    tables exist in the same file.
*   Settings: server session URL and account id, read from
    `UserDefaults` in the app and from `NERF_JMAP_URL` and
    `NERF_JMAP_ACCOUNT` in the CLI, defaulting to the prototype.
*   The TaskList id is read once from the engine after the first sync
    and cached; creates carry it in `taskListIds`.
*   Tests use `JinxScriptedServer` and `GRDBSyncStore.inMemory()`.  No
    network in tests.

## Chunk 4: legacy data migration (schema v9 plus adopt) (done 2026-10-28, branch jmap-backend)

Rehearsed 2026-10-28 on a copy of the installed database (2598 todos,
schema v8) placed in the dev container: v9 staged every row, the dev
build adopted all 2598 at launch, and the engine pushed them in one
pass.  The server then held 2604 Tasks (the 2598 plus the six probe
tasks), the local store had no pending entries, and a spot-checked
swept, categorized, linked task matched the spec encoding exactly.
The backup copy is kept in the session scratchpad; the dev container
now holds the adopted data for chunks 5 and 6 to develop against.

This is the chunk that moves data, and it is written before the UI
switches over so that it can be rehearsed on a copy of the real
database from the dev build.

*   **Migration v9**: add a `uid` TEXT column to `todo`, fill it with a
    fresh UUID per row, drop the `todo -> category` foreign key, and
    rename the table to `todo_legacy`.  Pure SQL; runs under
    `NerfSchema.migrate` like every migration before it.
*   **Adopt step**, run by `JournalSync` right after construction:
    1.  If `todo_legacy` does not exist, done.
    2.  Read its rows and the category table.  Read every existing Jinx
        Task and collect their `uid`s.
    3.  In one `engine.write { }`, `adopt` the encoding of every legacy
        row whose `uid` is not already present.  Encoding maps
        `categoryID` to the keyword by category name.
    4.  Drop `todo_legacy`.
    Idempotent: a crash between 3 and 4 leaves rows that the next
    launch skips by uid.  The adopted objects are pending creates; the
    engine's normal sync-out pushes them, and the uid makes a lost
    response safe.
*   **Rehearsal**: copy the installed container's `journal.sqlite` into
    the dev container, launch the dev build, watch 2484 creates reach
    the server, then wipe the server and repeat as needed.  This is the
    test of the cutover, run as many times as it takes.

## Chunk 5: reads from Jinx (done 2026-10-28, branch jmap-backend)

Verified: the dev build shows today's page from the adopted data, a
Task created directly on the server appeared in its store within
seconds over push, and `nerf todo` lists today's open todos from the
dev database.  The push test task (uid `chunk5-push-test`) is still on
the server.

*   `TaskReader` in NerfCore: `engine.objects(type: "Task")` decoded
    through the codec into `[Todo]`, with each object's `pending` and
    `lastError` available alongside.
*   `PageStore`, `JournalStore`, `FutureLogView`, calendar dots, HTML
    export, and the CLI's `todo` command read through it.  The page
    query and the future log filter in memory, as they already do.
*   Stores reload on the engine's `changes()` stream.  The
    `DistributedNotification` for todo changes is removed from the app
    and the CLI; Jinx's cross-process journal replaces it.
*   After this chunk the dev build shows the adopted data from Jinx
    tables.  The `todo` table is already gone (chunk 4).

## Chunk 6: writes through Jinx

Every todo mutation becomes an engine call, using `replace(_:with:)`
with a fresh encoding for single edits and `write { }` for anything
that touches several todos:

*   `PageStore`: all mutation methods.  The sweep at `startToday`
    abandons non-migrating todos as of their start day (loose thread
    2026-10-04-49a5zg) in one batch.  Bulk complete, mark pending,
    abandon, delete, category, send-to-date, and apply bundle are each
    one batch.  Undo stays as compensating calls.
*   `QuickNoteView`'s direct write; `BundleStore` apply.
*   CLI `add-todo`, `did`, `done`, `abandon`: write, then `sync()` once,
    ignoring a connectivity failure (the app will push later).
*   The app runs `engine.run()` in a task at launch for push, pull,
    EventSource, and journal tailing.

## Chunk 7: categories by keyword

*   On every `syncIn` change set, scan affected Tasks for
    `nerfjournal:category:` keywords with no local Category and create
    one with a default color, appended to the sort order.
*   Rename and delete rewrite the keyword on every carrying Task in one
    batch.

## Chunk 8: settings and status

A settings pane: session URL and account, `SyncStatus` (connected, last
sync in and out, pending count, last failure), and a list of todos with
a `lastError`.  The CLI gets `nerf sync` and `nerf sync-status`.

## Chunk 9: export, import, factory reset

*   Export reads todos through `TaskReader`; the file format keeps
    `id` (now the local key) and gains `uid`.
*   Import adopts todos by uid (skipping those present) and replaces the
    client-only tables as today.
*   Factory reset wipes the client-only tables and calls `engine.wipe()`.
    It never destroys server data.

## Chunk 10: cutover

1.  Quit the installed app.  Copy its `journal.sqlite` to a dated backup
    outside the container.
2.  Wipe the prototype server's tasks (a `Task/set` destroy of every
    id; `jmap.pl` can do it), so dev junk does not mix with real data.
3.  Build Release and launch.  Migration v9 and the adopt step run on
    the installed container.  Watch the status pane until pending count
    is zero; confirm the server holds 2484 tasks.
4.  Install the new `nerf` binary.  Unset `NERF_DATABASE`.
5.  Keep the backup until the first full day's use has passed.

If anything is wrong, quit, restore the backup over the container's
file, and relaunch the previous build.  The server can be wiped again.

## Order and dependencies

0 first.  2 and 3 are independent of each other.  4 needs 2 and 3, and
is the first point the dev build does anything with the server.  5
needs 4.  6 needs 5.  7, 8, and 9 need 6 and are independent of each
other.  10 needs all of them.

## Outside this repo

*   Jinx gaps noted on 2026-10-28, none blocking: no per-object errors
    in `SyncStatus` (use `SyncedObject.lastError`), `wipe()` emits no
    change set (reload stores explicitly after reset), no engine-level
    `adopt` (use `Writer.adopt` inside `write`).
*   Hosting the server somewhere other than localhost, with TLS and
    network-level authentication.
*   JMAP for Tasks in Cyrus, and when the prototype is retired.  The
    uid survives a server swap; re-adopting is the recovery path.
