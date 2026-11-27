import Foundation
import JinxJSON

// JMAP-SPEC.md is the contract this implements, and the two should be read
// together.

/// Turns a ``Todo`` into the JSCalendar Task that it is on a JMAP for Tasks
/// server, and back.
///
/// Writing is strict: an encoding always carries the whole set of
/// ``ownedProperties``, and the sync engine merges exactly those into the
/// Task, leaving everything else, like its description, its alerts, and
/// other clients' keywords, as it found it.  Reading is lenient: a Task
/// written by another client, with none of NerfJournal's own properties,
/// still decodes to a sensible todo.
public enum TaskCodec {
    /// The prefix of the names of NerfJournal's own Task properties.
    public static let vendorPrefix = "nerfjournal.semiotic.systems:"

    /// The property that is true on the Task of a todo that doesn't
    /// migrate, which ``TaskWriter/sweep(asOf:now:)`` will abandon after its
    /// start day.
    public static let autoCancelProperty = vendorPrefix + "autoCancel"

    /// The property that holds when the todo ended: an RFC 3339 date-time
    /// when the moment is known, and otherwise a bare day, "YYYY-MM-DD".
    public static let endedAtProperty = vendorPrefix + "endedAt"

    /// The key, in the Task's `links`, of the todo's
    /// ``Todo/externalURL``.
    public static let externalLinkKey = "nerfjournal-external"

    /// The properties an encoding carries, and so the only ones that writing
    /// a todo may change.
    ///
    /// `uid` is set when the Task is created, and never after, so it is not
    /// one of these.
    public static let ownedProperties: Set<String> = [
        "@type", "title", "start", "showWithoutTime", "taskListIds",
        "progress", "progressUpdated", "keywords", "links",
        autoCancelProperty, endedAtProperty,
    ]

    // MARK: - Encoding

    /// The Task that `todo` is.
    ///
    /// When `existing` is the Task as it stands, keywords and links that
    /// another client put there are carried through, and `progressUpdated`
    /// is left alone unless the todo's ending has changed.
    ///
    /// `now` is the instant recorded in `progressUpdated` for an ending with
    /// only a day, which has no instant of its own.  It is a parameter so
    /// that tests can fix it, and nil leaves the property out, which is what
    /// a one-time import of old records wants.
    ///
    /// The todo's category decides `taskListIds`: its category's list, or the
    /// default list.  A category whose list the server hasn't yet
    /// acknowledged has no id to file the Task under, and that is the error
    /// ``JournalSyncError/categoryNotSynced(_:)``, not a quiet fall-back to
    /// the default list.  With no default list, the error is
    /// ``JournalSyncError/noTaskList``.
    public static func encode(
        _ todo: Todo,
        lists: TaskListIndex,
        existing: JSONValue? = nil,
        now: Date? = Date()
    ) throws -> JSONValue {
        var task: [String: JSONValue] = [
            "@type": "Task",
            "title": .string(todo.title),
            "start": .string(todo.start.iso + "T00:00:00"),
            "showWithoutTime": true,
            "taskListIds": .object([try listId(for: todo, in: lists): true]),
        ]
        if !todo.shouldMigrate {
            task[autoCancelProperty] = true
        }

        let existingProgress = existing?["progress"]?.stringValue
        if let ending = todo.ending {
            let progress = ending.kind == .done ? "completed" : "cancelled"
            task["progress"] = .string(progress)
            if let time = ending.time {
                task[endedAtProperty] = .string(rfc3339(time))
                task["progressUpdated"] = .string(utcDateTime(time.instant))
            } else {
                task[endedAtProperty] = .string(ending.day.iso)
                if existingProgress == progress, let kept = existing?["progressUpdated"] {
                    task["progressUpdated"] = kept
                } else if let now {
                    task["progressUpdated"] = .string(utcDateTime(now))
                }
            }
        } else if let existingProgress, isEnded(progress: existingProgress) {
            // Reopening: say so explicitly, and drop the stale ending.
            task["progress"] = "needs-action"
        } else if let existingProgress {
            // A foreign in-process stays in-process.
            task["progress"] = .string(existingProgress)
        }

        if let keywords = existing?["keywords"]?.objectValue, !keywords.isEmpty {
            task["keywords"] = .object(keywords)
        }

        var links = existing?["links"]?.objectValue ?? [:]
        links[externalLinkKey] = nil
        if let url = todo.externalURL {
            links[externalLinkKey] = ["@type": "Link", "href": .string(url), "rel": "related"]
        }
        if !links.isEmpty {
            task["links"] = .object(links)
        }

        return .object(task)
    }

    /// The Task that `todo` is, for a Task that doesn't exist yet: the
    /// encoding from ``encode(_:lists:existing:now:)``, with `uid` added.
    public static func encodeNew(
        _ todo: Todo,
        lists: TaskListIndex,
        uid: String,
        now: Date? = Date()
    ) throws -> JSONValue {
        var task = try encode(todo, lists: lists, now: now)
        task["uid"] = .string(uid)
        return task
    }

    // The server id of the list `todo` belongs in. A category id that
    // names no list (the list was deleted elsewhere) reads as no category,
    // which is also how the todo decodes.
    static func listId(for todo: Todo, in lists: TaskListIndex) throws -> String {
        if let categoryID = todo.categoryID, let entry = lists.entry(forCategory: categoryID) {
            guard let id = entry.serverId else { throw JournalSyncError.categoryNotSynced(entry.name) }
            return id
        }
        guard let id = lists.defaultListId else { throw JournalSyncError.noTaskList }
        return id
    }

    // MARK: - Decoding

    /// The todo that a Task is, with the id `id`.
    ///
    /// A Task with no `start` starts on the day it was created.  An ended
    /// Task with no usable `endedAt` property ended on the day its progress
    /// was last updated, or failing that the day the Task was, or failing
    /// that its start day.  Those instants are turned into days in `zone`.
    /// A Task in no category list this client knows has no category, and a
    /// link the Task has, if it has only one, is the todo's
    /// ``Todo/externalURL`` even if NerfJournal didn't put it there.
    public static func decode(
        _ task: JSONValue,
        id: Int64?,
        lists: TaskListIndex,
        zone: TimeZone = .current
    ) -> Todo {
        let start = startDay(of: task, zone: zone)
        let shouldMigrate = task[autoCancelProperty] != .bool(true)

        var ending: TodoEnding?
        if let progress = task["progress"]?.stringValue, isEnded(progress: progress) {
            let kind: TodoEnding.Kind = progress == "completed" ? .done : .abandoned
            if let endedAt = task[endedAtProperty]?.stringValue, let parsed = parseEndedAt(endedAt) {
                ending = TodoEnding(day: parsed.day, time: parsed.time, kind: kind)
            } else {
                ending = TodoEnding(day: fallbackEndingDay(of: task, start: start, zone: zone), kind: kind)
            }
        }

        return Todo(
            id: id,
            title: task["title"]?.stringValue ?? "",
            shouldMigrate: shouldMigrate,
            start: start,
            ending: ending,
            categoryID: lists.categoryID(forListIds: task["taskListIds"]),
            externalURL: externalURL(of: task)
        )
    }

    // MARK: - Pieces

    static func isEnded(progress: String) -> Bool {
        progress == "completed" || progress == "cancelled" || progress == "failed"
    }

    static func startDay(of task: JSONValue, zone: TimeZone) -> CivilDate {
        if let start = task["start"]?.stringValue, let day = CivilDate(iso: String(start.prefix(10))) {
            return day
        }
        if let created = task["created"]?.stringValue, let instant = parseUTCDateTime(created) {
            return CivilDate(instant: instant, in: zone)
        }
        return CivilDate(instant: Date(), in: zone)
    }

    // The ending day for an ended Task without a usable endedAt, from the
    // best timestamp available. The start day comes last: a task that
    // lived a week and was completed elsewhere should not show as done on
    // its first day's page.
    static func fallbackEndingDay(of task: JSONValue, start: CivilDate, zone: TimeZone) -> CivilDate {
        for property in ["progressUpdated", "updated"] {
            if let value = task[property]?.stringValue, let instant = parseUTCDateTime(value) {
                return CivilDate(instant: instant, in: zone)
            }
        }
        return start
    }

    static func externalURL(of task: JSONValue) -> String? {
        guard let links = task["links"]?.objectValue else { return nil }
        if let ours = links[externalLinkKey] {
            return ours["href"]?.stringValue
        }
        if links.count == 1, let only = links.values.first {
            return only["href"]?.stringValue
        }
        return nil
    }

    // Either shape of endedAt: a bare day, or an RFC 3339 date-time whose
    // offset becomes the Moment's offset. Anything else is nil.
    static func parseEndedAt(_ s: String) -> (day: CivilDate, time: Moment?)? {
        if s.count == 10 {
            guard let day = CivilDate(iso: s) else { return nil }
            return (day, nil)
        }
        guard let moment = parseRFC3339(s) else { return nil }
        return (moment.civilDate, moment)
    }

    static func parseRFC3339(_ s: String) -> Moment? {
        guard let instant = parseInternetDateTime(s) else { return nil }
        let offset: Int
        if s.hasSuffix("Z") || s.hasSuffix("z") {
            offset = 0
        } else {
            // The offset is the trailing ±HH:MM, which the formatter has
            // already validated.
            let tail = s.suffix(6)
            let sign = tail.first == "-" ? -1 : 1
            let parts = tail.dropFirst().split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            offset = sign * (h * 3600 + m * 60)
        }
        return Moment(instant: instant, offsetSeconds: offset)
    }

    // JSCalendar's UTCDateTime is RFC 3339 in UTC with a Z; we accept any
    // offset on read, since the instant is what matters.
    static func parseUTCDateTime(_ s: String) -> Date? {
        parseInternetDateTime(s)
    }

    // Date.ISO8601FormatStyle rather than ISO8601DateFormatter: every read
    // decodes every Task, and the formatter cost more than a hundred
    // microseconds just to construct and tens more per parse, which over
    // a few thousand ended Tasks was most of a CLI run. The style is a
    // Sendable value, so one can be shared without ceremony, and parses
    // in about a microsecond. It takes a Z or an offset, with or without
    // fractional seconds, and rejects a bare day or a zoneless time, as
    // the formatter did. -- claude, 2026-10-29
    private static let internetDateTime = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    private static let fractionalInternetDateTime = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func parseInternetDateTime(_ s: String) -> Date? {
        (try? internetDateTime.parse(s)) ?? (try? fractionalInternetDateTime.parse(s))
    }

    static func utcDateTime(_ instant: Date) -> String {
        internetDateTime.format(instant)
    }

    // The moment at its own offset, so the string's day is the Moment's
    // civil day. A zero offset prints as "Z", which the spec allows.
    static func rfc3339(_ moment: Moment) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = moment.zone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return f.string(from: moment.instant)
    }
}
