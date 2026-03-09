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


