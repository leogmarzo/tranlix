import Foundation
import TranlixStore

/// Sessions bucketed by how recently they happened.
///
/// A flat list is fine at five sessions and unusable at fifty, which is one term of classes.
/// The buckets are the ones people actually use to remember when something was: today, this
/// week, and then by month.
enum SessionGrouping {
    struct Group: Identifiable {
        let title: String
        let sessions: [SessionSummary]
        var id: String { title }
    }

    static func groups(
        for sessions: [SessionSummary],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        // Order is by session date already, so keeping first-seen order keeps the groups in
        // the same order without sorting them separately.
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]

        for session in sessions {
            let title = title(for: session.createdAt, now: now, calendar: calendar)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(session)
        }

        return order.map { Group(title: $0, sessions: buckets[$0] ?? []) }
    }

    private static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Hoy" }
        if calendar.isDateInYesterday(date) { return "Ayer" }

        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
            return "Esta semana"
        }

        // Older than a week: the month is enough, with the year once it stops being obvious.
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date).capitalized
    }
}
