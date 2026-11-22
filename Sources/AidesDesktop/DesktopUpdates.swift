import AidesCore
import AppKit
import Foundation
import Observation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
@Observable
final class DesktopUpdates {
    private(set) var manualMessage: String?
    private var githubUpdate: GitHubReleaseUpdate.Available?
    private var sparkleHasUpdate = false
    @ObservationIgnored private var scheduledCheck: Task<Void, Never>?
    @ObservationIgnored private var checkingGitHub = false

    var hasUpdate: Bool { sparkleHasUpdate || githubUpdate != nil }

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private static let endpoint = URL(string: "https://api.github.com/repos/Typogalaxy/aides/releases/latest")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#else
        "x86_64"
#endif
    }

#if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let presentation = UpdatePresentation()
#endif

    var isAvailable: Bool {
        usesSparkle || GitHubReleaseUpdate.supports(installedVersion: installedVersion)
    }

    private var usesSparkle: Bool {
#if canImport(Sparkle)
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
#else
        false
#endif
    }

    func start() {
        guard isAvailable else { return }
#if canImport(Sparkle)
        if usesSparkle {
            guard controller == nil else { return }
            presentation.setAvailability = { [weak self] available in self?.sparkleHasUpdate = available }
            controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: presentation
            )
            return
        }
#endif
        guard scheduledCheck == nil else { return }
        scheduledCheck = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                await self?.refreshGitHubRelease(showStatus: false)
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func check() {
#if canImport(Sparkle)
        if usesSparkle {
            controller?.checkForUpdates(nil)
            return
        }
#endif
        Task { await refreshGitHubRelease(showStatus: true) }
    }

    func openUpdate() {
        if let githubUpdate {
            NSWorkspace.shared.open(githubUpdate.releaseURL)
        } else {
            check()
        }
    }

    func dismissManualMessage() { manualMessage = nil }

    private func refreshGitHubRelease(showStatus: Bool) async {
        guard !checkingGitHub else {
            if showStatus { manualMessage = "An update check is already in progress." }
            return
        }
        checkingGitHub = true
        defer { checkingGitHub = false }
        do {
            var request = URLRequest(url: Self.endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Aides", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await Self.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let latest = try JSONDecoder().decode(GitHubReleaseUpdate.self, from: data)
            githubUpdate = latest.update(after: installedVersion, architecture: Self.architecture)
            if showStatus {
                if let githubUpdate {
                    manualMessage = "Aides \(githubUpdate.version) is available to download."
                } else {
                    manualMessage = "There is no newer macOS installer available for this Mac."
                }
            }
        } catch {
            if showStatus { manualMessage = "Could not check GitHub for updates. Try again later." }
        }
    }

}

#if canImport(Sparkle)
@MainActor
private final class UpdatePresentation: NSObject, SPUStandardUserDriverDelegate {
    var setAvailability: ((Bool) -> Void)?

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        Task { @MainActor in setAvailability?(true) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in setAvailability?(false) }
    }
}
#endif
