import AppKit

/// Fork-only: date modified column. The text a row shows for its date,
/// compact enough for the sidebar: the time for today, "Yesterday", the
/// month and day for this year, a numeric date before that. Never relative
/// ("5 min ago") text, which would go stale on screen; the outline re-reads
/// its rows when the calendar day changes instead.
public struct ExplorerDateText: Sendable {
    private let calendar: Calendar
    private let time: Date.FormatStyle
    private let monthDay: Date.FormatStyle
    private let numeric: Date.FormatStyle
    private let full: Date.FormatStyle

    /// The defaults follow the system's settings as they change; a
    /// calendar's own `timeZone` is a snapshot, so the zone is separate.
    public init(
        calendar: Calendar = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        var zoned = calendar
        zoned.timeZone = timeZone
        self.calendar = zoned
        let base = Date.FormatStyle(locale: locale, calendar: zoned, timeZone: timeZone)
        time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: zoned, timeZone: timeZone)
        monthDay = base.month(.abbreviated).day()
        numeric = base.month(.defaultDigits).day(.defaultDigits).year(.twoDigits)
        full = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: zoned, timeZone: timeZone)
    }

    public func string(for date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(monthDay) }
        return date.formatted(numeric)
    }

    /// The row's tooltip.
    public func fullString(for date: Date) -> String {
        date.formatted(full)
    }

    /// The widest text any date can produce in `font`, so every row's date
    /// field shares one width and the dates line up.
    public func columnWidth(font: NSFont) -> CGFloat {
        let samples = Self.sampleComponents.compactMap(calendar.date(from:))
        let texts = ["Yesterday"] + samples.flatMap { [$0.formatted(time), $0.formatted(monthDay), $0.formatted(numeric)] }
        let widest = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 1
    }

    /// Two-digit days and minutes in every month, morning and afternoon.
    private static let sampleComponents: [DateComponents] = (1...12).flatMap { month in
        [10, 22].map { hour in DateComponents(year: 2025, month: month, day: 28, hour: hour, minute: 59) }
    }
}
