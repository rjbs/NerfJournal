---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 6: Focus, Cross-Window Communication, and Notifications

### When we call `.focusedSceneObject(pageStore)`, are we publishing the variable (live reference) or its current value (snapshot)?

Close to "the variable," with one addition. `PageStore` is a class, so
`pageStore` holds a reference. When you pass it to
`.focusedSceneObject(pageStore)`, what's shared is the reference, not a
snapshot of its `@Published` properties at that moment. Every reader is looking
at the same live object, so mutations to `pageStore.todos`, `pageStore.page`,
etc. are visible to all of them without any extra plumbing.

What `.focusedSceneObject` (and the `@FocusedObject` that reads it) adds on
top of reference-sharing is **observation**. Like `@ObservedObject` and
`@EnvironmentObject`, `@FocusedObject` subscribes to the object's
`objectWillChange` publisher. That subscription is what causes `TodoCommands`'
body to re-evaluate when a `@Published` property changes — so a menu item's
`.disabled(pageStore == nil)` or
`.disabled(journalStore.pageDates.isEmpty != false)` actually updates as state
changes.

Without the subscription you'd still be looking at the same live object, but
nothing would tell the menu bar to re-check its disabled state. With it, you
get both the live reference *and* change notifications — the same combination
you get from `@EnvironmentObject`, just routed up to menus instead of down to
child views.

### What if `pageStore` were reassigned to a new `PageStore` instance — would the focus environment pick it up?

Yes. `.focusedSceneObject(pageStore)` is called inside the `App`'s `body`
computed property, so SwiftUI re-evaluates it whenever the scene graph needs
reconsideration. If the reference changed, the focus environment would update
to point to the new object, and `@FocusedObject` readers would re-subscribe to
the new one's `objectWillChange`.

SwiftUI diffs scene modifiers much like it diffs view modifiers: applying
`.focusedSceneObject(sameObjectAsBefore)` is cheap — if the reference hasn't
changed, nothing downstream needs to update. Only when the reference actually
differs does the focus environment swap.

One wrinkle: `pageStore` here is a `@StateObject`, which exists specifically
to prevent the reference from changing across re-renders. That's the main
reason to use `@StateObject` over `@ObservedObject` — SwiftUI guarantees the
object is created once per view lifetime and preserved, so `pageStore` is a
stable reference until the `NerfJournalApp` instance itself goes away (which,
for the top-level `App`, means never). You *could* assign a new value via
`pageStore = PageStore()` from inside a method, and SwiftUI would honor it —
but the whole point of `@StateObject` is that you usually don't.

The mental model: the focus environment reflects whatever `body` publishes each
time it runs; stability of the reference is a property of `@StateObject`, not
of the publishing mechanism.



