# Plan: categories become TaskLists

Companion to MIGRATION-PLAN.md, which moved todos onto a JMAP for Tasks
server with categories encoded as a keyword on each Task.  This plan
replaces that encoding: each category becomes a TaskList, and a Task's
category is the list it is in.  JMAP-SPEC.md is revised alongside.

Decided 2026-10-28, the day of the cutover.  The keyword scheme had
reserved TaskLists for some other cross-cutting split of the journal;
the only such split anyone can name is work versus personal, and that
will be separate accounts, not lists.  With that reservation gone, lists
are the better fit: a TaskList carries name, color and sort order
natively, so categories sync whole; a todo has one category or none,
which is one list or the default list; renaming or recoloring is one
`TaskList/set`; and any other JMAP Tasks client shows the categories as
lists.

## The model

*   **The default list is "no category."**  Exactly one TaskList has
    `isDefault: true` (the server enforces this and offers
    `onSuccessSetIsDefault`; NerfJournal only reads the flag).  A Task
    in the default list and no other is uncategorized.  If no list is
    flagged, the lowest `sortOrder` stands in; if there are no lists at
    all, there is nowhere to put a Task and creating one fails, as now.
*   **Every other TaskList is a category.**  `Category` keeps its shape
    (`id`, `name`, `color`, `sortOrder`) but `id` is now the engine's
    local key for the list, as a `Todo`'s is for its Task.  The
    `category` table goes away; `bundleTodo.categoryID` and
    `exportGroupMember.categoryID` hold list keys.
*   **`taskListIds` becomes an owned property.**  A categorized Task is
    in exactly its category's list; an uncategorized one is in exactly
    the default list.  A write replaces the map whole.  On read, a Task
    in several lists takes the category with the lowest `sortOrder`.
*   **Color** is written as the CSS color name, which every
    `CategoryColor` case already is.  On read, a name among the eight
    matches directly, a `#rrggbb` value takes the nearest of the eight,
    and a missing or unreadable color is chosen from the list's name, so
    the same list gets the same color on every client.  That closes
    loose thread 2026-10-28-p5eph4.
*   **The category keyword is gone.**  Nothing writes or reads
    `nerfjournal:category:*` once the legacy step below has run.

## The constraint Jinx imposes

Jinx sends `TaskList/set` before `Task/set` in one request, but it does
not rewrite a reference to a list that has no server id yet; it refuses
a `#jinx` creation reference inside another type's value as a deferred
feature.  So a Task may only be filed in a list the server has already
acknowledged.  Consequences, all accepted:

*   Creating a category syncs immediately so the list gets its id.
    Offline, the category exists locally but a todo cannot be filed in
    it until a sync succeeds; the writer refuses with a clear error
    rather than silently filing the todo in the default list.
*   Deleting a category first moves its Tasks to the default list, syncs
    so the server sees them leave, then destroys the list.  A destroy
    sent in the same request as the moves would go first (dependency
    order) and be refused as `taskListHasTask`.
*   The legacy step and an import both create lists, sync, and only then
    file Tasks.

Recorded as a Jinx loose thread; when Jinx resolves creation references
across types and orders destroys after the updates that empty them,
these syncs can go.

## Chunks

All on branch `tasklist-categories`; main stays what the installed app
runs until the cutover.

### A. Codec and list index

*   `TaskListIndex` in NerfCore: built from the engine's TaskList
    objects; knows each list's key, server id, name, color, sortOrder,
    isDefault and pending state; answers `defaultListId`,
    `categories` (non-default, sorted), `serverId(forCategory:)` and
    `categoryID(forListIds:)`.
*   `TaskCodec.encode/decode` take the index instead of `[Category]`;
    `taskListIds` joins the owned properties and is always emitted;
    `encodeNew` loses its `taskListId` parameter.  Encoding a todo whose
    category list has no server id throws.
*   `CategoryColor`: `cssName`, `init(css:)` with nearest-match, and
    `derived(from name:)`.
*   `Category` drops its GRDB conformances.
*   `JournalSync`: `listIndex()`, `categories()` from the index,
    `defaultListId()` replacing `taskListId()` (closes thread
    2026-10-28-um3kxr).

### B. Reader and writers

*   `TaskReader` decodes against the index; the unknown-keyword adoption
    goes.
*   `TaskWriter` encodes against the index.
*   New `CategoryWriter`: `create(name:color:)` (create, sync),
    `rename`, `setColor`, `reorder`, `delete` (move Tasks, sync,
    destroy).  `CategorySync.swift` is removed.

### C. Schema v10 and the legacy step

*   v10: `category` becomes `category_legacy` with a `listKey` column;
    `bundleTodo` and `exportGroupMember` are rebuilt without their
    foreign key to `category`, values kept.
*   `JournalSync.adoptLegacyCategories()`, run at launch before
    `adoptLegacyTodos()`: for each legacy row without a `listKey`, find a
    non-default list of the same name or create one (name, color,
    sortOrder) and record its key; sync; move every Task carrying a
    `nerfjournal:category:<name>` keyword into that list and drop the
    keyword; in one transaction rewrite `categoryID` in `bundleTodo`,
    `exportGroupMember` and `todo_legacy` through the mapping and drop
    `category_legacy`.  Idempotent at every step: lists are matched by
    name, moved Tasks carry no keyword, and the rewrite and drop are
    atomic.
*   `adoptLegacyTodos()` then files staged todos by their rewritten
    `categoryID`.

### D. Export, import, reset

*   Export: categories come from the index.
*   Import: for each exported category, find a list by name or create
    one; sync; map the file's category ids to list keys through
    `bundleTodos`, `exportGroupMember` and the todos; adopt todos as
    now.  Lists the file does not mention are left alone.
*   Reset is unchanged: client tables plus `engine.wipe()`.

### E. The app

*   `CategoryStore` goes through `CategoryWriter` and reloads on the
    engine's TaskList change sets; the `nerfCategoriesDidChange`
    notification goes.
*   `PageStore` and `JournalStore` reload on TaskList changes too, since
    a list's default flag or deletion changes how Tasks decode.
*   `AppDelegate.startSync` runs `adoptLegacyCategories` then
    `adoptLegacyTodos`.
*   Factory Reset's alert text says what it resets now.

### F. The CLI

`nerf categories`, `nerf add --category` and `nerf did --category` read
categories through `JournalSync`.

### G. Documents

JMAP-SPEC.md (categories, `taskListIds`, the property table, the
worked examples), README.md, memory notes.

### H. Cutover

1.  Rehearse: a second TaskMaster on port 8081 over a copy of
    `taskmaster.sqlite`, the Dev build over a copy of the installed
    `journal.sqlite` with its session URL pointed at 8081.  Launch,
    confirm one list per category with the right color and order, every
    Task in the right list, no keywords left, bundles and export groups
    still pointing at the right categories.
2.  Quit the installed app.  Back up `journal.sqlite` and
    `taskmaster.sqlite`.
3.  Build Release from the merged main, launch on the installed
    container, watch the status pane to zero pending.
4.  Install `nerf`.  Keep the backups a day.
