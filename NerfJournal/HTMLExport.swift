import Foundation

func exportPageHTML(date: Date, todos: [Todo], notes: [Note], categories: [Category]) -> String {
    let cal = Calendar.current
    let pageDay = cal.startOfDay(for: date)

    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .full
    dateFormatter.timeStyle = .none
    let pageTitle = dateFormatter.string(from: date)

    let timeFormatter = DateFormatter()
    timeFormatter.dateStyle = .none
    timeFormatter.timeStyle = .short

    let catByID = Dictionary(uniqueKeysWithValues: categories.compactMap { c in c.id.map { ($0, c) } })

    // ── Activity items ─────────────────────────────────────────────────────
    // Todos resolved on this day, plus notes, merged chronologically.
    // Mirrors DiaryPageDetailView.activityItems sort (timestamp, then todo
    // before note on ties, then by id within kind).

    enum ActivityItem {
        case todo(Todo)
        case note(Note)
        var timestamp: Date {
            switch self { case .todo(let t): t.ending!.date; case .note(let n): n.timestamp }
        }
    }

    let activityTodos = todos.filter { t in
        t.ending.map { cal.isDate($0.date, inSameDayAs: pageDay) } ?? false
    }
    let openTodos = todos.filter { t in
        t.ending.map { !cal.isDate($0.date, inSameDayAs: pageDay) } ?? true
    }
    let visibleNotes = notes.filter { $0.text != nil }

    let activityItems: [ActivityItem] = (activityTodos.map(ActivityItem.todo)
                                       + visibleNotes.map(ActivityItem.note))
        .sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            switch ($0, $1) {
            case (.todo(let a), .todo(let b)): return a.id! < b.id!
            case (.note(let a), .note(let b)): return a.id! < b.id!
            case (.todo, .note): return true
            case (.note, .todo): return false
            }
        }

    // ── Open todos grouped by category ────────────────────────────────────

    var todosByCat: [Int64?: [Todo]] = [:]
    for todo in openTodos {
        let key: Int64? = todo.categoryID.flatMap { catByID[$0] != nil ? $0 : nil }
        todosByCat[key, default: []].append(todo)
    }
    let knownCatIDs = todosByCat.keys.compactMap { $0 }
        .sorted { (catByID[$0]?.sortOrder ?? 0) < (catByID[$1]?.sortOrder ?? 0) }

    // ── HTML helpers ───────────────────────────────────────────────────────

    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    func linkTag(for urlString: String) -> String {
        let domain = URL(string: urlString)?.host ?? urlString
        return "<a class=\"exturl\" href=\"\(esc(urlString))\">\(esc(domain))</a>"
    }

    func dotSpan(color: String) -> String {
        "<span class=\"dot\" style=\"background:\(color)\"></span>"
    }

    // ── Build body ─────────────────────────────────────────────────────────

    var body = ""

    // Activity section — table layout keeps the dot/time columns narrow and
    // the content column free to wrap naturally.
    if !activityItems.isEmpty {
        body += "<section>\n<h2>Activity</h2>\n<table class=\"act\">\n"
        for item in activityItems {
            switch item {
            case .todo(let todo):
                let (_, cls, cap) = todoDisplayState(todo, pageDay: pageDay, cal: cal)
                let dotColor = todo.categoryID.flatMap { catByID[$0]?.color.cssHex } ?? "#999"
                let ts = esc(timeFormatter.string(from: todo.ending!.date))
                var titleHTML = cls == "done" ? "<s>\(esc(todo.title))</s>" : esc(todo.title)
                if let url = todo.externalURL, !url.isEmpty {
                    titleHTML += " \(linkTag(for: url))"
                }
                body += "<tr class=\"\(cls)\">"
                body += "<td class=\"act-dot\">\(dotSpan(color: dotColor))</td>"
                body += "<td class=\"act-ts\">\(ts)</td>"
                body += "<td class=\"act-body\">\(titleHTML)"
                if let cap { body += "<div class=\"cap\">\(esc(cap))</div>" }
                body += "</td></tr>\n"

            case .note(let note):
                let ts = esc(timeFormatter.string(from: note.timestamp))
                body += "<tr class=\"note-row\">"
                body += "<td class=\"act-dot\"></td>"
                body += "<td class=\"act-ts\">\(ts)</td>"
                body += "<td class=\"act-body note-text\">\(esc(note.text!))</td>"
                body += "</tr>\n"
            }
        }
        body += "</table>\n</section>\n"
    }

    // Open/leftover todos — grouped by category, same structure as before.
    func renderGroup(category: Category?, groupTodos: [Todo]) {
        let dot = dotSpan(color: category?.color.cssHex ?? "#999")
        body += "<section>\n<h2>\(dot)\(esc(category?.name ?? "Other"))</h2>\n<ul>\n"
        for todo in groupTodos {
            let (sym, cls, cap) = todoDisplayState(todo, pageDay: pageDay, cal: cal)
            var titleHTML = cls == "done" ? "<s>\(esc(todo.title))</s>" : esc(todo.title)
            if let url = todo.externalURL, !url.isEmpty {
                titleHTML += " \(linkTag(for: url))"
            }
            body += "<li class=\"\(cls)\"><span class=\"sym\">\(sym)</span>\(titleHTML)"
            if let cap { body += "<div class=\"cap\">\(esc(cap))</div>" }
            body += "</li>\n"
        }
        body += "</ul>\n</section>\n"
    }

    for id in knownCatIDs { renderGroup(category: catByID[id], groupTodos: todosByCat[id]!) }
    if let uncategorized = todosByCat[nil] { renderGroup(category: nil, groupTodos: uncategorized) }

    // ── Template ───────────────────────────────────────────────────────────

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>NerfJournal \u{2013} \(esc(pageTitle))</title>
    <style>
    body{font-family:-apple-system,Helvetica,sans-serif;max-width:680px;margin:2em auto;color:#1d1d1f;line-height:1.5}
    h1{font-size:1.3em;margin:0 0 .8em}
    h2{font-size:.8em;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:#888;margin:1.3em 0 .3em;display:flex;align-items:center;gap:.4em}
    .dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;display:inline-block;vertical-align:middle}
    table.act{border-collapse:collapse;width:100%;margin-bottom:.5em}
    .act td{padding:.4em 0;vertical-align:middle}
    .act-dot{width:18px;text-align:center}
    .act-ts{font-size:.8em;color:#888;white-space:nowrap;padding:0 1em 0 .2em;text-align:right;font-variant-numeric:tabular-nums}
    .act-body{width:100%}
    ul{list-style:none;padding:0;margin:0 0 .5em}
    li{padding:.35em 0}
    .sym{display:inline-block;width:1.3em}
    .done{color:#555}
    .abandoned{color:#bbb}
    .migrated{color:#bbb}
    .note-text{white-space:pre-wrap;color:#444}
    .cap{font-size:.8em;color:#999;margin-left:1.3em}
    a.exturl{font-size:.8em;color:#999;text-decoration:underline dashed;margin-left:.35em}
    a.exturl:link,a.exturl:visited{color:#999}
    </style>
    </head>
    <body>
    <h1>\(esc(pageTitle))</h1>
    \(body)</body>
    </html>
    """
}

private func todoDisplayState(
    _ todo: Todo, pageDay: Date, cal: Calendar
) -> (symbol: String, cssClass: String, caption: String?) {
    let addedDay = cal.startOfDay(for: todo.added)
    let carried: String? = addedDay < pageDay ? {
        let n = cal.dateComponents([.day], from: addedDay, to: pageDay).day ?? 0
        return "Carried over \u{b7} \(n) day\(n == 1 ? "" : "s") ago"
    }() : nil

    guard let ending = todo.ending else {
        return ("○", "pending", carried)
    }
    let endDay = cal.startOfDay(for: ending.date)
    guard endDay > pageDay else {
        return ending.kind == .done ? ("✓", "done", carried) : ("✗", "abandoned", nil)
    }
    let n = cal.dateComponents([.day], from: pageDay, to: endDay).day ?? 0
    let cap = ending.kind == .done
        ? "Done \(n) day\(n == 1 ? "" : "s") later"
        : "Abandoned \(n) day\(n == 1 ? "" : "s") later"
    return ("→", "migrated", cap)
}

private extension CategoryColor {
    var cssHex: String {
        switch self {
        case .blue:   return "#3478f6"
        case .red:    return "#ff3b30"
        case .green:  return "#34c759"
        case .orange: return "#ff9500"
        case .purple: return "#af52de"
        case .pink:   return "#ff2d55"
        case .teal:   return "#5ac8fa"
        case .yellow: return "#ffcc00"
        }
    }
}
