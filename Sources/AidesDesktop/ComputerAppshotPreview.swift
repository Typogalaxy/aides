import AppKit
import SwiftUI

struct ComputerAppshotPreview: View {
    let appshot: AppshotDraft

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            PageHeading("Review current window")
            LabeledContent("App", value: appshot.observation.appID)
            LabeledContent("Window", value: appshot.observation.windowTitle.isEmpty ? "Untitled" : appshot.observation.windowTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let data = appshot.observation.screenshot, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 250)
                            .accessibilityLabel("Window screenshot")
                    }
                    if let notice = appshot.observation.notice {
                        Text(notice).desktopUIFont(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appshot.observation.elements) { element in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(element.label.isEmpty ? element.role : element.label)
                                .desktopUIFont(.caption, weight: .semibold)
                            if let value = element.value, !value.isEmpty {
                                Text(value).desktopUIFont(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(minWidth: 490, minHeight: 470)
    }
}
