import AidesCore
import SwiftUI

struct ToolkitMailAccountPicker: View {
    let workspace: Workspace
    @Binding var selection: String?
    let label: String

    @ViewState private var accounts: [ToolkitMailAccount] = []
    @ViewState private var isOpen = false
    @ViewState private var loading = false
    @ViewState private var error: String?

    private var selectedAccount: ToolkitMailAccount? {
        accounts.first { $0.id == selection }
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            Label(selectedAccount?.label ?? label, systemImage: "envelope")
                .lineLimit(1)
        }
        .help("Authorize one local draft proposal from a selected account.")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Draft mail from").font(.headline)
                Text("Review the prepared draft in Toolkit before sending.")
                    .font(.caption).foregroundStyle(.secondary)
                if loading {
                    ProgressView().controlSize(.small)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    Button("Retry") { Task { await load() } }
                } else if accounts.isEmpty {
                    Text("No account is available for sending.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounts) { account in
                                Button {
                                    selection = account.id
                                    isOpen = false
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(account.label)
                                            Text(verbatim: account.address)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if selection == account.id { Image(systemName: "checkmark") }
                                    }
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                }
                if selection != nil {
                    Button("Clear account") {
                        selection = nil
                        isOpen = false
                    }
                }
            }
            .padding(14)
            .frame(width: 270)
            .task { await load() }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let list: [ToolkitMailAccount] = try await workspace.toolkitGet(["mail", "accounts"])
            try Task.checkCancellation()
            accounts = list.filter { $0.available && $0.allowSend }
            if let selection, !accounts.contains(where: { $0.id == selection }) { self.selection = nil }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ToolkitMailSuggestionView: View {
    let workspace: Workspace
    let requestID: UUID
    let suggestion: ToolkitMailDraftSuggestion
    let unavailable: Bool

    @ViewState private var prepared: ToolkitMailDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Mail draft proposal", systemImage: "envelope")
                .font(.callout.weight(.medium))
            LabeledContent("Account", value: prepared?.accountAddress ?? suggestion.accountID)
            LabeledContent("To", value: suggestion.to.joined(separator: ", "))
            LabeledContent("Subject", value: suggestion.subject)
            DisclosureGroup("Message") {
                ScrollView {
                    Text(verbatim: suggestion.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            if let prepared {
                Text(status(prepared)).foregroundStyle(.secondary)
            } else if !unavailable {
                Button("Prepare for mail review") {
                    Task { prepared = await workspace.prepareToolkitMail(suggestedBy: requestID) }
                }
                .disabled(workspace.isWorking)
            } else {
                Text("This proposal is unavailable.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
    }

    private func status(_ draft: ToolkitMailDraft) -> String {
        switch draft.status {
        case .awaitingConfirmation: "Prepared. Review and send from Settings → Toolkit → Mail."
        case .sending: "Sending. Check the receipt in Toolkit → Mail."
        case .submitted: "Submitted to the provider."
        case .declined: "Declined in Toolkit → Mail."
        case .interrupted: "Outcome unknown. Check the provider’s Sent folder."
        }
    }
}
