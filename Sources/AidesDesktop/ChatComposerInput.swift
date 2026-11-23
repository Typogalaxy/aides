import AppKit
import SwiftUI

struct ChatComposerInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let fontSize: CGFloat
    let send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let field = ComposerTextView(usingTextLayoutManager: false)
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.allowsUndo = true
        field.drawsBackground = false
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = true
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.lineFragmentPadding = 0
        field.textContainerInset = .zero
        field.delegate = context.coordinator
        field.placeholder = placeholder
        field.setAccessibilityLabel(placeholder)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = field
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.input = self
        guard let field = scroll.documentView as? ComposerTextView else { return }
        field.placeholder = placeholder
        field.setAccessibilityLabel(placeholder)
        let font = NSFont.systemFont(ofSize: fontSize)
        if field.font != font {
            field.font = font
            field.needsDisplay = true
        }
        if !field.hasMarkedText(), field.string != text {
            field.string = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let measured = (text + " ").boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        return CGSize(width: width, height: min(7 * lineHeight, max(2 * lineHeight, ceil(measured))))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var input: ChatComposerInput

        init(_ input: ChatComposerInput) { self.input = input }

        func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextView, input.text != field.string else { return }
            input.text = field.string
        }

        func textView(_ field: NSTextView, doCommandBy command: Selector) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                guard !field.hasMarkedText() else { return false }
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
                if modifiers.contains(.shift) || command == #selector(NSResponder.insertLineBreak(_:)) {
                    field.insertText("\n", replacementRange: field.selectedRange())
                    return true
                }
                guard command == #selector(NSResponder.insertNewline(_:)),
                      modifiers.intersection([.control, .option]).isEmpty else { return false }
                input.send()
                return true
            case #selector(NSResponder.insertTab(_:)):
                field.window?.selectNextKeyView(field)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                field.window?.selectPreviousKeyView(field)
                return true
            default:
                return false
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = "" {
        didSet {
            if oldValue != placeholder { needsDisplay = true }
        }
    }

    var showsPlaceholder: Bool { string.isEmpty && !hasMarkedText() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder, let font else { return }
        let origin = textContainerOrigin
        let lineHeight = ceil(layoutManager?.defaultLineHeight(for: font) ?? (font.ascender - font.descender + font.leading))
        let line = NSRect(
            x: origin.x, y: origin.y,
            width: max(0, bounds.maxX - origin.x), height: lineHeight
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (placeholder as NSString).draw(
            with: line,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: paragraph]
        )
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
