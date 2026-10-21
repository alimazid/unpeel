import AppKit
import XCTest
@testable import UnpeelExplorer

/// Fork-only: date modified column. The compact text a row shows for its
/// date: narrow enough for the sidebar, and never relative ("5 min ago")
/// text that would go stale on screen.
private let utcZone = TimeZone(identifier: "UTC")!

final class ExplorerDateTextTests: XCTestCase {
    private let text = ExplorerDateText(calendar: ExplorerDateTextTests.aucklandCalendar, locale: Locale(identifier: "en_US"), timeZone: utcZone)
    /// Wednesday 21 October 2026, 15:30 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_596_600)

    /// A calendar in another zone: the zone passed in is the one used.
    private static var aucklandCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return calendar
    }

    private func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    /// ICU separates the time from AM/PM with a narrow no-break space.
    private func plain(_ string: String) -> String {
        string.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testTodayShowsTheTime() {
        XCTAssertEqual(plain(text.string(for: ago(hours: 6), now: now)), "9:30 AM")
    }

    func testYesterdayIsNamed() {
        XCTAssertEqual(text.string(for: ago(hours: 20), now: now), "Yesterday")
    }

    func testEarlierThisYearShowsMonthAndDay() {
        XCTAssertEqual(text.string(for: ago(hours: 24 * 18), now: now), "Oct 3")
    }

    func testOtherYearsShowANumericDate() {
        XCTAssertEqual(text.string(for: ago(hours: 24 * 400), now: now), "9/16/25")
    }

    func testAFutureDateIsNeverCalledToday() {
        XCTAssertEqual(text.string(for: now.addingTimeInterval(24 * 3600 * 3), now: now), "Oct 24")
    }

    func testTheTooltipNamesTheFullDateAndTime() {
        XCTAssertEqual(plain(text.fullString(for: ago(hours: 6))), "Wednesday, October 21, 2026 at 9:30 AM")
    }

    /// Every format fits the column, so dates line up and never truncate.
    @MainActor
    func testColumnWidthFitsEveryFormat() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let width = text.columnWidth(font: font)
        let samples = [ago(hours: 0.5), ago(hours: 20), ago(hours: 24 * 18), ago(hours: 24 * 400)]
            .map { text.string(for: $0, now: now) } + ["12:59 PM", "12/31/25"]
        for sample in samples {
            let measured = (sample as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(measured, width, "“\(sample)” is wider than the column")
        }
        XCTAssertLessThan(width, 70, "the column must stay narrow enough for the sidebar")
    }
}
