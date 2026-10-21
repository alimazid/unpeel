import AppKit

/// Fork-only: date modified column. Each entry row's date, in a field of
/// one width at the row's trailing edge so the dates of every depth line up.
extension ExplorerOutlineController {
    /// Every row reserves the column, so a note or a Draft Row ends where
    /// the names of its neighbours do.
    func resetDate(of cell: ExplorerRowCellView) {
        let font = dateFont
        cell.dateField?.font = font
        cell.dateField?.stringValue = ""
        cell.dateField?.toolTip = nil
        cell.dateWidth?.constant = dateColumnWidth(font: font)
        cell.restingDateColor = palette.secondaryText
    }

    func showDate(_ date: Date?, in cell: ExplorerRowCellView) {
        guard let date else { return }
        cell.dateField?.stringValue = dateText.string(for: date, now: now())
        cell.dateField?.toolTip = dateText.fullString(for: date)
    }

    /// Two points under the row font, with digits of one width so times
    /// and dates align digit for digit.
    private var dateFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(palette.rowFont.pointSize - 2, 9), weight: .regular)
    }

    /// Measured once per font: every row asks.
    private func dateColumnWidth(font: NSFont) -> CGFloat {
        if let measured = measuredDateColumn, measured.font == font { return measured.width }
        let width = dateText.columnWidth(font: font)
        measuredDateColumn = (font, width)
        return width
    }
}
