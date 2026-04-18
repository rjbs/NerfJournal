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



