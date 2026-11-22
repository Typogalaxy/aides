import AidesCore
import Foundation
import Vapor

struct ToolkitFeed: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let url: String
    let kind: ToolkitSourceKind
    let intervalMinutes: Int
    var paused: Bool
    var nextCheckAt: Date
    var lastCheckedAt: Date?
    var lastError: String?
    var entries: [ToolkitSourceEntry]
    var seenIDs: Set<String>
    var hasBaseline = false

    init(name: String, url: URL, kind: ToolkitSourceKind, intervalMinutes: Int, paused: Bool) {
        id = UUID()
        self.name = name
        self.url = url.absoluteString
        self.kind = kind
        self.intervalMinutes = intervalMinutes
        self.paused = paused
        nextCheckAt = .now
        entries = []
        seenIDs = []
    }

    func observation(_ data: Data) throws -> [ToolkitSourceEntry] {
        switch kind {
        case .page:
            return [ToolkitSourceEntry(id: ToolkitFeedDocument.fingerprint(data), title: name, url: url)]
        case .feed:
            guard let entries = ToolkitFeedDocument.entries(data) else { throw ToolkitFeedError.invalidFeed }
            return entries
        }
    }

    mutating func accept(_ observation: [ToolkitSourceEntry]) -> Int {
        let uninitialized = !hasBaseline
        if kind == .page {
            let changed = !uninitialized && entries.first?.id != observation.first?.id
            entries = observation
            seenIDs = Set(observation.map(\.id))
            return changed ? 1 : 0
        }

        let combined = seenIDs.union(observation.map(\.id))
        guard combined.count <= 20_000 else {
            paused = true
            lastError = "This feed reached its stored entry limit. Recreate the subscription to start a fresh baseline."
            return 0
        }
        let newEntries = uninitialized ? 0 : combined.count - seenIDs.count
        seenIDs = combined
        entries = Array(observation.prefix(50))
        return newEntries
    }
}

struct ToolkitFeedSummary: Encodable, Sendable {
    let id: UUID
    let name: String
    let url: String
    let kind: ToolkitSourceKind
    let intervalMinutes: Int
    let paused: Bool
    let nextCheckAt: Date
    let lastCheckedAt: Date?
    let lastError: String?
    let entries: [ToolkitSourceEntry]

    init(_ feed: ToolkitFeed) {
        id = feed.id
        name = feed.name
        url = feed.url
        kind = feed.kind
        intervalMinutes = feed.intervalMinutes
        paused = feed.paused
        nextCheckAt = feed.nextCheckAt
        lastCheckedAt = feed.lastCheckedAt
        lastError = feed.lastError
        entries = feed.entries
    }
}

struct ToolkitFeedList: Encodable, Sendable {
    let sources: [ToolkitFeedSummary]

    init(_ feeds: [ToolkitFeed]?) {
        sources = (feeds ?? []).map(ToolkitFeedSummary.init)
    }
}

struct NewToolkitFeed: Decodable, Sendable {
    let name: String
    let url: String
    let kind: ToolkitSourceKind
    let intervalMinutes: Int
    let paused: Bool?
}

private struct ToolkitFeedPause: Decodable, Sendable {
    let paused: Bool
}

actor ToolkitFeedMonitor {
    private let store: StateStore<ServerState>

    init(store: StateStore<ServerState>) {
        self.store = store
    }

    func start() async {
        while !Task.isCancelled {
            if let source = await store.snapshot().toolkitFeeds?.filter({ !$0.paused && $0.nextCheckAt <= .now })
                .min(by: { $0.nextCheckAt < $1.nextCheckAt }) {
                await check(source)
            }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }

    private func check(_ source: ToolkitFeed) async {
        let outcome: Result<[ToolkitSourceEntry], ToolkitFeedError>
        do {
            let data = try await ToolkitFeedTransport.fetch(source.url, kind: source.kind)
            try Task.checkCancellation()
            outcome = .success(try source.observation(data))
        } catch is CancellationError {
            return
        } catch {
            outcome = .failure(error as? ToolkitFeedError ?? .unavailable)
        }

        try? await store.update { state in
            guard let index = state.toolkitFeeds?.firstIndex(where: {
                $0.id == source.id && !$0.paused && $0.nextCheckAt == source.nextCheckAt
            }), var updated = state.toolkitFeeds?[index] else { return }
            let now = Date.now
            updated.lastCheckedAt = now
            updated.nextCheckAt = now.addingTimeInterval(Double(updated.intervalMinutes * 60))
            switch outcome {
            case .success(let entries):
                updated.lastError = nil
                let count = updated.accept(entries)
                updated.hasBaseline = true
                if count > 0, let thread = state.app.threads.firstIndex(where: { $0.role == .secretary }) {
                    // External page and entry text stay in Toolkit data.
                    let notice = source.kind == .page
                        ? "A monitored web page changed. Open Toolkit to view the source."
                        : "A monitored feed has new entries. Open Toolkit to view them."
                    state.app.threads[thread].messages.append(Message(notice, role: .system, notificationKind: .sourceUpdate))
                }
            case .failure(let error):
                updated.lastError = error.rawValue
            }
            state.toolkitFeeds?[index] = updated
            state.revise()
        }
    }
}

extension AidesService {
    func toolkitFeeds(deviceID: UUID) async throws -> ToolkitFeedList {
        let state = await store.snapshot()
        try Self.requireFeedDevice(deviceID, in: state)
        return ToolkitFeedList(state.toolkitFeeds)
    }

    func addToolkitFeed(_ input: NewToolkitFeed, deviceID: UUID) async throws -> ToolkitFeedList {
        let name = try Self.required(input.name, max: 100)
        guard (5...1_440).contains(input.intervalMinutes), let url = ToolkitSourceAddress.httpsURL(input.url) else {
            throw Abort(.badRequest, reason: "Use a public HTTPS source and a polling interval of 5 to 1440 minutes.")
        }
        return try await store.update { state in
            try Self.requireFeedDevice(deviceID, in: state)
            var feeds = state.toolkitFeeds ?? []
            guard feeds.count < 10 else { throw Abort(.conflict, reason: "Remove an existing source before adding another.") }
            guard !feeds.contains(where: { $0.url == url.absoluteString && $0.kind == input.kind }) else {
                throw Abort(.conflict, reason: "This source is already monitored.")
            }
            feeds.append(ToolkitFeed(
                name: name, url: url, kind: input.kind, intervalMinutes: input.intervalMinutes,
                paused: input.paused ?? false
            ))
            state.toolkitFeeds = feeds
            state.revise()
            return ToolkitFeedList(feeds)
        }
    }

    func pauseToolkitFeed(_ id: UUID, paused: Bool, deviceID: UUID) async throws -> ToolkitFeedList {
        try await store.update { state in
            try Self.requireFeedDevice(deviceID, in: state)
            guard let index = state.toolkitFeeds?.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            if state.toolkitFeeds?[index].paused != paused {
                state.toolkitFeeds?[index].paused = paused
                if !paused { state.toolkitFeeds?[index].nextCheckAt = .now }
                state.revise()
            }
            return ToolkitFeedList(state.toolkitFeeds)
        }
    }

    func removeToolkitFeed(_ id: UUID, deviceID: UUID) async throws -> ToolkitFeedList {
        try await store.update { state in
            try Self.requireFeedDevice(deviceID, in: state)
            guard let index = state.toolkitFeeds?.firstIndex(where: { $0.id == id }) else { throw Abort(.notFound) }
            state.toolkitFeeds?.remove(at: index)
            state.revise()
            return ToolkitFeedList(state.toolkitFeeds)
        }
    }

    private static func requireFeedDevice(_ deviceID: UUID, in state: ServerState) throws {
        guard state.app.devices.contains(where: { $0.id == deviceID }) else {
            throw Abort(.unauthorized, reason: "Pair this device to continue.")
        }
    }
}

func registerToolkitFeedRoutes(_ group: RoutesBuilder, service: AidesService) {
    let sources = group.grouped("sources")
    sources.get { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.toolkitFeeds(deviceID: deviceID))
    }
    sources.post { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.addToolkitFeed(decode(NewToolkitFeed.self, request), deviceID: deviceID))
    }
    sources.post(":id", "pause") { request in
        let deviceID = try await service.authenticatedDevice(request)
        let input = try decode(ToolkitFeedPause.self, request)
        return try await json(service.pauseToolkitFeed(toolkitFeedID(request), paused: input.paused, deviceID: deviceID))
    }
    sources.delete(":id") { request in
        let deviceID = try await service.authenticatedDevice(request)
        return try await json(service.removeToolkitFeed(toolkitFeedID(request), deviceID: deviceID))
    }
}

private func toolkitFeedID(_ request: Request) throws -> UUID {
    guard let raw = request.parameters.get("id"), let id = UUID(uuidString: raw) else {
        throw Abort(.badRequest, reason: "Invalid source identifier.")
    }
    return id
}
