import Foundation
import Observation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
@Observable
final class DesktopUpdates {
    private(set) var hasUpdate = false

#if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let presentation = UpdatePresentation()
#endif

    var isAvailable: Bool {
#if canImport(Sparkle)
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String
#else
        false
#endif
    }

    func start() {
#if canImport(Sparkle)
        guard isAvailable, controller == nil else { return }
        presentation.setAvailability = { [weak self] available in self?.hasUpdate = available }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: presentation
        )
#endif
    }

    func check() {
#if canImport(Sparkle)
        controller?.checkForUpdates(nil)
#endif
    }
}

#if canImport(Sparkle)
private final class UpdatePresentation: NSObject, SPUStandardUserDriverDelegate {
    @MainActor var setAvailability: ((Bool) -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        Task { @MainActor in setAvailability?(true) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in setAvailability?(false) }
    }
}
#endif
