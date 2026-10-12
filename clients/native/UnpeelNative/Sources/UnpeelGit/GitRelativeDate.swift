import Foundation

/// The compact age shown on a commit row: `now`, `5m`, `3h`, `2d`, `2w`,
/// `2mo`, `2y`. The exact date is in the row's tooltip.
enum GitRelativeDate {
    static func text(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        let minute = 60.0, hour = 3600.0, day = 86400.0
        switch seconds {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(seconds / minute))m"
        case ..<day: return "\(Int(seconds / hour))h"
        case ..<(7 * day): return "\(Int(seconds / day))d"
        case ..<(30 * day): return "\(Int(seconds / (7 * day)))w"
        case ..<(365 * day): return "\(Int(seconds / (30 * day)))mo"
        default: return "\(Int(seconds / (365 * day)))y"
        }
    }

    static let tooltipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
