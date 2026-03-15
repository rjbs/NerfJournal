---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 6: Focus, Cross-Window Communication, and Notifications

### What's the benefit of `NotificationCenter` over `DistributedNotificationCenter`?

Three distinct differences — not really about performance:

**Scope**: [`NotificationCenter`](https://developer.apple.com/documentation/foundation/notificationcenter)
is in-process only; notifications never leave your app's memory space.
[`DistributedNotificationCenter`](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
crosses process boundaries via a system daemon. Using `NotificationCenter`
for intra-app communication isn't an optimization so much as using the right
tool: no reason to involve the OS for something that doesn't need to leave
the process.

**Sandboxing**: The bigger practical constraint on macOS. Sandboxed apps have
restricted access to `DistributedNotificationCenter` — you can post and
receive notifications prefixed with your own bundle ID, but arbitrary
cross-app notifications are blocked. NerfJournal uses
`org.rjbs.nerfjournal.externalChange` specifically because it's prefixed with
the app's identifier, which sandbox rules permit.

**Payload**: `NotificationCenter` notifications can carry any Swift object as
`userInfo`. `DistributedNotificationCenter` must serialize the payload through
the OS — only property-list-compatible types are allowed, and large payloads
are discouraged. NerfJournal's distributed notification carries no payload at
all (the CLI just pokes the app to re-read the database), sidestepping this
entirely.

The split in NerfJournal is principled: `DistributedNotificationCenter` only
where necessary (crossing the CLI process boundary), `NotificationCenter`
everywhere else.

---

## Unit 5: App Structure and Multiple Windows

### Where is `@CommandsBuilder`? `Commands.body` has no visible result-builder annotation.

It's on the protocol requirement, not the conforming implementation.
[`Commands`](https://developer.apple.com/documentation/swiftui/commands) is
declared as:

```swift
public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder var body: Self.Body { get }
}
```

When a protocol requirement carries a result-builder attribute, Swift
automatically applies it to any conforming implementation of that requirement.
You don't re-annotate `body` in `DebugCommands` — the attribute is inherited.

This is the same mechanism behind `@ViewBuilder`: `View.body` is declared
`@ViewBuilder var body: Self.Body { get }`, yet conforming types never write
`@ViewBuilder` on their own `body`. Multi-expression `body` properties work in
both cases because the builder attribute flows from the protocol requirement to
the concrete implementation.

`@CommandsBuilder` collects `Commands`-conforming values — `CommandMenu`,
`CommandGroup`, etc. all conform to `Commands` — into a single combined value,
exactly as `@ViewBuilder` collects `View`-conforming values.

### Why is `WindowGroup` the only option for iOS, not just the default?

[`Window`](https://developer.apple.com/documentation/swiftui/window) is a
macOS-only scene type — it doesn't exist on iOS at all. `WindowGroup` is the
only scene type available for the main app content on iOS. The distinction
doesn't matter much in practice on iPhone because `WindowGroup` there always
produces exactly one window (iPhones don't have windowed multitasking). On iPad
you can get multiple side-by-side instances if the app opts in via
`UISceneConfiguration`, but that's deliberate. On macOS, `WindowGroup`
automatically adds "New Window" to the File menu, which is why NerfJournal
avoids it.

