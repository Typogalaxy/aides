import AppKit
import SwiftUI

struct ComputerAppshotPreview: View {
    let appshot: AppshotDraft

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ComputerReviewSheet(title: "Review current window") {
            ComputerDetailRow("App", value: appshot.observation.appID)
            ComputerDetailRow("Window", value: appshot.observation.windowTitle.isEmpty ? "Untitled" : appshot.observation.windowTitle)
            if let data = appshot.observation.screenshot, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 250, alignment: .leading)
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
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
