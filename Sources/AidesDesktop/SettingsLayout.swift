import SwiftUI

struct SettingsField<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control

    init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .desktopUIFont(.callout, weight: .medium)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            control()
                .accessibilityLabel(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsDetail: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .desktopUIFont(.callout, weight: .medium)
            Text(value)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

struct SettingsActions<Actions: View>: View {
    var alignment: HorizontalAlignment = .leading
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8, content: actions)
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: alignment, spacing: 8, content: actions)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

struct SettingsFormSheet<Fields: View, Actions: View>: View {
    let title: String
    var idealWidth: CGFloat = 510
    @ViewBuilder var fields: () -> Fields
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeading(title)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fields()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
            Divider()
            SettingsActions(alignment: .trailing, actions: actions)
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
        }
        .frame(minWidth: 310, idealWidth: idealWidth, maxWidth: idealWidth, minHeight: 250, idealHeight: 410, maxHeight: 560)
    }
}
