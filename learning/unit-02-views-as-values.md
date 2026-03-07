---
title: "Unit 2: Views as Values"
nav_order: 20
---

# Unit 2: Views as Values

## Introduction

SwiftUI's central idea is a complete inversion of the AppKit/UIKit model. In
AppKit (and Perl's Tk, Qt, and most other GUI toolkits), you build a tree of
mutable objects and imperatively update them as data changes. In SwiftUI, you
*describe* what the UI should look like given the current data, and SwiftUI
figures out the changes.

That description is made of **views** — and views, like the data models from
Unit 1, are **value types**.

---

## `View` is a Protocol

Every piece of UI in SwiftUI is a type that conforms to the
[`View`](https://developer.apple.com/documentation/swiftui/view) protocol.
The protocol has exactly one requirement:

```swift
protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Self.Body { get }
}
```

Your struct must provide a `body` computed property that itself returns
something conforming to `View`. Every built-in component — `Text`, `Button`,
`HStack`, `List` — also conforms to `View`, so the whole UI is one big tree of
conforming types.

Here's the smallest possible view:

```swift
struct Greeting: View {
    var body: some View {
        Text("Hello, NerfJournal")
    }
}
```

`Greeting` is a struct. `body` is a computed property. `Text` is also a struct
conforming to `View`.

---

## `some View` — Opaque Return Types

`some View` is the piece that looks strangest at first. If you know Rust,
it's exactly [`impl View`](https://doc.rust-lang.org/book/ch10-02-traits.html#returning-types-that-implement-traits)
— an *opaque return type*: "I'll return something that conforms to `View`,
but I won't tell you which concrete type."

Why not just `View`? Because in Swift, `View` has an associated type (`Body`),
which makes it an *existential* (a type-erased box) when used as a plain return
type. Existentials have runtime overhead and limit what the compiler can
optimize. `some View` says the concrete type is fixed and known at compile
time — it just isn't named in the signature.

In practice: write `some View` whenever the compiler asks for it, and know it
means "a specific, compiler-known type that satisfies `View`."

```swift
// The concrete type SwiftUI sees is something like:
// ModifiedContent<ModifiedContent<Text, _PaddingLayout>, _BackgroundModifier<Color>>
// You never need to write that. `some View` hides it.
var body: some View {
    Text("Hello")
        .padding()
        .background(Color.accentColor)
}
```

---

## Views Are Values: No Mutation, Just Re-description

Because views are structs, they follow all the value-type rules from Unit 1.
When SwiftUI needs to redraw, it calls your `body` again. You don't update
the existing view — you return a fresh description, and SwiftUI diffs it
against the previous one.

This is the conceptual break from AppKit:

| AppKit/UIKit | SwiftUI |
|---|---|
| `label.stringValue = newText` | Return new `Text(newText)` from `body` |
| Mutate objects in place | Describe what should exist |
| You manage the update | SwiftUI diffs and applies changes |

The value-type model makes this safe and efficient: because structs are copied
rather than shared, two calls to `body` always produce independent descriptions
with no aliasing surprises. SwiftUI's diffing engine compares them and updates
only the parts of the actual UI tree that changed.

---

## Modifiers

Modifiers are methods on `View` that return a new view wrapping the original.
They don't mutate — each call in a chain produces a new struct:

```swift
Text("March 7")
    .font(.caption)
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .frame(width: 60, alignment: .trailing)
```

Each `.modifier(...)` call wraps the previous view in a new type. The compiler
sees a deeply nested generic type; you see a readable chain. **Order matters**
— `.padding().background(color)` puts the background outside the padding;
`.background(color).padding()` puts the background inside.

`DayCell` in `JournalView.swift` (line 266) has a clean example — a `Text`
wrapped with `.font`, `.fontWeight`, `.frame`, `.background`, `.foregroundStyle`,
and an `.overlay`:

```swift
Text("\(Calendar.current.component(.day, from: date))")
    .font(.system(.callout))
    .fontWeight(isToday ? .semibold : .regular)
    .frame(width: 26, height: 26)
    .background(Circle().fill(circleColor))
    .foregroundStyle(isSelected ? Color.white : .primary)
    .overlay(alignment: .bottom) {
        if hasFutureItems {
            Circle()
                .fill(isSelected ? Color.white.opacity(0.8) : Color.orange.opacity(0.8))
                .frame(width: 4, height: 4)
                .offset(y: 3)
        }
    }
```

---

## Layout: Stacks, Spacer, Padding

SwiftUI's layout primitives:

- [`HStack`](https://developer.apple.com/documentation/swiftui/hstack) — arrange children horizontally
- [`VStack`](https://developer.apple.com/documentation/swiftui/vstack) — arrange children vertically
- [`ZStack`](https://developer.apple.com/documentation/swiftui/zstack) — layer children depth-wise
- [`Spacer`](https://developer.apple.com/documentation/swiftui/spacer) — flexible space that pushes siblings apart
- `.padding()` — add space around a view
- `.frame(width:height:alignment:)` — constrain or expand a view's size

These compose naturally. `FutureLogRow` (line 99 in `FutureLogView.swift`) is
a horizontal row with a category pip, an optional date, the title text, a
spacer, and an optional link icon:

```swift
HStack(spacing: 8) {
    Circle()
        .fill(/* category color */)
        .frame(width: 8, height: 8)

    if showDate {
        Text(todo.start.formatted(.dateTime.month(.abbreviated).day()))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: futureLogDateColumnWidth, alignment: .trailing)
    }

    Text(todo.title)

    Spacer()

    // optional link icon...
}
.padding(.vertical, 2)
```

The `Spacer()` pushes the title left and the link icon right. The `.padding(.vertical, 2)`
modifier on the whole `HStack` adds a small buffer above and below the row.

---

## `@ViewBuilder`

Inside an `HStack`, `VStack`, or `body`, you can write multiple view
expressions with no explicit `return` or array literal. This works because
those closures are annotated with
[`@ViewBuilder`](https://developer.apple.com/documentation/swiftui/viewbuilder),
a *result builder* that transforms a sequence of view expressions into a
combined type.

You don't need to understand the implementation. You need to know:

1. In a `@ViewBuilder` closure, each line is a view expression.
2. `if` / `if-else` / `switch` work as you'd expect — SwiftUI includes or
   excludes views based on the condition.
3. You can't write arbitrary Swift statements (loops, assignments) directly
   in a `@ViewBuilder` block without wrapping them. `ForEach` is how you
   iterate over collections in view code.

```swift
VStack {
    Text("Title")        // expression 1
    if isEditing {       // conditional — emits a view or nothing
        TextField(...)
    } else {
        Text(todo.title)
    }
    Spacer()             // expression 2
}
```

---

## View Composition

Large views are broken into smaller ones. This is the primary tool for
managing complexity in SwiftUI — each sub-view is its own struct, independently
testable, independently readable.

`CategoryLabel` (`CategoryLabel.swift`) is the simplest example in NerfJournal
— a category color pip and a name, used in multiple places:

```swift
struct CategoryLabel: View {
    let category: Category?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(category.map { $0.color.swatch } ?? Color.gray)
                .frame(width: 8, height: 8)
            Text(category?.name ?? "Other")
        }
    }
}
```

`MonthCalendarView` (line 150 in `JournalView.swift`) uses `DayCell` for each
day in the grid. `DayCell` knows nothing about months — it just takes a `date`,
some flags, and an `onTap` closure. The calendar drives it:

```swift
DayCell(
    date: date,
    isSelected: isSameDay(date, selectedDate),
    hasEntry: hasEntry(date),
    hasFutureItems: futureDates.contains(calendar.startOfDay(for: date)),
    isToday: calendar.isDateInToday(date),
    onTap: { onSelect(date) }
)
```

This is composition in practice: each struct does one thing, knows only what
it needs, and is assembled by its parent.

---

## Private Computed Properties as Sub-Views

An alternative to extracting a new struct is breaking a complex `body` into
`private var` computed properties, each returning `some View`. `MonthCalendarView`
does this for its three sections:

```swift
var body: some View {
    VStack(spacing: 10) {
        monthHeader    // private var, defined below
        weekdayHeader
        dayGrid
    }
}

private var monthHeader: some View {
    HStack {
        Button { shiftMonth(by: -1) } label: { ... }
        Spacer()
        Text(displayMonth.formatted(...))
        Spacer()
        Button { shiftMonth(by: 1) } label: { ... }
    }
}
```

This keeps the top-level `body` readable while still having access to `self`
(the parent's stored properties) without passing anything explicitly. Use this
for logical sections of a single view; use a new struct when the piece is
reused or needs its own state.

---

## Reading

- [SwiftUI — View](https://developer.apple.com/documentation/swiftui/view) — the protocol itself
- [Declaring a custom SwiftUI view](https://developer.apple.com/documentation/swiftui/declaring-a-custom-swiftui-view)
- [Layout fundamentals](https://developer.apple.com/documentation/swiftui/layout-fundamentals)
  — stacks, spacers, and alignment
- [ViewBuilder](https://developer.apple.com/documentation/swiftui/viewbuilder)
- [Opaque and Boxed Protocol Types](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/)
  — explains `some` in depth (Swift book)

---

## Code Tour

### `CategoryLabel.swift` — the whole file

Twelve lines. A struct, a stored property, a `body` returning an `HStack` with
two children. Read this first — it's the clearest possible example of the
pattern every SwiftUI view follows.

### `JournalView.swift` lines 258–293: `DayCell`

A self-contained view that takes only plain values (no stores, no environment)
and a callback closure. Notice how all its display logic lives in `body` and
the `circleColor` computed property. No mutation anywhere.

### `JournalView.swift` lines 150–255: `MonthCalendarView`

Shows private computed properties as sub-views (`monthHeader`, `weekdayHeader`,
`dayGrid`). `dayGrid` uses `LazyVGrid` and `ForEach` — the SwiftUI equivalents
of a grid layout and a loop. Note how `MonthCalendarView` creates `DayCell`
values but knows nothing about their internal layout.

### `FutureLogView.swift` lines 73–100: `FutureLogRow` struct and body

A more realistic view: it has environment objects, state, and conditional
rendering (`if showDate`, `if isEditing`). Focus on the `body` for now — the
outer `HStack`, what's in it, and how `.padding(.vertical, 2)` applies to the
whole row. The `@EnvironmentObject` and `@State` properties will be covered
properly in Units 3 and 4.

---

## Exercises

**1.** `DayCell` has a `circleColor` computed property that returns a `Color`
(not a `View`). It's used inside `.background(Circle().fill(circleColor))`.
Trace through the modifier chain on `DayCell`'s `Text`: how many wrapping view
types does the compiler construct for that single `Text`?

**2.** In `CategoryLabel`, the pip circle uses `.fill(category.map { $0.color.swatch } ?? Color.gray)`.
Rewrite just that expression using `if let` instead of `map`/`??`. Both work;
which do you find clearer?

**3.** `MonthCalendarView.body` references `monthHeader`, `weekdayHeader`, and
`dayGrid` as if they were stored properties. Why don't they need `self.` prefix?
What would happen if you tried to assign to one of them (e.g., `monthHeader = Text("x")`)
inside a method?

**4.** In `FutureLogRow.body`, the `Spacer()` between the title `Text` and the
link icon pushes them to opposite ends of the row. Remove it mentally: where
would the link icon end up? Try it by adding a temporary `// ` comment in front
of the `Spacer()` line and running `/build` — the build will succeed but the
layout will be different.
