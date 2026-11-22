import AidesCore
import SwiftUI

struct MailSuggestionView: View {
    let workspace: Workspace
    let messageID: UUID
    let draft: MailSuggestion

    @ViewState private var queued = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Email draft", systemImage: "envelope")
                .font(.headline)
            if let sender = draft.from {
                LabeledContent("From", value: sender)
                    .textSelection(.enabled)
            }
            LabeledContent("To", value: draft.to)
                .textSelection(.enabled)
            LabeledContent("Subject", value: draft.subject)
                .textSelection(.enabled)
            Divider()
            Text(draft.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if queued {
                Label("Queued for submission", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if draft.from != nil {
                Button("Send this email") {
                    Task { queued = await workspace.sendMail(suggestedBy: messageID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(workspace.isWorking)
            } else {
                Text("Configure a sender on the server Mac before submitting this draft.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }
}
