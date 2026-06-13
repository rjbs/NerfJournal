---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 7: Persistence with GRDB

### What does GRDB stand for?

The initials of its author, **G**wendal **R**oué, plus **DB** for database —
"Gwendal Roué's database." It's why the GitHub repository lives under his handle,
`groue/GRDB.swift`. The `.swift` suffix marks it as the Swift library; there's no
separate non-Swift "GRDB" to distinguish it from. It isn't a branded acronym so
much as the author signing his work.

### If FK checks are deferred to commit, why does the v3 migration's delete order matter?

It doesn't — the reader was right, and the unit (and the in-code comment it
quoted) overstated the rule. The text has been corrected.

Verified against the vendored GRDB source: `registerMigration` defaults to
`foreignKeyChecks: .deferred`, implemented in `Migration.swift` as `PRAGMA
foreign_keys = OFF` → run the body in a transaction → `PRAGMA foreign_key_check`
over the whole database just before commit → restore `PRAGMA foreign_keys = ON`.
So during the body foreign keys are genuinely off: no per-statement enforcement,
and cascades don't fire (`ON DELETE CASCADE` requires foreign keys on — that part
of the comment is correct). The sole enforcement is the one commit-time scan.

For a migration that empties *every* related table, the committed end-state has
no rows at all, so `foreign_key_check` finds no orphans no matter what order the
deletes ran in. The children-first ordering — and even doing `DELETE` before
`DROP TABLE` — is defensive habit, not a requirement.

Order genuinely matters in two other cases: (1) under `foreignKeyChecks:
.immediate` (foreign keys on, checked per statement), deleting a still-referenced
parent fails on that statement; (2) under deferred checks when the committed
end-state still holds live rows whose foreign keys must resolve — the
create-new-table / copy-data / drop-old-table rebuild, where the final scan runs
against real data. That second case is almost certainly where the "order matters"
instinct comes from.

