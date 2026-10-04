# NerfJournal sync engine design notes

Companion to JMAP-SPEC.md.  That document fixes how a todo is encoded
as a Task.  This one records how the local cache and the sync engine
should work, distilled from a study (2026-10-04) of Fastmail's web
client: the public Overture datastore and jmap-js connection layer, and
the internal client's JMAP api layer and its offline caching proxy.

Status: design notes, not yet implemented.

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
account id, the Task state string, and a push lock (see "Two
processes").

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

One push in flight at a time, across both processes.

1.  Take the push lock.  Read the log in `seq` order and snapshot, in
    memory, each row's current local value and server snapshot.
2.  Build one Task/set.  Creates send the full encoding, keyed by
    creation id equal to the row's `uid`.  Updates send a PatchObject
    diffed from server snapshot to current encoding (see "Patches").
    Updates whose diff is empty are dropped from the request and their
    log entries deleted.  Destroys send `remoteID`.
3.  Send.  On a transport failure or `serverUnavailable`, release the
    lock, leave the log untouched, and retry later with backoff.  The
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
    If the row was edited again while the request was in flight, the
    new server snapshot still reflects what was sent, so the next diff
    contains exactly the later edits.  Nothing is lost and nothing is
    sent twice.
5.  Release the lock.  If the log is non-empty, push again.

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
*   If the server rejects duplicate uids with `alreadyExists`, handle it
    as above.  Whether the prototype does this is untested.

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

## Two processes

The app and the CLI share the SQLite file, and either may write.

*   The writer uses short transactions.  GRDB in WAL mode is sufficient.
*   The push lock is a row in `syncState` holding a holder id and a
    timestamp, taken and released in their own transactions, with a
    staleness timeout so a crashed pusher does not wedge the other
    process.
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
*   Skipping `ifInState`.  With one pusher at a time and the contiguous
    state rule it is unnecessary; if both processes ever push
    concurrently, send `ifInState` and treat `stateMismatch` as pull,
    rebase, retry.
*   Store keys as creation ids; we use `uid`.
*   Showing only the first error as a toast.  Per-row error state in
    SQLite so both processes can show it.

## To probe on the prototype before implementing

*   Does Task/query accept a `uid` filter?
*   Does a create with a duplicate `uid` in the same list fail with
    `alreadyExists` and `existingId`, or succeed?
*   What does Task/changes return for a state string the server has
    never issued?

## Effect on the migration plan

*   Chunk 4 (cache schema) becomes: `remoteID`, `uid`, `serverTask`
    JSON, and `lastSyncError` on `todo`; `pendingChange(seq, todoID,
    op)`; `syncState(key, value)`.  No stored patches.
*   Chunk 2 (codec) gains three pure functions besides encode and
    decode: `diff(oldTask, newTask) -> PatchObject`, `apply(task,
    patch) -> Task`, and the rebase that composes them.  All are
    unit-testable with the spec's worked examples.
*   Chunk 6 (engine) is the push, pull, and resync procedures above,
    plus the lock and the backoff.  Its design risk is now mostly
    retired; what remains is careful implementation.
