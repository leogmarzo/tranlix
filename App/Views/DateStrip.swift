import SwiftUI

/// One week of days at the top of the sidebar. Picking one narrows the list to that day.
///
/// Small on purpose. The question it answers is "what did I record on Thursday", and a full
/// calendar grid for that pushed the session list off the screen. Always a whole week, Sunday
/// to Saturday, so a weekday sits in the same place every time; older weeks are one click on
/// the arrows, or a jump through the month picker behind the title.
struct DateStrip: View {
    let recordingDays: Set<Date>
    @Binding var selectedDay: Date?

    /// The Sunday the visible week starts on.
    @State private var start = DayCalendar.startOfWeek(containing: Date())
    @State private var showsMonthPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            week
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                showsMonthPicker = true
            } label: {
                HStack(spacing: 3) {
                    Text(DayCalendar.rangeTitle(from: start, to: end))
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Elegir otro mes")

            Spacer()

            Button("Hoy") {
                start = DayCalendar.startOfWeek(containing: DayCalendar.today)
                selectedDay = DayCalendar.today
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        // Anchored to the whole row rather than the title: from the title, near the sidebar's
        // edge, the popover hung off the side of the window.
        .popover(isPresented: $showsMonthPicker, arrowEdge: .bottom) {
            MonthPicker(
                recordingDays: recordingDays,
                selectedDay: selectedDay,
                showing: selectedDay ?? start
            ) { day in
                selectedDay = day
                start = DayCalendar.startOfWeek(containing: day)
                showsMonthPicker = false
            }
        }
    }

    /// The arrows flank the days and are as tall as them: the small chevrons in the header
    /// were a few points wide and took aiming to hit.
    private var week: some View {
        HStack(spacing: 0) {
            WeekArrow(systemImage: "chevron.left", help: "Semana anterior") { move(by: -7) }
            ForEach(DayCalendar.days(from: start, count: 7), id: \.self) { day in
                DayCell(
                    date: day,
                    weekday: DayCalendar.weekdaySymbol(for: day),
                    isSelected: selectedDay == day,
                    hasRecordings: recordingDays.contains(day)
                ) {
                    select(day)
                }
                .frame(maxWidth: .infinity)
            }
            WeekArrow(systemImage: "chevron.right", help: "Semana siguiente") { move(by: 7) }
        }
    }

    private var end: Date {
        DayCalendar.add(days: 6, to: start)
    }

    /// A second click on the picked day lets go of it, the same as «Mostrar todas».
    private func select(_ day: Date) {
        selectedDay = selectedDay == day ? nil : day
    }

    private func move(by days: Int) {
        start = DayCalendar.add(days: days, to: start)
    }
}

/// A previous or next week button, sized for a finger on a trackpad rather than a cursor tip.
private struct WeekArrow: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One day in the strip or in the month picker: the number, and a dot when something was
/// recorded that day.
struct DayCell: View {
    let date: Date
    var weekday: String?
    let isSelected: Bool
    let hasRecordings: Bool
    var isInOtherMonth = false
    let action: () -> Void

    private var isToday: Bool { date == DayCalendar.today }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                if let weekday {
                    Text(weekday)
                        .font(.caption2)
                        .foregroundStyle(isToday ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                }
                Text(date.formatted(.dateTime.day()))
                    .font(.callout)
                    .fontWeight(isToday ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(numberStyle)
                    .frame(width: 24, height: 24)
                    .background {
                        if isSelected { Circle().fill(Color.accentColor) }
                    }
                Circle()
                    .fill(hasRecordings ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
                    .frame(width: 4, height: 4)
            }
            .frame(width: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var numberStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(Color.accentColor) }
        if isInOtherMonth { return AnyShapeStyle(.tertiary) }
        return AnyShapeStyle(.primary)
    }

    /// The dot alone would leave VoiceOver with a bare number.
    private var accessibilityText: String {
        let day = DayCalendar.dayTitle(date)
        return hasRecordings ? "\(day), con grabaciones" : "\(day), sin grabaciones"
    }
}

/// A month of days behind the strip's range title, for going further back than two weeks.
struct MonthPicker: View {
    let recordingDays: Set<Date>
    let selectedDay: Date?
    let onPick: (Date) -> Void

    @State private var month: Date

    init(recordingDays: Set<Date>, selectedDay: Date?, showing day: Date, onPick: @escaping (Date) -> Void) {
        self.recordingDays = recordingDays
        self.selectedDay = selectedDay
        self.onPick = onPick
        _month = State(initialValue: DayCalendar.startOfMonth(containing: day))
    }

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: 2), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(DayCalendar.monthTitle(month))
                    .font(.headline)
                Spacer()
                Button { month = DayCalendar.add(months: -1, to: month) } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Mes anterior")
                Button { month = DayCalendar.add(months: 1, to: month) } label: {
                    Image(systemName: "chevron.right")
                }
                .help("Mes siguiente")
            }
            .buttonStyle(.borderless)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(DayCalendar.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(DayCalendar.monthGrid(for: month), id: \.self) { day in
                    DayCell(
                        date: day,
                        isSelected: selectedDay == day,
                        hasRecordings: recordingDays.contains(day),
                        isInOtherMonth: !DayCalendar.isDate(day, inMonthOf: month)
                    ) {
                        onPick(day)
                    }
                }
            }
        }
        .padding(12)
    }
}

/// The Sunday-first, Spanish calendar the strip and the month picker draw with.
///
/// Set explicitly rather than taken from the system, so the week is laid out the same way
/// whatever the Mac's region settings say.
enum DayCalendar {
    static let locale = Locale(identifier: "es_AR")

    static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = locale
        calendar.firstWeekday = 1
        return calendar
    }

    static var today: Date { calendar.startOfDay(for: Date()) }

    static func add(days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }

    static func add(months: Int, to date: Date) -> Date {
        calendar.date(byAdding: .month, value: months, to: date) ?? date
    }

    static func startOfWeek(containing date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func startOfMonth(containing date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    static func days(from start: Date, count: Int) -> [Date] {
        (0..<count).map { add(days: $0, to: start) }
    }

    /// Six full weeks from the Sunday on or before the first of the month, so the grid keeps
    /// its height from one month to the next.
    static func monthGrid(for month: Date) -> [Date] {
        days(from: startOfWeek(containing: startOfMonth(containing: month)), count: 42)
    }

    static func isDate(_ date: Date, inMonthOf month: Date) -> Bool {
        calendar.isDate(date, equalTo: month, toGranularity: .month)
    }

    /// "dom", "lun", "mar", …, Sunday first like the grid.
    static var weekdaySymbols: [String] {
        calendar.shortStandaloneWeekdaySymbols.map(trimmed)
    }

    static func weekdaySymbol(for date: Date) -> String {
        trimmed(calendar.shortStandaloneWeekdaySymbols[calendar.component(.weekday, from: date) - 1])
    }

    /// "Jueves, 29 de octubre", with the year once it stops being obvious.
    static func dayTitle(_ date: Date) -> String {
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return format(date, sameYear ? "EEEE, d 'de' MMMM" : "EEEE, d 'de' MMMM 'de' yyyy")
    }

    /// "Noviembre 2026" for a month.
    static func monthTitle(_ month: Date) -> String {
        format(month, "LLLL yyyy")
    }

    /// "Noviembre 2026" when the strip sits inside one month, "Oct – Nov 2026" across two.
    static func rangeTitle(from start: Date, to end: Date) -> String {
        if calendar.isDate(start, equalTo: end, toGranularity: .month) {
            return monthTitle(start)
        }
        if calendar.isDate(start, equalTo: end, toGranularity: .year) {
            return "\(format(start, "LLL")) – \(format(end, "LLL yyyy"))"
        }
        return "\(format(start, "LLL yyyy")) – \(format(end, "LLL yyyy"))"
    }

    /// Capitalized like a heading: only the first letter. `capitalized` would also turn
    /// "de octubre" into "De Octubre".
    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateFormat = pattern
        let text = trimmed(formatter.string(from: date))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Spanish abbreviations come with a period ("oct.", "mié."), which is noise in a strip
    /// this narrow.
    private static func trimmed(_ text: String) -> String {
        text.replacingOccurrences(of: ".", with: "")
    }
}
