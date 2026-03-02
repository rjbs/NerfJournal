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
    // Mirrors JournalPageDetailView.activityItems sort (timestamp, then todo
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

    // Activity section — flex rows with fixed dot/time/indicator columns.
    // Only abandoned items are struck through; done items use the ✔ indicator.
    if !activityItems.isEmpty {
        body += "<section>\n<h2>Activity</h2>\n<ul class=\"rows\">\n"
        for item in activityItems {
            switch item {
            case .todo(let todo):
                let (_, cls, cap) = todoDisplayState(todo, pageDay: pageDay, cal: cal)
                let dotColor = todo.categoryID.flatMap { catByID[$0]?.color.cssHex } ?? "#999"
                let ts = esc(timeFormatter.string(from: todo.ending!.date))
                let isAbandoned = cls == "abandoned"
                var titleHTML = isAbandoned ? "<s>\(esc(todo.title))</s>" : esc(todo.title)
                if let url = todo.externalURL, !url.isEmpty {
                    titleHTML += " \(linkTag(for: url))"
                }
                let ind: String
                switch cls {
                case "done":      ind = "\u{2714}"
                case "abandoned": ind = "\u{2717}"
                default:          ind = ""
                }
                body += "<li class=\"row \(cls)\">"
                body += "<span class=\"dot-slot\">\(dotSpan(color: dotColor))</span>"
                body += "<span class=\"ts\">\(ts)</span>"
                body += "<span class=\"ind\">\(ind)</span>"
                body += "<span class=\"bd\">\(titleHTML)"
                if let cap { body += "<div class=\"cap\">\(esc(cap))</div>" }
                body += "</span></li>\n"

            case .note(let note):
                let ts = esc(timeFormatter.string(from: note.timestamp))
                body += "<li class=\"row note-row\">"
                body += "<span class=\"dot-slot\"></span>"
                body += "<span class=\"ts\">\(ts)</span>"
                body += "<span class=\"ind\"></span>"
                body += "<span class=\"bd note-text\">\(esc(note.text!))</span>"
                body += "</li>\n"
            }
        }
        body += "</ul>\n</section>\n"
    }

    // Open/leftover todos — grouped by category.
    // Both done and abandoned items are struck through in this view.
    func renderGroup(category: Category?, groupTodos: [Todo]) {
        let dot = dotSpan(color: category?.color.cssHex ?? "#999")
        body += "<section>\n<h2>\(dot)\(esc(category?.name ?? "Other"))</h2>\n<ul class=\"rows\">\n"
        for todo in groupTodos {
            let (sym, cls, cap) = todoDisplayState(todo, pageDay: pageDay, cal: cal)
            let isStruck = cls == "done" || cls == "abandoned"
            var titleHTML = isStruck ? "<s>\(esc(todo.title))</s>" : esc(todo.title)
            if let url = todo.externalURL, !url.isEmpty {
                titleHTML += " \(linkTag(for: url))"
            }
            body += "<li class=\"row \(cls)\">"
            body += "<span class=\"sym\">\(sym)</span>"
            body += "<span class=\"bd\">\(titleHTML)"
            if let cap { body += "<div class=\"cap\">\(esc(cap))</div>" }
            body += "</span></li>\n"
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
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;font-size:14px;line-height:1.5;color:#24292e;background:#f6f8fa;padding:24px 16px}
    .page{max-width:680px;margin:0 auto}
    h1{font-size:22px;margin-bottom:20px}
    section{background:#fff;border:1px solid #e1e4e8;border-radius:6px;padding:16px;margin-bottom:16px}
    h2{font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.06em;color:#57606a;margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid #e1e4e8;display:flex;align-items:center;gap:6px}
    .dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;display:inline-block}
    ul.rows{list-style:none}
    li.row{display:flex;align-items:baseline;gap:8px;padding:6px 0;border-bottom:1px solid #f0f0f0}
    li.row:last-child{border-bottom:none}
    .dot-slot{width:9px;flex-shrink:0;align-self:center}
    .ts{font-size:12px;color:#57606a;white-space:nowrap;font-variant-numeric:tabular-nums;flex-shrink:0;width:5.5em;text-align:right}
    .ind{width:1em;flex-shrink:0;text-align:center;font-size:12px}
    .bd{flex:1 1 auto;min-width:0}
    .sym{width:1.3em;flex-shrink:0;text-align:center}
    .done{color:#57606a}
    .abandoned{color:#8c959f}
    .migrated{color:#8c959f}
    .note-text{white-space:pre-wrap;color:#57606a}
    .cap{font-size:12px;color:#8c959f;margin-top:2px}
    a.exturl{font-size:12px;color:#8c959f;text-decoration:underline dashed;margin-left:4px}
    a.exturl:link,a.exturl:visited{color:#8c959f}
    </style>
    </head>
    <body>
    <div class="page">
    <h1>\(esc(pageTitle))</h1>
    \(body)</div>
    </body>
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
