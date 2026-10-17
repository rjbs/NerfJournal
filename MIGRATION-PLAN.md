# Migration plan: SQLite todos to JMAP Tasks via Jinx

Companion to JMAP-SPEC.md (the encoding) and SYNC-DESIGN.md (the engine
requirements, now implemented by Jinx).  This is the ordered list of
deliverable chunks for NerfJournal itself.  Each chunk is mergeable on
its own and leaves the app and the CLI working.

Revised 2026-10-17.

## Language mode

Jinx is Swift 6 language mode from its first commit.  NerfJournal is
Swift 5 mode today.  The shared package in chunk 1 is created in Swift
6 mode; the app and CLI move to Swift 6 mode in chunk 1b, before any
write flows through the Jinx engine, so the new concurrency boundary is
checked by the compiler from the start.

## Chunk 1: shared package

A Swift package in the repo, `NerfCore`, that the app target and the
`cli` package both depend on.

*   Moves in: `CivilDate`, `Moment`, `Todo`, `TodoEnding`, `Category`,
    `CategoryColor`, `TaskBundle`, `BundleTodo`, `JournalPage`,
    `ExportGroup`, and the GRDB migrations that define their tables.
*   Deletes: the CLI's hand-mirrored copies of `CivilDate`, `Todo`,
    `TodoEnding`, `Moment`, and its table definitions.
*   Stays out: stores, views, AppKit, anything SwiftUI.  No UI
    dependency, because the CLI consumes it.
*   The GRDB dependency moves from the app target to the package (see
    the gotchas note on GRDB in a package).
*   Swift 6 language mode; value types marked `Sendable`.
*   Behavior change: none.  Existing CLI tests pass against the shared
    types.

## Chunk 1b: Swift 6 language mode for the app and CLI

With Xcode 27's default-MainActor-isolation setting on.  Expected work:
pull captured values out of the ~60 `dbQueue` closures, isolate or make
Sendable the `AppDatabase.shared` singleton, annotate the undo
registration closure and six notification observers, and tidy a few
statics in the CLI.  No behavior change.  Doubles as curriculum unit 9.

## Chunk 2: codec

In `NerfCore`: `Todo` <-> Task encode and decode implementing every rule
in JMAP-SPEC.md, including the lenient-read rules for foreign Tasks,
plus the Jinx type descriptor for Task naming the owned-property set.
Diff, apply, and rebase come from Jinx.  The spec's worked examples are
the test fixtures.  No network.

## Chunk 3: moved to Jinx

The JMAP client, EventSource, and typed errors.

## Chunk 4: schema

*   Register Jinx's migration on the app's GRDB migrator.
*   Remove the `todo -> category` foreign key; the category link becomes
    the keyword.
*   After the one-time adopt (chunk 7), drop the `todo` table.
*   Client-only tables are unchanged: `category`, `journalPage`,
    `taskBundle`, `bundleTodo`, `exportGroup`, `exportGroupMember`.

## Chunk 5: every todo write through the Jinx engine

`Todo` becomes a decoded view over Jinx's local JSON, with `Todo.id`
the Jinx local key.  Every write site changes:

*   `PageStore`, all ~20 mutation methods.  Bulk operations (sweep,
    bulk complete, mark pending, abandon, delete, category, send to
    date, apply bundle) use a Jinx transaction so each is one log batch
    and one Task/set.
*   `QuickNoteView`'s direct write.
*   `BundleStore` apply.
*   `AppDatabase` import and factory reset, via Jinx adopt and wipe.
*   The CLI's `add`, `did`, and `end` commands.
*   Reads: the page and future-log queries load all Tasks via Jinx's
    all-objects read, decode, and filter in memory, as the app already
    does over the todo table.
*   Stores reload on Jinx's change stream.  The DistributedNotification
    for todo changes is dropped; Jinx's cross-process journal replaces
    it.
*   The sweep abandons as of each todo's start day (loose thread
    2026-10-04-49a5zg), not the last page date.

## Chunk 6: moved to Jinx

The push, pull, resync, claims, and backoff engine.

## Chunk 7: initial import

Jinx's adopt entry point behind a menu item and a `nerf` subcommand:
every existing todo becomes a Jinx row with a generated uid and a
pending create, and the push loop does the rest.  Also the recovery path
after a server swap (prototype to Cyrus), since uids survive.

## Chunk 8: categories by keyword

`CategoryStore` scans keywords on all Tasks and auto-creates a local
Category for an unknown one; rename and delete rewrite keywords on
every affected Task in one transaction.

## Chunk 9: settings and status

Server URL and account, connection state, last pull time, count of
unpushed entries, and per-row last sync error, all read from Jinx.

## Chunk 10: cutover semantics

Decide and implement what export, import, and factory reset mean with a
server.  Proposed: export stays a full local dump; import merges via
adopt; factory reset wipes local state only and never destroys server
data.

## Outside this repo

*   Hosting the server behind Tailscale with TLS.
*   JMAP for Tasks in Cyrus, and whether the prototype is retired.
*   Jinx itself.
