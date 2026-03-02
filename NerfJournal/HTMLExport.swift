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

    // Group todos by effective category; unknown IDs fall into "Other".
    var todosByCat: [Int64?: [Todo]] = [:]
    for todo in todos {
        let key: Int64? = todo.categoryID.flatMap { catByID[$0] != nil ? $0 : nil }
        todosByCat[key, default: []].append(todo)
    }
    let knownCatIDs = todosByCat.keys.compactMap { $0 }
        .sorted { (catByID[$0]?.sortOrder ?? 0) < (catByID[$1]?.sortOrder ?? 0) }

    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    var body = ""

    func renderGroup(category: Category?, groupTodos: [Todo]) {
        let name = esc(category?.name ?? "Other")
        let dot: String
        if let hex = category?.color.cssHex {
            dot = "<span class=\"dot\" style=\"background:\(hex)\"></span>"
        } else {
            dot = "<span class=\"dot\" style=\"background:#999\"></span>"
        }
        body += "<section>\n<h2>\(dot)\(name)</h2>\n<ul>\n"
        for todo in groupTodos {
            let (sym, cls, cap) = todoDisplayState(todo, pageDay: pageDay, cal: cal)
            body += "<li class=\"\(cls)\">"
            body += "<span class=\"sym\">\(sym)</span>"
            body += cls == "done" ? "<s>\(esc(todo.title))</s>" : esc(todo.title)
            if let url = todo.externalURL, !url.isEmpty {
                body += "<div class=\"meta\"><a href=\"\(esc(url))\">\(esc(url))</a></div>"
            }
            if let cap {
                body += "<div class=\"meta\">\(esc(cap))</div>"
            }
            body += "</li>\n"
        }
        body += "</ul>\n</section>\n"
    }

    for id in knownCatIDs { renderGroup(category: catByID[id], groupTodos: todosByCat[id]!) }
    if let uncategorized = todosByCat[nil] { renderGroup(category: nil, groupTodos: uncategorized) }

    let visibleNotes = notes.filter { $0.text != nil }
    if !visibleNotes.isEmpty {
        body += "<section class=\"notes\">\n<h2>Notes</h2>\n"
        for note in visibleNotes {
            body += "<div class=\"note\">"
            body += "<div class=\"note-text\">\(esc(note.text!))</div>"
            body += "<div class=\"note-time\">\(esc(timeFormatter.string(from: note.timestamp)))</div>"
            body += "</div>\n"
        }
        body += "</section>\n"
    }

    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <title>NerfJournal \u{2013} \(esc(pageTitle))</title>
    <style>
    body{font-family:-apple-system,Helvetica,sans-serif;max-width:680px;margin:2em auto;color:#1d1d1f;line-height:1.5}
    h1{font-size:1.3em;margin:0 0 1em}
    h2{font-size:.85em;font-weight:600;color:#666;margin:1.1em 0 .3em;display:flex;align-items:center;gap:.35em}
    .dot{width:10px;height:10px;border-radius:50%;flex-shrink:0;display:inline-block}
    ul{list-style:none;padding:0;margin:0}
    li{padding:.2em 0}
    .sym{display:inline-block;width:1.3em}
    .done{color:#555}
    .abandoned{color:#bbb}
    .migrated{color:#bbb}
    .meta{font-size:.8em;color:#888;margin-left:1.3em}
    .notes{margin-top:1.5em;border-top:1px solid #ddd;padding-top:.5em}
    .note{margin:.6em 0}
    .note-text{white-space:pre-wrap}
    .note-time{font-size:.8em;color:#888;margin-top:.15em}
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
        // Ended on this page's day.
        return ending.kind == .done ? ("✓", "done", carried) : ("✗", "abandoned", nil)
    }
    // Was open on this page, resolved on a later day.
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
