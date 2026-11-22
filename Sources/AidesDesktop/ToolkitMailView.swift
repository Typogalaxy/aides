import AidesCore
import SwiftUI

struct ToolkitMailView: View {
    let workspace: Workspace

    @ViewState private var accounts: [ToolkitMailAccount] = []
    @ViewState private var drafts: [ToolkitMailDraft] = []
    @ViewState private var archives: [ToolkitMailArchive] = []
    @ViewState private var accountID: String?
    @ViewState private var query = ""
    @ViewState private var messages: [ToolkitMailMessage] = []
    @ViewState private var selectedMessage: ToolkitMailMessage?
    @ViewState private var reviewing: ToolkitMailDraft?
    @ViewState private var reviewingArchive: ToolkitMailArchive?
    @ViewState private var showsComposer = false
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var hasSearched = false

    private var account: ToolkitMailAccount? {
        accounts.first { $0.id == accountID && $0.available }
    }

    var body: some View {
        Form {
            Section("Connected mail accounts") {
                Button("Refresh mail") { Task { await refresh() } }
                    .disabled(busy)
                if accounts.isEmpty {
                    Text("Configure a Gmail, Outlook, or Fastmail account on the Aides server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(accounts) { account in
                    LabeledContent("\(account.label) · \(account.provider.title)") {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(account.address)
                            Text(account.available ? (account.allowSend ? "Read and send" : "Read only") : "Credential unavailable")
                                .desktopUIFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            if accounts.contains(where: \.available) {
                Section("Search mail") {
                    Picker("Account", selection: $accountID) {
                        Text("Choose an account").tag(String?.none)
                        ForEach(accounts.filter(\.available)) { account in
                            Text(account.label).tag(Optional(account.id))
                        }
                    }
                    .disabled(busy)
                    HStack {
                        TextField("Search terms", text: $query)
                            .onSubmit { Task { await search() } }
                        Button("Search") { Task { await search() } }
                            .disabled(busy || account == nil || query.trimmed.isEmpty)
                    }
                    if hasSearched && messages.isEmpty {
                        Text("No messages found.").foregroundStyle(.secondary)
                    }
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Button(message.subject.isEmpty ? "(No subject)" : message.subject) {
                                Task { await read(message) }
                            }
                            .buttonStyle(.link)
                            .disabled(busy)
                            Text(message.from).desktopUIFont(.caption).foregroundStyle(.secondary)
                            if !message.preview.isEmpty {
                                Text(message.preview).lineLimit(2).desktopUIFont(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            ToolkitMailWatchesSection(workspace: workspace, account: account, query: query)
            Section("Drafts and send receipts") {
                if account?.allowSend == true {
                    Button("Create draft…") { showsComposer = true }.disabled(busy)
                }
                if drafts.isEmpty { Text("No recorded drafts.").foregroundStyle(.secondary) }
                ForEach(drafts) { draft in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.subject.isEmpty ? "(No subject)" : draft.subject)
                                .desktopUIFont(.body, weight: .medium)
                            Text("\(draft.accountLabel) · \(draft.to.joined(separator: ", "))")
                                .desktopUIFont(.caption)
                                .foregroundStyle(.secondary)
                            Text(draft.status.title)
                                .desktopUIFont(.caption)
                                .foregroundStyle(draft.status == .interrupted ? .orange : .secondary)
                        }
                        Spacer()
                        Button(draft.status == .awaitingConfirmation ? "Review…" : "Details…") { reviewing = draft }
                    }
                    .padding(.vertical, 3)
                }
            }
            if !archives.isEmpty {
                Section("Archive requests") {
                    ForEach(archives) { archive in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(archive.subject.isEmpty ? "(No subject)" : archive.subject)
                                    .desktopUIFont(.body, weight: .medium)
                                Text("\(archive.accountLabel) · \(archive.from)")
                                    .desktopUIFont(.caption)
                                    .foregroundStyle(.secondary)
                                Text(archive.status.title)
                                    .desktopUIFont(.caption)
                                    .foregroundStyle(archive.status == .interrupted ? .orange : .secondary)
                            }
                            Spacer()
                            Button(archive.status == .awaitingConfirmation ? "Review…" : "Details…") {
                                reviewingArchive = archive
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onChange(of: accountID) { _, _ in
            messages = []
            hasSearched = false
        }
        .sheet(item: $selectedMessage) { message in
            ToolkitMailMessageSheet(workspace: workspace, account: account, message: message, onPrepared: updateArchive)
        }
        .sheet(item: $reviewing) { draft in
            ToolkitMailReviewSheet(workspace: workspace, draft: draft, onUpdated: update)
        }
        .sheet(item: $reviewingArchive) { archive in
            ToolkitMailArchiveReviewSheet(workspace: workspace, archive: archive, onUpdated: updateArchive)
        }
        .sheet(isPresented: $showsComposer) {
            if let account {
                ToolkitMailComposeSheet(workspace: workspace, account: account, onCreated: update)
            }
        }
    }

    private func update(_ draft: ToolkitMailDraft) {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
    }

    private func updateArchive(_ archive: ToolkitMailArchive) {
        if let index = archives.firstIndex(where: { $0.id == archive.id }) {
            archives[index] = archive
        } else {
            archives.insert(archive, at: 0)
        }
    }

    private func refresh() async {
        await perform {
            async let loadedAccounts: [ToolkitMailAccount] = workspace.toolkitGet(["mail", "accounts"])
            async let loadedDrafts: [ToolkitMailDraft] = workspace.toolkitGet(["mail", "drafts"])
            async let loadedArchives: [ToolkitMailArchive] = workspace.toolkitGet(["mail", "archives"])
            (accounts, drafts, archives) = try await (loadedAccounts, loadedDrafts, loadedArchives)
            if account == nil { accountID = accounts.first(where: \.available)?.id }
        }
    }

    private func search() async {
        let value = query.trimmed
        guard let account, !value.isEmpty else { return }
        await perform {
            messages = try await workspace.toolkitPost(
                ["mail", "accounts", account.id, "search"], body: ToolkitMailSearchRequest(query: value, limit: 15)
            )
            hasSearched = true
        }
    }

    private func read(_ message: ToolkitMailMessage) async {
        guard let account else { return }
        await perform {
            selectedMessage = try await workspace.toolkitGet(["mail", "accounts", account.id, "messages", message.id])
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { try await operation() }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }
}

private struct ToolkitMailMessageSheet: View {
    let workspace: Workspace
    let account: ToolkitMailAccount?
    let message: ToolkitMailMessage
    let onPrepared: (ToolkitMailArchive) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var archiveID = UUID()
    @ViewState private var attachmentPreview: ToolkitMailAttachmentPreview?
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeading(message.subject.isEmpty ? "(No subject)" : message.subject)
            LabeledContent("From", value: message.from)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message.body ?? message.preview)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !message.attachments.isEmpty {
                        Divider()
                        Text("Attachments").desktopUIFont(.headline)
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { index, attachment in
                            HStack {
                                LabeledContent(attachment.name, value: attachmentDetails(attachment))
                                    .desktopUIFont(.caption)
                                if let account, let key = attachment.previewKey {
                                    Button("Preview text") { Task { await preview(index: index, key: key, account: account) } }
                                        .accessibilityLabel("Preview text from \(attachment.name)")
                                        .disabled(busy)
                                }
                            }
                        }
                        if let attachmentPreview {
                            Divider()
                            HStack {
                                Text(verbatim: attachmentPreview.name).desktopUIFont(.headline)
                                Spacer()
                                Button("Close text preview") { self.attachmentPreview = nil }
                            }
                            Text(verbatim: attachmentPreview.text)
                                .desktopUIFont(.caption, design: .monospaced)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if let account, account.allowArchive {
                    Button("Prepare archive request") { Task { await prepareArchive(account) } }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .padding(22)
        .frame(width: 560, height: 420)
    }

    private func attachmentDetails(_ attachment: ToolkitMailAttachment) -> String {
        let size = attachment.byteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [attachment.contentType, size, attachment.isInline ? "Inline" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func preview(index: Int, key: String, account: ToolkitMailAccount) async {
        guard !busy else { return }
        busy = true
        error = nil
        attachmentPreview = nil
        defer { busy = false }
        do {
            attachmentPreview = try await workspace.toolkitPost(
                ["mail", "accounts", account.id, "messages", message.id, "attachments", "preview"],
                body: ToolkitMailAttachmentPreviewRequest(index: index, previewKey: key)
            )
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareArchive(_ account: ToolkitMailAccount) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let archive: ToolkitMailArchive = try await workspace.toolkitPost(
                ["mail", "archives"],
                body: ToolkitMailArchiveRequest(id: archiveID, accountID: account.id, messageID: message.id)
            )
            onPrepared(archive)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ToolkitMailArchiveReviewSheet: View {
    let workspace: Workspace
    @ViewState var archive: ToolkitMailArchive
    let onUpdated: (ToolkitMailArchive) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var isWorking = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading("Archive mail")
            LabeledContent("Account", value: archive.accountAddress)
            LabeledContent("Message sender", value: archive.from)
            LabeledContent("Subject", value: archive.subject)
            LabeledContent("Status", value: archive.status.title)
            if let error = error ?? archive.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if archive.status == .awaitingConfirmation && archive.requestedByDeviceID == workspace.deviceID {
                    Button("Decline", role: .destructive) { Task { await decide(approved: false) } }
                    Button("Confirm and archive") { Task { await decide(approved: true) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(isWorking)
        }
        .textSelection(.enabled)
        .padding(22)
        .frame(width: 520)
    }

    private func decide(approved: Bool) async {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let updated: ToolkitMailArchive = try await workspace.toolkitPost(
                ["mail", "archives", archive.id.uuidString, "decision"], body: ToolkitMailDecision(approved: approved)
            )
            archive = updated
            onUpdated(updated)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if let list: [ToolkitMailArchive] = try? await workspace.toolkitGet(["mail", "archives"]),
               let updated = list.first(where: { $0.id == archive.id }) {
                archive = updated
                onUpdated(updated)
            }
        }
    }
}

private extension ToolkitMailArchiveStatus {
    var title: String {
        switch self {
        case .awaitingConfirmation: "Awaiting confirmation"
        case .archiving: "Archiving"
        case .archived: "Archived"
        case .declined: "Declined"
        case .interrupted: "Outcome unknown"
        }
    }
}

private struct ToolkitMailComposeSheet: View {
    let workspace: Workspace
    let account: ToolkitMailAccount
    let onCreated: (ToolkitMailDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var recipients = ""
    @ViewState private var subject = ""
    @ViewState private var message = ""
    @ViewState private var lastRequest: ToolkitMailDraftRequest?
    @ViewState private var busy = false
    @ViewState private var error: String?

    private var addresses: [String] {
        recipients.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeading("Create mail draft")
            Form {
                LabeledContent("From", value: account.address)
                TextField("To (comma-separated addresses)", text: $recipients)
                TextField("Subject", text: $subject)
                TextField("Message", text: $message, axis: .vertical).lineLimit(5...12)
            }
            .disabled(busy)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Save for review") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addresses.isEmpty || subject.trimmed.isEmpty || message.trimmed.isEmpty || busy)
            }
        }
        .padding(22)
        .frame(width: 550)
    }

    private func save() async {
        guard !busy else { return }
        let candidate = ToolkitMailDraftRequest(
            id: lastRequest?.id ?? UUID(), accountID: account.id, to: addresses, subject: subject.trimmed, body: message
        )
        let request = lastRequest == candidate ? candidate : ToolkitMailDraftRequest(
            accountID: candidate.accountID, to: candidate.to, subject: candidate.subject, body: candidate.body
        )
        lastRequest = request
        busy = true
        error = nil
        defer { busy = false }
        do {
            let draft: ToolkitMailDraft = try await workspace.toolkitPost(["mail", "drafts"], body: request)
            onCreated(draft)
            dismiss()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ToolkitMailReviewSheet: View {
    let workspace: Workspace
    @ViewState var draft: ToolkitMailDraft
    let onUpdated: (ToolkitMailDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var busy = false
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            PageHeading("Mail draft")
            LabeledContent("From", value: draft.accountAddress)
            LabeledContent("To", value: draft.to.joined(separator: ", "))
            LabeledContent("Subject", value: draft.subject)
            LabeledContent("Status", value: draft.status.title)
            ScrollView {
                Text(draft.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if draft.status == .interrupted {
                Text("Check the provider’s Sent folder before creating another copy.")
                    .desktopUIFont(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if draft.status == .awaitingConfirmation && draft.requestedByDeviceID == workspace.deviceID {
                    Button("Decline", role: .destructive) { Task { await decide(approved: false) } }
                    Button("Confirm and send") { Task { await decide(approved: true) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .disabled(busy)
        }
        .textSelection(.enabled)
        .padding(22)
        .frame(width: 590, height: 420)
    }

    private func decide(approved: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let updated: ToolkitMailDraft = try await workspace.toolkitPost(
                ["mail", "drafts", draft.id.uuidString, "decision"], body: ToolkitMailDecision(approved: approved)
            )
            draft = updated
            onUpdated(updated)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            if let list: [ToolkitMailDraft] = try? await workspace.toolkitGet(["mail", "drafts"]),
               let updated = list.first(where: { $0.id == draft.id }) {
                draft = updated
                onUpdated(updated)
            }
        }
    }
}

private extension ToolkitMailDraftStatus {
    var title: String {
        switch self {
        case .awaitingConfirmation: "Awaiting confirmation"
        case .sending: "Sending"
        case .submitted: "Submitted to provider"
        case .declined: "Declined"
        case .interrupted: "Outcome unknown"
        }
    }
}
