---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 3: Local State and Binding

### `@State` — what does "owned by SwiftUI, not the struct" actually mean?

When SwiftUI first renders a view, it allocates persistent storage for each
`@State` property, keyed to that view's *position in the view hierarchy*. The
struct itself does contain a `@State` wrapper, but that wrapper holds almost
nothing — it's a thin shell that knows where to find the real value in
SwiftUI's external storage. Accessing the property goes through that wrapper
to the external store; writing to it writes there and enqueues a re-render.

The struct instance is genuinely thrown away and recreated on every render.
SwiftUI calls `body` fresh each time. The `@State` wrapper inside the new
instance reconnects to the *same* external storage as before, because the
view occupies the same position in the hierarchy. That's how state survives
across re-renders despite the struct being ephemeral — the wrapper is the
thread of continuity; the struct is scaffolding that gets rebuilt.

Re-render triggering works through `@State`'s property wrapper machinery: the
setter calls into SwiftUI's scheduler, which marks the view as needing update
and calls `body` again on the next pass.

The storage is identity-keyed, not pooled. Two views of the same type at
different positions in the tree get independent storage slots.

### View hierarchy identity — "keyed to position, not to instance"

SwiftUI maintains a persistent *view graph* (render tree) that outlives any
individual struct instance. Instance identity is useless here because instances
are ephemeral by design — two successive instances of the same view type at the
same position are indistinguishable as objects. So SwiftUI uses structural
position as the stable identity instead.

When a re-render is needed, SwiftUI calls `body` to get a fresh description,
diffs it against what's in the tree, and patches in place — updating values
where structure is the same, creating new nodes (with fresh state) where new
views appeared, and tearing down nodes (and their state) where views
disappeared.

The view structs you write are the *input* to the tree, not the tree itself.

### View identity — what is the scope of uniqueness for `.id()` and `ForEach` IDs?

**Local to the parent** — not global. IDs only need to be unique among siblings
within the same parent's `body`.

The two uses have subtly different intents:

- **`ForEach(items, id: \.id)`** — IDs distinguish siblings from each other;
  must be unique within the collection at any given moment so SwiftUI can tell
  items apart across updates.
- **`.id(value)` on a single view** — signals "treat me as a new view when
  this value changes"; uniqueness relative to other views isn't the point.

So `.id(currentTodo.id)` on a `TextField` is fine even though `id` is an
autoincrement `Int64`. That view isn't competing with any other view for that
integer — it just needs to produce a *different* value when `currentTodo`
changes, so SwiftUI resets the field's state.


`DayCell(...)` in `body` is a value describing what should be at that slot;
SwiftUI decides what to do with the actual on-screen elements. The struct fills
a slot; SwiftUI manages the slot.

