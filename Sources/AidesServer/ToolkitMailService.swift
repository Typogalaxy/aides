import AidesCore
import AidesExecution
import Foundation
import Vapor

private struct MailAccountConfiguration: Decodable, Sendable {
    let id: String
    let provider: ToolkitMailProvider
    let label: String
    let address: String
    let credentialEnvironment: String?
    let credentialFile: String?
    let allowSend: Bool?
    let allowArchive: Bool?

    var defaultCredentialFile: String { "mail-\(id).token" }

    func account(available: Bool) -> ToolkitMailAccount {
        ToolkitMailAccount(
            id: id, provider: provider, label: label, address: address,
            available: available, allowSend: allowSend == true, allowArchive: allowArchive == true
        )
    }

    func token(in storage: ToolkitHostConfiguration) throws -> String? {
        let file = try storage.read(credentialFile ?? defaultCredentialFile)
        let value = file ?? credentialEnvironment.flatMap { ProcessInfo.processInfo.environment[$0] }
        guard let token = value?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
              token.utf8.count <= 16_384,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return token
    }

    var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && !label.isEmpty && label.utf8.count <= 100 &&
        !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        Self.isMailAddress(address) &&
        (credentialFile == nil || credentialFile == defaultCredentialFile) &&
        (credentialEnvironment.map(Self.isCredentialEnvironment) ?? true)
    }

    private static func isCredentialEnvironment(_ name: String) -> Bool {
        name.hasPrefix("AIDES_MAIL_") && name != "AIDES_MAIL_ACCOUNTS" &&
            name.utf8.count <= 100 && name.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || $0 == 95
            }
    }

    static func isMailAddress(_ value: String) -> Bool {
        guard value.utf8.count <= 254 else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, !local.isEmpty, local.utf8.count <= 64,
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains(".."),
              local.utf8.allSatisfy({ self.isAlphaNumeric($0) || "!#$%&'*+-/=?^_`{|}~.".utf8.contains($0) }),
              let domain = parts.last else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.utf8.allSatisfy { self.isAlphaNumeric($0) || $0 == 45 }
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

enum MailAccessKind {
    case read, send, archive
}

struct MailAccountAccess: Sendable {
    let account: ToolkitMailAccount
    let token: String
}

extension AidesService {
    func toolkitMailAccounts(deviceID: UUID) async throws -> [ToolkitMailAccount] {
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        let storage = mailStorage
        return try mailConfiguration().map { configuration in
            configuration.account(available: (try? configuration.token(in: storage)) != nil)
        }
    }

    func searchToolkitMail(
        accountID: String, input: ToolkitMailSearchRequest, deviceID: UUID, expectedAccount: ToolkitMailAccount? = nil
    ) async throws -> [ToolkitMailMessage] {
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = input.limit ?? 5
        guard !query.isEmpty, query.utf8.count <= 256, (1...10).contains(limit),
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Abort(.badRequest, reason: "Enter a mail search up to 256 bytes and a result limit from 1 through 10.")
        }
        let access = try mailAccess(id: accountID)
        if let expectedAccount {
            guard expectedAccount.id == access.account.id, expectedAccount.provider == access.account.provider,
                  expectedAccount.address.caseInsensitiveCompare(access.account.address) == .orderedSame else {
                throw Abort(.conflict, reason: "This mail account changed. Review its authorization before searching again.")
            }
        }
        let result: [ToolkitMailMessage]
        do {
            result = try await ToolkitMailConnector().search(
                account: access.account, token: access.token, query: query, limit: limit
            )
        } catch {
            throw Self.mailFailure(error)
        }
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        return result
    }

    func readToolkitMail(accountID: String, messageID: String, deviceID: UUID) async throws -> ToolkitMailMessage {
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        let access = try mailAccess(id: accountID)
        let result: ToolkitMailMessage
        do {
            result = try await ToolkitMailConnector().read(
                account: access.account, token: access.token, messageID: messageID
            )
        } catch {
            throw Self.mailFailure(error)
        }
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        return result
    }

    func previewToolkitMailAttachment(
        accountID: String, messageID: String, input: ToolkitMailAttachmentPreviewRequest, deviceID: UUID
    ) async throws -> ToolkitMailAttachmentPreview {
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        guard input.isValid else { throw Abort(.badRequest, reason: "Select an attachment from the opened message.") }
        let access = try mailAccess(id: accountID)
        let result: ToolkitMailAttachmentPreview
        do {
            result = try await ToolkitMailConnector().previewAttachment(
                account: access.account, token: access.token, messageID: messageID, selection: input
            )
        } catch ToolkitMailAttachmentPreviewError.changed {
            throw Abort(.conflict, reason: "The attachment changed. Open the message again.")
        } catch ToolkitMailAttachmentPreviewError.unsupported {
            throw Abort(.unprocessableEntity, reason: "This preview requires a UTF-8 text attachment up to 16 KiB.")
        } catch {
            throw Self.mailFailure(error)
        }
        try Self.requireMailDevice(deviceID, in: await store.snapshot())
        return result
    }

    func toolkitMailDrafts(deviceID: UUID) async throws -> [ToolkitMailDraft] {
        let state = await store.snapshot()
        try Self.requireMailDevice(deviceID, in: state)
        return (state.toolkitMailDrafts ?? [:]).values.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt > $1.createdAt
        }
    }

    func createToolkitMailDraft(_ input: ToolkitMailDraftRequest, deviceID: UUID) async throws -> ToolkitMailDraft {
        try Self.validateMailDraft(input)
        return try await store.update { state in
            try Self.requireMailDevice(deviceID, in: state)
            if let existing = state.toolkitMailDrafts?[input.id] {
                guard existing.request == input, existing.requestedByDeviceID == deviceID else {
                    throw Abort(.conflict, reason: "This mail draft ID has already been used.")
                }
                return existing
            }
            guard state.toolkitMailRetiredDraftIDs?.contains(input.id) != true else {
                throw Abort(.gone, reason: "This mail receipt expired.")
            }
            let account = try mailAccess(id: input.accountID, kind: .send).account
            var drafts = state.toolkitMailDrafts ?? [:]
            let active = drafts.values.filter { $0.status == .awaitingConfirmation || $0.status == .sending }
            guard active.count < 24 else {
                throw Abort(.conflict, reason: "Review the existing drafts before creating another.")
            }
            let draft = ToolkitMailDraft(request: input, account: account, requestedByDeviceID: deviceID, now: .now)
            drafts[input.id] = draft
            state.toolkitMailDrafts = drafts
            return draft
        }
    }

    func decideToolkitMailDraft(_ id: UUID, approved: Bool, deviceID: UUID) async throws -> ToolkitMailDraft {
        let (draft, access): (ToolkitMailDraft, MailAccountAccess?) = try await store.update { state in
            try Self.requireMailDevice(deviceID, in: state)
            guard var draft = state.toolkitMailDrafts?[id] else {
                if state.toolkitMailRetiredDraftIDs?.contains(id) == true { throw Abort(.gone) }
                throw Abort(.notFound, reason: "Mail draft not found.")
            }
            guard draft.status == .awaitingConfirmation else { return (draft, nil) }
            let access: MailAccountAccess?
            if approved {
                try Self.requireMailDevice(draft.requestedByDeviceID, in: state)
                let configured = try mailAccess(id: draft.accountID, kind: .send)
                guard configured.account.provider == draft.accountProvider,
                      configured.account.address == draft.accountAddress else {
                    throw Abort(.conflict, reason: "The sender changed. Create a new mail draft.")
                }
                draft.status = .sending
                access = configured
            } else {
                draft.status = .declined
                access = nil
            }
            draft.updatedAt = .now
            state.toolkitMailDrafts?[id] = draft
            Self.trimToolkitMailReceipts(in: &state, keeping: id)
            return (draft, access)
        }
        guard let access else { return draft }

        // The sending record is durable before the provider request. Any ambiguous outcome ends this attempt.
        let status: ToolkitMailDraftStatus
        let failure: String?
        do {
            try await ToolkitMailConnector().send(draft: draft, account: access.account, token: access.token)
            status = .submitted
            failure = nil
        } catch {
            status = .interrupted
            failure = Self.mailFailure(error).reason
        }
        return try await store.update { state in
            guard var current = state.toolkitMailDrafts?[id], current.status == .sending else {
                throw Abort(.conflict, reason: "The mail record changed. Check the provider’s Sent folder.")
            }
            current.status = status
            current.error = failure
            current.updatedAt = .now
            state.toolkitMailDrafts?[id] = current
            Self.trimToolkitMailReceipts(in: &state, keeping: id)
            return current
        }
    }

    static func interruptToolkitMailDispatches(in state: inout ServerState) {
        let interrupted = state.toolkitMailDrafts?.values.filter { $0.status == .sending } ?? []
        for var draft in interrupted {
            draft.status = .interrupted
            draft.error = "The server stopped before recording delivery. Check the provider’s Sent folder."
            draft.updatedAt = .now
            state.toolkitMailDrafts?[draft.id] = draft
        }
        trimToolkitMailReceipts(in: &state)
    }

    private static func trimToolkitMailReceipts(in state: inout ServerState, keeping id: UUID? = nil) {
        guard var drafts = state.toolkitMailDrafts else { return }
        let old = drafts.values.filter {
            $0.id != id && $0.status != .awaitingConfirmation && $0.status != .sending
        }.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(id == nil ? 32 : 31)
        guard !old.isEmpty else { return }
        var retired = state.toolkitMailRetiredDraftIDs ?? []
        for draft in old {
            retired.insert(draft.id)
            drafts.removeValue(forKey: draft.id)
        }
        state.toolkitMailRetiredDraftIDs = retired
        state.toolkitMailDrafts = drafts
    }

    private var mailStorage: ToolkitHostConfiguration {
        ToolkitHostConfiguration(directory: host.directory)
    }

    private func mailConfiguration() throws -> [MailAccountConfiguration] {
        let file: String?
        do {
            file = try mailStorage.read("mail-accounts.json")
        } catch {
            throw Abort(.serviceUnavailable, reason: "Check the protected mail-accounts.json file on the host.")
        }
        guard let json = file ?? ProcessInfo.processInfo.environment["AIDES_MAIL_ACCOUNTS"], !json.isEmpty else {
            return []
        }
        guard json.utf8.count <= 32_768,
              let accounts = try? JSONDecoder().decode([MailAccountConfiguration].self, from: Data(json.utf8)),
              accounts.count <= 24, accounts.allSatisfy(\.isValid), Set(accounts.map(\.id)).count == accounts.count else {
            throw Abort(.serviceUnavailable, reason: "Check the mail-accounts.json configuration on the host.")
        }
        return accounts
    }

    func mailAccess(id: String, kind: MailAccessKind = .read) throws -> MailAccountAccess {
        guard let configured = try mailConfiguration().first(where: { $0.id == id }) else {
            throw Abort(.notFound, reason: "Mail account not found.")
        }
        if kind == .send && configured.allowSend != true {
            throw Abort(.forbidden, reason: "This mail account is read-only.")
        }
        if kind == .archive && configured.allowArchive != true {
            throw Abort(.forbidden, reason: "Archiving is disabled for this mail account.")
        }
        guard let token = try? configured.token(in: mailStorage) else {
            throw Abort(.serviceUnavailable, reason: "Configure the protected mail account credential on the host.")
        }
        return MailAccountAccess(account: configured.account(available: true), token: token)
    }

    private static func validateMailDraft(_ input: ToolkitMailDraftRequest) throws {
        guard (1...5).contains(input.to.count), input.to.allSatisfy(MailAccountConfiguration.isMailAddress),
              Set(input.to.map { $0.lowercased() }).count == input.to.count,
              !input.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.subject.utf8.count <= 240,
              !input.subject.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.body.utf8.count <= 20_000, !input.body.utf8.contains(0) else {
            throw Abort(.badRequest, reason: "Use one to five distinct email addresses, a short subject, and a plain-text body.")
        }
    }

    static func requireMailDevice(_ deviceID: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
    }

    static func mailFailure(_ error: Error) -> Abort {
        switch error as? ToolkitMailConnectorError {
        case .unauthorized, .wrongAccount:
            Abort(.forbidden, reason: "The provider did not authorize this account. Check its token and permissions.")
        case .rejected:
            Abort(.badRequest, reason: "The provider rejected the mail request.")
        default:
            Abort(.badGateway, reason: "The mail provider could not confirm the result.")
        }
    }
}

func registerToolkitMailRoutes(_ group: RoutesBuilder, service: AidesService) {
    let mail = group.grouped("mail")
    registerToolkitMailArchiveRoutes(mail, service: service)
    mail.get("accounts") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitMailAccounts(deviceID: device))
    }
    mail.post("accounts", ":accountID", "search") { request in
        let device = try await service.authenticatedDevice(request)
        guard let account = request.parameters.get("accountID") else { throw Abort(.badRequest) }
        return try await json(service.searchToolkitMail(
            accountID: account, input: decode(ToolkitMailSearchRequest.self, request), deviceID: device
        ))
    }
    mail.get("accounts", ":accountID", "messages", ":messageID") { request in
        let device = try await service.authenticatedDevice(request)
        guard let account = request.parameters.get("accountID"),
              let message = request.parameters.get("messageID") else { throw Abort(.badRequest) }
        return try await json(service.readToolkitMail(accountID: account, messageID: message, deviceID: device))
    }
    mail.post("accounts", ":accountID", "messages", ":messageID", "attachments", "preview") { request in
        let device = try await service.authenticatedDevice(request)
        guard let account = request.parameters.get("accountID"),
              let message = request.parameters.get("messageID") else { throw Abort(.badRequest) }
        return try await json(service.previewToolkitMailAttachment(
            accountID: account, messageID: message,
            input: decode(ToolkitMailAttachmentPreviewRequest.self, request), deviceID: device
        ))
    }
    mail.get("drafts") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.toolkitMailDrafts(deviceID: device))
    }
    mail.post("drafts") { request in
        let device = try await service.authenticatedDevice(request)
        return try await json(service.createToolkitMailDraft(decode(ToolkitMailDraftRequest.self, request), deviceID: device))
    }
    mail.post("drafts", ":id", "decision") { request in
        let device = try await service.authenticatedDevice(request)
        guard let parameter = request.parameters.get("id"), let id = UUID(uuidString: parameter) else {
            throw Abort(.badRequest)
        }
        let decision = try decode(ToolkitMailDecision.self, request)
        return try await json(service.decideToolkitMailDraft(id, approved: decision.approved, deviceID: device))
    }
}
