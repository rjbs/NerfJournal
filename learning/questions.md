---
title: Questions & Answers
nav_order: 4
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 1: Swift as a Language

### `guard let` vs `if let` — does `guard` always take an `else`?

Yes, `guard` always requires an `else`. It's a compile-time requirement. The
`else` body must exit the current scope — via `return`, `throw`, `break`,
`continue`, or a `Never`-returning function like `fatalError()`.

The real distinction isn't about the `else` clause, though. It's about **where
the unwrapped binding lives**:

```swift
if let n = nick {
    greet(n)      // n is available here
}
// n is gone here

guard let n = nick else { return }
// n is available here, for the rest of the enclosing scope
greet(n)
doMoreWith(n)   // still have n
```

With `if let`, the unwrapped name only exists inside the braces. With
`guard let`, the unwrapped name escapes into the surrounding scope and stays
there.

An `if let / else` is perfectly valid Swift. The idiom question is: are you
branching on the optional, or are you asserting a precondition and continuing?
`guard` is the "bail out early, proceed with confidence" pattern — the happy
path stays at the outer indentation level rather than being nested inside a
branch.
