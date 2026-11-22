import SwiftUI

struct DesktopTypography: Equatable, Sendable {
    static let uiKey = "aides.fontSize.interface"
    static let codeKey = "aides.fontSize.code"
    // Keep the on-disk key so existing font preferences survive the expanded setting.
    static let contentKey = "aides.fontSize.reply"

    static let defaultUISize = 13
    static let defaultCodeSize = 13
    static let defaultContentSize = 16

    static let uiRange = 11...20
    static let codeRange = 10...26
    static let contentRange = 11...28

    let uiSize: CGFloat
    let codeSize: CGFloat
    let contentSize: CGFloat

    init(ui: Int = defaultUISize, code: Int = defaultCodeSize, content: Int = defaultContentSize) {
        uiSize = CGFloat(min(max(ui, Self.uiRange.lowerBound), Self.uiRange.upperBound))
        codeSize = CGFloat(min(max(code, Self.codeRange.lowerBound), Self.codeRange.upperBound))
        contentSize = CGFloat(min(max(content, Self.contentRange.lowerBound), Self.contentRange.upperBound))
    }

    enum UIStyle {
        case largeTitle, title2, title3, headline, body, callout, caption, caption2

        var baseSize: CGFloat {
            switch self {
            case .largeTitle: 26
            case .title2: 17
            case .title3: 15
            case .headline, .body: 13
            case .callout: 12
            case .caption: 10
            case .caption2: 9
            }
        }
    }

    func uiFont(_ style: UIStyle, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        .system(
            size: uiSize + style.baseSize - CGFloat(Self.defaultUISize),
            weight: weight ?? (style == .headline ? .semibold : .regular),
            design: design
        )
    }
}

private struct DesktopTypographyKey: EnvironmentKey {
    static let defaultValue = DesktopTypography()
}

extension EnvironmentValues {
    var desktopTypography: DesktopTypography {
        get { self[DesktopTypographyKey.self] }
        set { self[DesktopTypographyKey.self] = newValue }
    }
}

extension View {
    func desktopUIFont(
        _ style: DesktopTypography.UIStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(DesktopUIFontModifier(style: style, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }

    func desktopCodeFont() -> some View {
        modifier(DesktopCodeFontModifier())
    }
}

private struct DesktopUIFontModifier: ViewModifier {
    @Environment(\.desktopTypography) private var typography

    let style: DesktopTypography.UIStyle
    let weight: Font.Weight?
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = typography.uiFont(style, weight: weight, design: design)
        content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

private struct DesktopCodeFontModifier: ViewModifier {
    @Environment(\.desktopTypography) private var typography

    func body(content: Content) -> some View {
        content.font(.system(size: typography.codeSize, design: .monospaced))
    }
}
