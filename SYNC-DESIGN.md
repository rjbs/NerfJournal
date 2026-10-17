# NerfJournal sync engine design notes

Companion to JMAP-SPEC.md.  That document fixes how a todo is encoded
as a Task.  This one records how the local cache and the sync engine
should work, distilled from a study (2026-10-04) of Fastmail's web
client: the public Overture datastore and jmap-js connection layer, and
the internal client's JMAP api layer and its offline caching proxy.

Status: design notes.  Revised 2026-10-17: the engine and the Task store
are now provided by the Jinx library (/Users/rjbs/code/hub/Jinx, plan in
doc/plan.md), which adopted this design.  See "Division of labor with
Jinx" for what NerfJournal still owns.

## Division of labor with Jinx

The sections from "The core model" through "Concurrent pushers" describe
behavior that Jinx implements.  They stay here as the record of what
NerfJournal requires and why, and as the reference for checking Jinx
against.  Jinx owns:

*   The Task store itself.  Tasks live in `jinx_`-prefixed tables in
    NerfJournal.s SQLite file, registered as a migration on the app.s
    GRDB migrator.  Each row holds the local value and the server
    snapshot as JSON, a stable Int64 local key that never changes, the
    JMAP id once assigned, pending state, and the last sync error.
*   The to-send log with per-entry claims, late diffing, rebase on
    pull, resync, error classification, state handling, backoff, and
    the JMAP client and EventSource.
*   Cross-process change signaling.  Each commit appends its change set
    to a `jinx_` journal table and posts a Darwin notification named for
    the database file.  An engine in another process wakes, reads the
    unseen journal rows, and emits them on its own change stream.  The
    app and the CLI therefore see identical change sets, and
    NerfJournal.s DistributedNotification is no longer needed for todo
    changes.

NerfJournal owns:

*   **The codec and the owned-property set.**  Jinx.s type descriptor
    for Task declares exactly the properties JMAP-SPEC.md lists.  A
    replacement-encoding update merges only those keys into the current
    local JSON, so a fresh encoding from `Todo` can never null a
    property it does not know about.  The diff recurses into objects
    and patches maps such as `keywords` and `links` per entry.
*   **`Todo` as a decoded view.**  `Todo.id` is the Jinx local key.
    Every read decodes the local JSON through the lenient rules in
    JMAP-SPEC.md.  Nothing in the app queries Task columns with SQL;
    the page and future-log queries load all Tasks and filter in
    memory, which is what the app already does over the todo table.
*   **All writes through the Jinx engine**, from PageStore, the
    quick-entry panel, bundle application, import, and the CLI.  Bulk
    operations (the sweep, bulk complete, abandon, delete, category,
    send-to-date, apply bundle) use Jinx.s transaction so each is one
    log batch and one Task/set.
*   **Client-only tables**: category (color and sort order), journalPage,
    taskBundle, bundleTodo, exportGroup.  None references a Task; the
    category link is the keyword, by name.
*   **Categories by keyword**, including auto-creating a local Category
    for an unknown keyword found on any Task.
*   **Import and factory reset** via Jinx.s adopt (existing objects
    become pending creates) and wipe entry points.  The one-time
    migration of the existing todo table is an adopt; keeping the old
    Int64 ids as local keys is nice-to-have, since nothing references
    them.
*   **Undo**, as compensating edits through the same writes.

## What was studied, and which part matters

Fastmail's client has two sync layers.

1.  **In-memory, in the page.**  The Overture `Store` plus the app's
    `jmap/api/*` adapters.  Records live in memory with status bits
    (NEW, DIRTY, COMMITTING, OBSOLETE), a committed-base snapshot per
    dirty record, and a rollback snapshot per in-flight commit.  Nothing
    persists across a reload.

2.  **Persistent, in a worker.**  `workers/proxy/` is a JMAP caching
    proxy over IndexedDB.  It keeps every record, a reverse patch from
    each locally modified record back to its last-known server version,
    and an ordered log of records to send.  It survives reloads and
    works offline.

The proxy is the template for a SQLite-backed engine.  The in-memory
store is useful mainly for its conflict rule and its state handling,
both of which the proxy also implements.

## The core model

Three things per synced row, and one log.

*   **The local value.**  The `todo` row as it is today, which is what
    the UI reads and the writer updates.

*   **The server snapshot.**  A JSON column holding the last Task object
    the server is known to have for this row, or NULL for a row the
    server has never seen.  Fastmail stores a reverse patch instead; a
    full snapshot is equivalent, simpler to inspect, and cheap at our
    row counts.

*   **Identity.**  `remoteID` (the JMAP id, NULL until created) and
    `uid` (client-generated UUID, set at insert, never changes).

*   **The to-send log.**  A `pendingChange` table of `(seq, todoID, op)`
    where `op` is create, update, or destroy.  It stores no patch.  The
    patch is computed at push time as the diff between the server
    snapshot and the encoding of the current local value.

Consequences of computing the patch late rather than at edit time:

*   Several edits to one row collapse into one patch.
*   An edit that returns a row to its server value produces an empty
    patch, and the row drops out of the push.
*   Undo needs no special handling.  It is another edit through the
    writer (see below).

Per-type sync metadata lives in a `syncState` table: the server URL,
account id, and the Task state string.  Log entries carry a claim (see
"Concurrent pushers").

## The write path

Every mutation goes through one writer, in one transaction:

1.  Update the `todo` row.
2.  If the row has no `remoteID` and no pending create, append a
    create to the log.  If it has a pending create, do nothing more; the
    create will send the current value.
3.  Otherwise delete any existing log entry for the row and append an
    update at the end.  Moving to the end keeps the log in edit order.
4.  For a destroy: if the row was never sent, delete the row and its log
    entry outright.  Otherwise replace its log entry with a destroy.

The writer is shared by the app and the CLI.

## Push

One push in flight per process.  Several processes may push at once;
see "Concurrent pushers" for why that is safe.

1.  Claim the unclaimed log entries, in one transaction, by stamping
    them with this process.s id and the time.  Read the claimed entries
    in `seq` order and snapshot, in memory, each row.s current local
    value and server snapshot.
2.  Build one Task/set.  Creates send the full encoding, keyed by
    creation id equal to the row's `uid`.  Updates send a PatchObject
    diffed from server snapshot to current encoding (see "Patches").
    Updates whose diff is empty are dropped from the request and their
    log entries deleted.  Destroys send `remoteID`.
3.  Send.  On a transport failure or `serverUnavailable`, release the
    claims, leave the log otherwise untouched, and retry later with
    backoff.  The
    identical batch is rebuilt next time.
4.  Apply the response in one transaction:
    *   `created`: set `remoteID`, set server snapshot to what was sent
        merged with any server-set properties returned.
    *   `updated`: set server snapshot to what was sent merged with any
        server-set properties returned.
    *   `destroyed`: delete the row.  `notDestroyed` with `notFound`
        counts as destroyed.
    *   `notCreated` / `notUpdated`: see "Errors".
    *   `newState`: advance the Task state if `oldState` equals the
        stored state; otherwise mark that a pull is needed.
    *   Delete the log entries that were sent, in this same transaction.
        An entry that was re-added at a later `seq` by an edit made
        during the request belongs to the next push and is left alone.
    If the row was edited again while the request was in flight, the
    new server snapshot still reflects what was sent, so the next diff
    contains exactly the later edits.  Nothing is lost and nothing is
    sent twice.
5.  If unclaimed entries remain, push again.

Fastmail's proxy holds an exclusive database lock for the whole round
trip.  We cannot, with two processes, so step 1 snapshots and step 4
reconciles instead.

## Pull

Always push before pulling.  If a pull ever has to resync from scratch,
it should do so against a server that already has our changes.

1.  Task/changes with `sinceState`, followed in the same request by two
    Task/get calls back-referenced to `/created` and `/updated`.
2.  If the response's `oldState` is not our stored state, discard it
    and pull again.
3.  For each fetched Task:
    *   No local row with that `remoteID` or `uid`: insert, server
        snapshot = fetched Task.  Matching by `uid` catches a create
        whose response we lost.
    *   Local row with no pending change: replace local value and server
        snapshot.
    *   Local row with a pending change: **rebase**.  Compute the patch
        from old server snapshot to current local encoding, apply it on
        top of the fetched Task, decode the result as the new local
        value, and store the fetched Task as the new server snapshot.
        If the result equals the fetched Task, the server already has
        our change: drop the log entry.
    *   Local row whose push is in flight (only possible from the other
        process): defer; the pusher will reconcile.
4.  For each destroyed id: delete the row and its log entry.  Keep a
    note of any pending change that was discarded.
5.  Advance the stored state to `newState`.  Loop while
    `hasMoreChanges`.

The rebase is Fastmail's conflict rule: a locally pending property wins
until pushed, everything else takes the server value.  Doing it on the
JSON encoding rather than on `Todo` fields means the rule works at
patch-path granularity and needs no per-field code.

## Resync

On `cannotCalculateChanges`, or a stored state the server no longer
recognises:

1.  Forget the stored state.  Do not wipe local data.
2.  Task/get with `ids: null`.  The prototype allows 1000 objects per
    get, which is enough for now; page via Task/query if it ever is not.
3.  Apply every returned Task as in Pull step 3.
4.  Delete every local row that has a `remoteID`, was not returned, and
    has no pending create.  Rows the server has never seen are never
    deleted by a resync.
5.  Store the returned state.

## Patches

Updates are JSON-pointer PatchObjects built by recursive diff of plain
objects, as Fastmail does:

*   Recurse into objects, never into arrays.  Emit `"a/b": value` for a
    changed leaf, `"a/b": null` for a removed key, the whole value for a
    changed array or scalar.  Escape `~` and `/` in keys.
*   A per-path veto falls back to replacing the whole value.  For Task,
    veto `recurrenceOverrides/*` (patch-inside-patch is ambiguous) if we
    ever write it; we do not today.
*   Never name a property the spec does not model.  Because the diff is
    between two encodings of the same row, and both encodings carry
    only our properties, foreign properties are never mentioned and so
    survive.  This is the mechanism behind spec principle 3.

The server snapshot must therefore hold the full Task as fetched, not a
re-encoding of it, so that foreign properties are present when the
rebase applies our patch on top.

## Errors

Fan a method-level error on Task/set out into a per-item error for
every item in the request, so there is one error path.  Then classify:

*   **Retryable**: `serverFail`, `serverUnavailable`, `stateMismatch`,
    `rateLimit`, transport failure.  Keep the log entry.  Back off.
*   **Permanent per item**: `invalidProperties`, `notFound`,
    `forbidden`, `invalidPatch`.  Record the error on the row, revert
    the row's local value to its server snapshot, delete the log entry,
    and surface it in the UI and the CLI.  Do not revert other rows.
*   `notCreated` with `alreadyExists` and an `existingId`: adopt
    `existingId` as `remoteID` and treat as created.

Fastmail's in-memory layer treats every failure as permanent and
reverts, including edits made after the failed request was sent.  Do
not copy that.

Retry timing: exponential backoff, roughly 1 s doubling to 5 min for
connectivity, shorter for logic errors.  Push reconnection triggers an
immediate push attempt.

## Idempotency

A create whose response is lost would be re-sent and duplicated.
Neither Fastmail layer solves this.  We can, because the spec gives
every Task a client-generated `uid`:

*   The creation id in Task/set is the `uid`.
*   Before re-sending a create after an ambiguous failure, pull first.
    A fetched Task with a matching `uid` adopts the row (Pull step 3).
*   The server rejects duplicate uids; see "Probed on the prototype"
    for the exact shape, which is not `alreadyExists`.

Updates are absolute patches and destroys treat `notFound` as success,
so both are safe to replay.

## State handling

*   One stored state for the Task type.  Advance it only when the
    response's `oldState` equals it (from Task/changes or Task/set).  A
    non-contiguous `newState` means a pull is needed.
*   A StateChange from push, or a `newState` we did not expect, sets a
    "pull needed" flag.  The engine does not pull while a push is in
    flight; it checks the flag when the push finishes.
*   Debounce push notifications.  Pull once after a short quiet period.

## Concurrent pushers

The app and the CLI share the SQLite file, either may write, and both
may push at the same time.  In practice the CLI mostly creates, and
nearly every update is a progress change, so two processes rarely touch
the same property.  Updates are therefore last-writer-wins at the
property level, and `ifInState` is never sent.  This is a deliberate
choice (2026-10-04), not an oversight.

What makes concurrent pushing safe without a global lock:

*   **Claims, not a lock.**  A log entry is claimed by the process that
    will send it, so no entry is sent twice.  A claim older than a
    staleness timeout is treated as unclaimed, so a crashed pusher
    does not strand its entries.
*   **Every send is safe to repeat anyway.**  Creates are rejected by
    uid (see "Idempotency"), update patches are absolute, and a destroy
    of a missing task counts as destroyed.  A stale claim that is
    re-sent after all costs a round trip, not correctness.
*   **State advances only when contiguous.**  When two processes push
    back to back, the second to apply its response sees an `oldState`
    that does not match and sets the pull-needed flag.  The pull then
    fetches tasks that are already local with matching `remoteID` and
    no pending change, and simply refreshes their snapshots.
*   **Rebase on pull is unaffected.**  It reconciles local pending
    edits against fetched data, which has nothing to do with who
    pushed.

The writer uses short transactions.  GRDB in WAL mode is sufficient.
*   Only the app holds the EventSource connection.  The CLI pushes once
    after each write if it can reach the server, and otherwise leaves
    the log for the app.
*   The CLI already posts a DistributedNotification after writing; the
    engine posts the same after applying a pull, so the UI refreshes.

## Undo

Undo is a compensating edit through the writer, which is what PageStore
already does.  Nothing is pulled out of the log.  An undo before the
push produces an empty diff and the row drops out; an undo after the
push is a second update.  Undoing a destroy of a pushed row becomes a
fresh create with the same `uid`, which is an argument for the server
rejecting duplicate uids rather than silently accepting them.

## Deliberately not copied

*   Overture's in-memory status bits, committed/rollback snapshots, and
    NestedStore edit drafts.  The server-snapshot column plus the log
    replaces all of them.
*   Holding an exclusive lock for the whole push round trip.
*   Run-loop batching, multi-tab jitter, `canFetchAll` and lazy
    OBSOLETE refetching, the calendar's date-range-as-sync-unit.  We
    hold the full set locally and always fetch changed records inline.
*   Store keys as creation ids; we use `uid`.
*   Showing only the first error as a toast.  Per-row error state in
    SQLite so both processes can show it.

## Probed on the prototype, 2026-10-04

*   **Task/query accepts a `uid` filter** and returns the matching id.
    So "pull first, then adopt by uid" has a cheaper form: query by
    uid before re-sending a create.
*   **A duplicate `uid` is rejected**, but as `invalidProperties` with
    `properties: ["uid"]` and the description "a task with this uid and
    recurrenceId already exists", not as `alreadyExists` with an
    `existingId`.  The engine must therefore treat `invalidProperties`
    naming `uid` on a create as "already exists": query by uid, adopt
    the id, and clear the pending create.  Handle `alreadyExists` too,
    in case the server is changed to return it, which would be the
    friendlier behavior.
*   **Task/changes with any unknown state** returns
    `cannotCalculateChanges`.  Tested with a garbage string, a number
    beyond the current state, and the empty string.  There is no
    separate error for "never issued", so the resync path is the only
    path, which is fine.

## Effect on the migration plan

Revised 2026-10-17 for the Jinx split.

*   Chunk 1 (shared package) is unchanged: `CivilDate`, `Moment`,
    `Todo`, `TodoEnding`, `Category`, and the client-only GRDB schema,
    shared by the app and the CLI.
*   Chunk 2 (codec) is `Todo` <-> Task encode and decode with the
    lenient-read rules, plus the Task type descriptor for Jinx naming
    the owned-property set.  Diff, apply, and rebase come from Jinx.
*   Chunk 3 (JMAP client) moves to Jinx.
*   Chunk 4 (schema) shrinks to: register Jinx.s migration; drop the
    `todo` table after the one-time adopt; remove the todo -> category
    foreign key.  No v9 columns on `todo`.
*   Chunk 5 (one write path) becomes "every todo write goes through the
    Jinx engine", covering PageStore, QuickNoteView, BundleStore.s
    apply, AppDatabase import and reset, and the three CLI commands
    that write today.  The CLI drops its mirrored model types for the
    shared package.
*   Chunk 6 (engine) moves to Jinx.
*   Chunk 7 (import) is the adopt entry point behind a menu item and a
    `nerf` subcommand.
*   Chunks 8 through 10 (keyword categories, settings and status,
    cutover semantics) are unchanged, with status read from Jinx.s
    per-row pending state and last error.
