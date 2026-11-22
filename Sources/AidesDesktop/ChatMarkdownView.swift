import Foundation
import SwiftUI

struct ChatMarkdownView: View {
    let source: String
    var bodySize: CGFloat = 13
    var codeSize: CGFloat = 12

    var body: some View {
        let document = ChatMarkdownDocument(source)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(document.sections.indices, id: \.self) { index in
                let section = document.sections[index]
                sectionView(section)
                    .padding(.top, spacing(before: index, in: document))
            }
        }
        .font(.system(size: bodySize))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spacing(before index: Int, in document: ChatMarkdownDocument) -> CGFloat {
        guard index > 0 else { return 0 }
        if document.sections[index - 1].isHeading { return bodySize * 1.25 }
        return document.sections[index].isListItem ? 5 : bodySize * 0.85
    }

    @ViewBuilder
    private func sectionView(_ section: ChatMarkdownDocument.Section) -> some View {
        switch section {
        case .block(let block):
            HStack(alignment: .top, spacing: 8) {
                if block.isListItem {
                    Text(block.listMarker ?? " ")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(block.listMarker == nil)
                }
                blockView(block)
            }
            .padding(.leading, CGFloat(max(block.listDepth - 1, 0)) * 18)
            .modifier(QuoteStyle(depth: block.quoteDepth))
        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(table.rows.indices, id: \.self) { index in
                        GridRow {
                            ForEach(table.columns.indices, id: \.self) { column in
                                inlineText(table.rows[index].cells[column] ?? AttributedString())
                                    .fontWeight(table.rows[index].isHeader ? .semibold : .regular)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: columnAlignment(table.columns[column]))
                            }
                        }
                        .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.045) : Color.clear)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatMarkdownDocument.Block) -> some View {
        switch block.kind {
        case .header(level: let level):
            inlineText(block.text)
                .font(.system(size: bodySize * max(1.0, 1.62 - Double(level - 1) * 0.14), weight: .semibold))
                .accessibilityAddTraits(.isHeader)
        case .codeBlock:
            ScrollView(.horizontal) {
                let code = String(block.text.characters)
                Text(verbatim: code.hasSuffix("\n") ? String(code.dropLast()) : code)
                    .font(.system(size: codeSize, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        case .thematicBreak:
            Rectangle().fill(.quaternary).frame(height: 1).accessibilityHidden(true)
        default:
            inlineText(block.text)
        }
    }

    private func inlineText(_ source: AttributedString) -> some View {
        let codeRuns = source.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
        return Group {
            if codeRuns.isEmpty {
                Text(source)
            } else {
                textWithMarkedCode(source, codeRuns: codeRuns)
                    .textRenderer(InlineCodeBackground())
            }
        }
        .lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func textWithMarkedCode(_ source: AttributedString, codeRuns: [AttributedString.Runs.Run]) -> Text {
        var text: Text?
        var start = source.startIndex
        for run in codeRuns {
            if start < run.range.lowerBound {
                append(Text(AttributedString(source[start..<run.range.lowerBound])), to: &text)
            }
            let code = Text(AttributedString(source[run.range]))
                .font(.system(size: codeSize, design: .monospaced))
                .customAttribute(InlineCode())
            append(code, to: &text)
            start = run.range.upperBound
        }
        if start < source.endIndex {
            append(Text(AttributedString(source[start..<source.endIndex])), to: &text)
        }
        return text ?? Text(source)
    }

    private func append(_ next: Text, to text: inout Text?) {
        if let previous = text {
            text = Text("\(previous)\(next)")
        } else {
            text = next
        }
    }

    private func columnAlignment(_ column: PresentationIntent.TableColumn) -> Alignment {
        switch column.alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}

private struct InlineCode: TextAttribute {}

private struct InlineCodeBackground: TextRenderer {
    private let horizontalInset: CGFloat = 4
    private let verticalInset: CGFloat = 2

    var displayPadding: EdgeInsets {
        EdgeInsets(top: verticalInset, leading: horizontalInset, bottom: verticalInset, trailing: horizontalInset)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line where run[InlineCode.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: -horizontalInset, dy: -verticalInset)
                let pill = Path(roundedRect: bounds, cornerRadius: 4)
                context.fill(pill, with: .color(.primary.opacity(0.1)))
            }
            context.draw(line)
        }
    }
}

private struct QuoteStyle: ViewModifier {
    let depth: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if depth > 0 {
            content
                .padding(.leading, CGFloat(depth) * 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(.quaternary).frame(width: 3)
                }
        } else {
            content
        }
    }
}

struct ChatMarkdownDocument {
    struct Block {
        let components: [PresentationIntent.IntentType]
        var text = AttributedString()
        var listMarker: String?

        var kind: PresentationIntent.Kind { components.first?.kind ?? .paragraph }
        var listDepth: Int {
            components.count { if case .listItem = $0.kind { true } else { false } }
        }
        var isListItem: Bool { listDepth > 0 }
        var quoteDepth: Int {
            components.count { if case .blockQuote = $0.kind { true } else { false } }
        }
    }

    struct Row {
        let identity: Int
        let isHeader: Bool
        var cells: [Int: AttributedString] = [:]
    }

    struct Table {
        let identity: Int
        let columns: [PresentationIntent.TableColumn]
        var rows: [Row] = []
    }

    enum Section {
        case block(Block)
        case table(Table)

        var isListItem: Bool {
            if case .block(let block) = self { block.isListItem } else { false }
        }

        var isHeading: Bool {
            guard case .block(let block) = self, case .header = block.kind else { return false }
            return true
        }
    }

    var sections: [Section] = []

    init(_ source: String) {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            sections = [.block(Block(components: [], text: AttributedString(source)))]
            return
        }
        var blocks: [Block] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            var content = AttributedString(parsed[run.range])
            content.presentationIntent = nil
            content.imageURL = nil
            if let url = run.link, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                content.link = nil
            }
            if blocks.last?.components.first?.identity != components.first?.identity || blocks.isEmpty {
                blocks.append(Block(components: components))
            }
            blocks[blocks.count - 1].text.append(content)
        }

        var seenListItems: Set<Int> = []
        for var block in blocks {
            if let cell = tableCell(for: block) {
                append(cell, text: block.text)
                continue
            }
            if let index = block.components.firstIndex(where: {
                if case .listItem = $0.kind { true } else { false }
            }),
               case .listItem(ordinal: let number) = block.components[index].kind,
               seenListItems.insert(block.components[index].identity).inserted {
                let list = block.components.dropFirst(index + 1).first
                block.listMarker = list?.kind == .orderedList ? "\(number)." : "•"
            }
            sections.append(.block(block))
        }
    }

    private struct TableCell {
        let table: Table
        let row: Row
        let column: Int
    }

    private func tableCell(for block: Block) -> TableCell? {
        guard case .tableCell(columnIndex: let column) = block.kind,
              let table = block.components.first(where: {
                  if case .table = $0.kind { true } else { false }
              }), case .table(columns: let columns) = table.kind,
              let row = block.components.dropFirst().first else { return nil }
        return TableCell(
            table: Table(identity: table.identity, columns: columns),
            row: Row(identity: row.identity, isHeader: row.kind == .tableHeaderRow),
            column: column
        )
    }

    private mutating func append(_ cell: TableCell, text: AttributedString) {
        var table = cell.table
        if case .table(let previous) = sections.last, previous.identity == cell.table.identity {
            table = previous
            sections.removeLast()
        }
        if table.rows.last?.identity != cell.row.identity {
            table.rows.append(cell.row)
        }
        table.rows[table.rows.count - 1].cells[cell.column] = text
        sections.append(.table(table))
    }
}
