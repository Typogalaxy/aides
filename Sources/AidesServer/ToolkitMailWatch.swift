import AidesCore
import Foundation
import Vapor

struct ToolkitMailWatch: Codable, Identifiable, Sendable {
    let id: UUID
    let account: ToolkitMailAccount
    let deviceID: UUID
    let query: String
    let intervalMinutes: Int
    let createdAt: Date
    var paused: Bool
    var nextCheckAt: Date
    var lastCheckedAt: Date?
    var lastError: String?
    var matchingCount: Int
    var seenIDs: Set<String>
    var hasBaseline: Bool

    init(account: ToolkitMailAccount, deviceID: UUID, query: String, intervalMinutes: Int, paused: Bool) {
        let now = Date.now
        id = UUID()
        self.account = account
        self.deviceID = deviceID
        self.query = query
        self.intervalMinutes = intervalMinutes
        createdAt = now
        nextCheckAt = now
        self.paused = paused
        matchingCount = 0
        seenIDs = []
        hasBaseline = false
    }

    var status: ToolkitMailWatchStatus {
        ToolkitMailWatchStatus(
            id: id, accountID: account.id, accountLabel: account.label, query: query, intervalMinutes: intervalMinutes,
            paused: paused, nextCheckAt: nextCheckAt, lastCheckedAt: lastCheckedAt, lastError: lastError,
            matchingCount: matchingCount
        )
    }

    mutating func accept(_ messages: [ToolkitMailMessage]) -> Int {
        matchingCount = messages.count
        var fresh = Set<String>()
        for message in messages where (message.receivedAt ?? .distantPast) >= createdAt {
            fresh.insert(ToolkitFeedDocument.fingerprint(Data(message.id.utf8)))
        }
        let observed = seenIDs.union(fresh)
        guard observed.count <= 20_000 else {
            paused = true
            lastError = "This watch reached its stored match limit. Recreate the watch to start a fresh baseline."
            return 0
        }
        let newMatches = hasBaseline ? observed.count - seenIDs.count : 0
        hasBaseline = true
        seenIDs = observed
        return newMatches
    }
}

private struct ToolkitMailWatchPause: Decodable, Sendable {
    let paused: Bool
}

extension AidesService {
    func toolkitMailWatches(deviceID: UUID) async throws -> ToolkitMailWatchList {
        let state = await store.snapshot()
        try Self.requireWatchDevice(deviceID, in: state)
        return Self.mailWatchList(state)
    }

    func addToolkitMailWatch(_ input: ToolkitMailWatchRequest, deviceID: UUID) async throws -> ToolkitMailWatchList {
        let query = try Self.required(input.query, max: 256)
        guard (5...1_440).contains(input.intervalMinutes), query.utf8.count <= 256,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Abort(.badRequest, reason: "Use a mail search up to 256 bytes and check it every 5 to 1440 minutes.")
        }
        guard let account = try await toolkitMailAccounts(deviceID: deviceID).first(where: { $0.id == input.accountID }) else {
            throw Abort(.notFound, reason: "Mail account not found.")
        }
        guard account.available else {
            throw Abort(.conflict, reason: "Configure this mail account's credential before watching it.")
        }
        return try await store.update { state in
            try Self.requireWatchDevice(deviceID, in: state)
            var watches = state.toolkitMailWatches ?? []
            guard watches.count < 12 else { throw Abort(.conflict, reason: "Remove an existing mail watch first.") }
            guard !watches.contains(where: { $0.account.id == account.id && $0.query == query }) else {
                throw Abort(.conflict, reason: "A watch already uses this account and query.")
            }
            watches.append(ToolkitMailWatch(
                account: account, deviceID: deviceID, query: query, intervalMinutes: input.intervalMinutes,
                paused: input.paused ?? false
            ))
            state.toolkitMailWatches = watches
            state.revise()
            return Self.mailWatchList(state)
        }
    }

    func pauseToolkitMailWatch(_ id: UUID, paused: Bool, deviceID: UUID) async throws -> ToolkitMailWatchList {
        try await store.update { state in
            try Self.requireWatchDevice(deviceID, in: state)
            guard let index = state.toolkitMailWatches?.firstIndex(where: { $0.id == id }),
                  var watch = state.toolkitMailWatches?[index] else { throw Abort(.notFound) }
            if !paused { try Self.requireWatchDevice(watch.deviceID, in: state) }
            if watch.paused != paused {
                watch.paused = paused
                if !paused { watch.nextCheckAt = .now }
                state.toolkitMailWatches?[index] = watch
                state.revise()
            }
            return Self.mailWatchList(state)
        }
    }

    func removeToolkitMailWatch(_ id: UUID, deviceID: UUID) async throws -> ToolkitMailWatchList {
        try await store.update { state in
            try Self.requireWatchDevice(deviceID, in: state)
            guard let index = state.toolkitMailWatches?.firstIndex(where: { $0.id == id }) else {
                throw Abort(.notFound)
            }
            state.toolkitMailWatches?.remove(at: index)
            state.revise()
            return Self.mailWatchList(state)
        }
    }

    func runToolkitMailWatches() async {
        while !Task.isCancelled {
            let snapshot = await store.snapshot()
            if let watch = snapshot.toolkitMailWatches?.filter({ !$0.paused && $0.nextCheckAt <= .now })
                .min(by: { $0.nextCheckAt < $1.nextCheckAt }) {
                await pollToolkitMailWatch(watch)
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    private func pollToolkitMailWatch(_ watch: ToolkitMailWatch) async {
        let messages: [ToolkitMailMessage]?
        let failure: Abort?
        do {
            try Task.checkCancellation()
            messages = try await searchToolkitMail(
                accountID: watch.account.id, input: ToolkitMailSearchRequest(query: watch.query, limit: 10),
                deviceID: watch.deviceID, expectedAccount: watch.account
            )
            failure = nil
        } catch {
            messages = nil
            failure = error as? Abort ?? Abort(.badGateway)
        }
        guard !Task.isCancelled else { return }
        try? await store.update { state in
            guard let index = state.toolkitMailWatches?.firstIndex(where: {
                $0.id == watch.id && !$0.paused && $0.nextCheckAt == watch.nextCheckAt
            }), var current = state.toolkitMailWatches?[index] else { return }
            let now = Date.now
            current.lastCheckedAt = now
            current.nextCheckAt = now.addingTimeInterval(Double(current.intervalMinutes * 60))
            if !state.app.devices.contains(where: { $0.id == current.deviceID }) {
                current.paused = true
                current.lastError = "The device that enabled this watch is no longer paired. Recreate the watch from a paired device."
            } else if let messages {
                current.lastError = nil
                if current.accept(messages) > 0,
                   let thread = state.app.threads.firstIndex(where: { $0.role == .secretary }) {
                    let notice = "A mail watch found new matching messages. Open Toolkit to review them."
                    state.app.threads[thread].messages.append(Message(notice, role: .system, notificationKind: .sourceUpdate))
                }
            } else if let failure {
                current.lastError = failure.reason
                current.paused = [.badRequest, .unauthorized, .forbidden, .notFound, .conflict].contains(failure.status)
            }
            state.toolkitMailWatches?[index] = current
            state.revise()
        }
    }

    private static func mailWatchList(_ state: ServerState) -> ToolkitMailWatchList {
        ToolkitMailWatchList(watches: (state.toolkitMailWatches ?? []).map(\.status))
    }

    private static func requireWatchDevice(_ deviceID: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
    }
}

func registerToolkitMailWatchRoutes(_ group: RoutesBuilder, service: AidesService) {
    let watches = group.grouped("mail", "watches")
    watches.get { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.toolkitMailWatches(deviceID: deviceID))
    }
    watches.post { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.addToolkitMailWatch(decode(ToolkitMailWatchRequest.self, request), deviceID: deviceID))
    }
    watches.post(":id", "pause") { request in
        let deviceID = try await service.authenticatedDevice(request)
        let input = try decode(ToolkitMailWatchPause.self, request)
        return try await json(service.pauseToolkitMailWatch(mailWatchID(request), paused: input.paused, deviceID: deviceID))
    }
    watches.delete(":id") { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.removeToolkitMailWatch(mailWatchID(request), deviceID: deviceID))
    }
}

private func mailWatchID(_ request: Request) throws -> UUID {
    guard let raw = request.parameters.get("id"), let id = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "Invalid mail watch identifier.")
    }
    return id
}
