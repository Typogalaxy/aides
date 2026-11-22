import AidesCore
import Foundation
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class ToolkitDesktopNotifications {
    private static let preferenceKey = "aides.toolkit.desktopNotifications"
    private static let maximumSeen = 256

    private(set) var isEnabled = UserDefaults.standard.bool(forKey: preferenceKey)
    private(set) var isChanging = false
    private(set) var error: String?

    @ObservationIgnored private var recentIDs: [UUID] = []
    @ObservationIgnored private var seenIDs: Set<UUID> = []
    @ObservationIgnored private var delivery: Task<Void, Never>?
    @ObservationIgnored private var queuedNotices: [NotificationKind: UUID] = [:]

    var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func change(enabled: Bool) async {
        guard isAvailable, !isChanging else { return }
        isChanging = true
        error = nil
        defer { isChanging = false }
        do {
            if enabled {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) else {
                    error = "Allow Aides notifications in System Settings to enable desktop notices."
                    return
                }
            } else {
                stop()
            }
            isEnabled = enabled
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        delivery?.cancel()
        delivery = nil
        queuedNotices.removeAll()
        recentIDs.removeAll()
        seenIDs.removeAll()
    }

    func receive(_ next: AppState, after previous: AppState) {
        guard isEnabled, isAvailable, next.revision > previous.revision else { return }
        let oldThreads = Dictionary(uniqueKeysWithValues: previous.threads.map { ($0.id, $0) })
        var groups: [NotificationKind: UUID] = [:]
        for thread in next.threads {
            let oldMessages = oldThreads[thread.id]?.messages ?? []
            guard thread.messages.count > oldMessages.count else { continue }
            let previousNotices = Set(oldMessages.lazy.filter { $0.notificationKind != nil }.map(\.id))
            for message in thread.messages {
                guard let kind = message.notificationKind, !previousNotices.contains(message.id),
                      seenIDs.insert(message.id).inserted else { continue }
                recentIDs.append(message.id)
                groups[kind] = message.id
            }
        }
        if recentIDs.count > Self.maximumSeen {
            let excess = recentIDs.count - Self.maximumSeen
            seenIDs.subtract(recentIDs.prefix(excess))
            recentIDs.removeFirst(excess)
        }
        guard !groups.isEmpty else { return }
        queuedNotices.merge(groups) { _, latest in latest }
        guard delivery == nil else { return }
        delivery = Task {
            while isEnabled, !Task.isCancelled, let (kind, messageID) = queuedNotices.first {
                queuedNotices.removeValue(forKey: kind)
                let content = UNMutableNotificationContent()
                content.title = "Aides"
                content.body = switch kind {
                case .reminder: "A reminder is ready in Aides."
                case .sourceUpdate: "A monitored source has an update in Aides."
                }
                let request = UNNotificationRequest(identifier: "aides.\(messageID.uuidString)", content: content, trigger: nil)
                do {
                    try await UNUserNotificationCenter.current().add(request)
                } catch {
                    if !Task.isCancelled {
                        self.error = "A desktop notice could not be delivered. Check the macOS notification settings."
                    }
                }
            }
            if !Task.isCancelled { delivery = nil }
        }
    }
}

struct ToolkitNotificationsView: View {
    let notifications: ToolkitDesktopNotifications

    var body: some View {
        Form {
            Section("Notifications on this Mac") {
                Toggle("Show macOS notifications", isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { enabled in Task { await notifications.change(enabled: enabled) } }
                ))
                .disabled(!notifications.isAvailable || notifications.isChanging)
                Text("Receive notices for new reminders and monitored source updates while Aides is running. The notice only identifies the type of update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !notifications.isAvailable {
                    Text("Open the packaged Aides app to configure desktop notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = notifications.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
