import AidesCore
import AppKit
import Carbon
import Observation

@MainActor
@Observable
final class ComputerAppshotCapture {
    static let shortcut = "⌃⌥⇧A"
    private static let hotKey = EventHotKeyID(signature: 0x41494453, id: 1)

    private(set) var draft: AppshotDraft?
    private(set) var error: String?
    private(set) var isEnabled = false
    private(set) var isCapturing = false
    var includeImages = false

    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var registration: EventHotKeyRef?
    @ObservationIgnored private var task: Task<Void, Never>?

    func changeEnabled(_ enabled: Bool) {
        if !enabled {
            stop()
            return
        }
        guard registration == nil else { return }
        error = nil
        var wanted = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), Self.handleEvent, 1, &wanted,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            error = "Aides couldn't register its app capture shortcut."
            return
        }
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey | shiftKey),
            Self.hotKey, GetApplicationEventTarget(), 0, &registration
        )
        guard hotKeyStatus == noErr else {
            stop()
            error = "The app capture shortcut is unavailable. Check other apps' shortcuts."
            return
        }
        isEnabled = true
    }

    func stop() {
        task?.cancel()
        task = nil
        draft = nil
        error = nil
        isCapturing = false
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        isEnabled = false
    }

    func remove(_ id: UUID) {
        if draft?.id == id { draft = nil }
    }

    private func capture() {
        guard isEnabled, !isCapturing else { return }
        draft = nil
        error = nil
        isCapturing = true
        task = Task { [weak self, includeImages] in
            do {
                let observation = try await ComputerExecutor.captureFrontmost(includeImage: includeImages)
                try Task.checkCancellation()
                self?.draft = AppshotDraft(observation: observation)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = error.localizedDescription
            }
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.isCapturing = false
            self.task = nil
            NSApp.activate()
        }
    }

    private static let handleEvent: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let read = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard read == noErr, identifier.signature == 0x41494453, identifier.id == 1 else {
            return OSStatus(eventNotHandledErr)
        }
        let capture = Unmanaged<ComputerAppshotCapture>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in capture.capture() }
        return noErr
    }
}

struct AppshotDraft: Identifiable {
    let id = UUID()
    let observation: ComputerObservation
}
