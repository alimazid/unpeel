import Foundation
import Markdown

/// Markdown → HTML body. Raw HTML in the source is always emitted as escaped
/// text: the preview shows the user's file, never runs it.
public enum MarkdownHTMLRenderer {
    public static func html(from markdown: String) -> String {
        let document = Document(parsing: markdown)
        var walker = HTMLWalker()
        return walker.visit(document)
    }

    /// `#Hello World` → `hello-world`, GitHub's rule minus the uniqueness suffix.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" {
                out += "-"
            }
        }
        return out
    }
}

private struct HTMLWalker: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    // MARK: Blocks

    mutating func visitDocument(_ document: Document) -> String {
        defaultVisit(document)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = defaultVisit(heading)
        let id = MarkdownHTMLRenderer.slug(heading.plainText)
        return "<h\(heading.level) id=\"\(HTMLEscaping.escapeAttribute(id))\">\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(defaultVisit(paragraph))</p>\n"
    }

    mutating func visitBlockQuote(_ quote: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(quote))</blockquote>\n"
    }

    mutating func visitCodeBlock(_ block: CodeBlock) -> String {
        let cls = block.language.map { " class=\"language-\(HTMLEscaping.escapeAttribute($0))\"" } ?? ""
        return "<pre><code\(cls)>\(HTMLEscaping.escape(block.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        "<p>\(HTMLEscaping.escape(html.rawHTML.trimmingCharacters(in: .newlines)))</p>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(list))</ul>\n"
    }

    mutating func visitOrderedList(_ list: OrderedList) -> String {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        return "<ol\(start)>\n\(defaultVisit(list))</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) -> String {
        // A single-paragraph item renders inline (`<li>text</li>`) like
        // GitHub's tight lists; anything richer keeps its block markup.
        let inner: String
        if item.childCount == 1, let paragraph = item.child(at: 0) as? Paragraph {
            inner = defaultVisit(paragraph)
        } else {
            inner = defaultVisit(item)
        }
        switch item.checkbox {
        case .checked:
            return "<li class=\"task\"><input type=\"checkbox\" disabled checked> \(inner)</li>\n"
        case .unchecked:
            return "<li class=\"task\"><input type=\"checkbox\" disabled> \(inner)</li>\n"
        case nil:
            return "<li>\(inner)</li>\n"
        }
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) -> String {
        alignments = table.columnAlignments
        let head = visit(table.head)
        let body = visit(table.body)
        return "<table>\n<thead>\n\(head)</thead>\n<tbody>\n\(body)</tbody>\n</table>\n"
    }

    private var alignments: [Table.ColumnAlignment?] = []

    mutating func visitTableHead(_ head: Table.Head) -> String {
        "<tr>\(cells(of: head, tag: "th"))</tr>\n"
    }

    mutating func visitTableBody(_ body: Table.Body) -> String {
        defaultVisit(body)
    }

    mutating func visitTableRow(_ row: Table.Row) -> String {
        "<tr>\(cells(of: row, tag: "td"))</tr>\n"
    }

    private mutating func cells(of container: Markup, tag: String) -> String {
        var out = ""
        for (index, cell) in container.children.enumerated() {
            let align = index < alignments.count ? alignments[index] : nil
            let attr: String
            switch align {
            case .left: attr = " align=\"left\""
            case .center: attr = " align=\"center\""
            case .right: attr = " align=\"right\""
            case nil: attr = ""
            }
            out += "<\(tag)\(attr)>\(defaultVisit(cell))</\(tag)>"
        }
        return out
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) -> String {
        HTMLEscaping.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strike: Strikethrough) -> String {
        "<del>\(defaultVisit(strike))</del>"
    }

    mutating func visitInlineCode(_ code: InlineCode) -> String {
        "<code>\(HTMLEscaping.escape(code.code))</code>"
    }

    mutating func visitInlineHTML(_ html: InlineHTML) -> String {
        HTMLEscaping.escape(html.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = HTMLEscaping.escapeAttribute(link.destination ?? "")
        return "<a href=\"\(href)\">\(defaultVisit(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = HTMLEscaping.escapeAttribute(image.source ?? "")
        let alt = HTMLEscaping.escapeAttribute(image.plainText)
        let title = image.title.map { " title=\"\(HTMLEscaping.escapeAttribute($0))\"" } ?? ""
        return "<img src=\"\(src)\" alt=\"\(alt)\"\(title)>"
    }
}
