import AidesCore
import Foundation
import Testing

private let editor = "com.apple.TextEdit"
private let calculator = "com.apple.calculator"

@Test func routineDesktopGrantIsNarrowerThanTheApplicationGrant() {
    let window = ComputerObservation(appID: editor, windowTitle: "Scratch", elements: [
        ComputerElement(id: "document", role: "AXTextArea", label: "Document"),
        ComputerElement(id: "send", role: "AXButton", label: "Send")
    ])
    let typing = ComputerAction(kind: .typeText, appID: editor, elementID: "document", text: "Example")
    let click = ComputerAction(kind: .click, appID: editor, elementID: "send")
    #expect(typing.isValid(allowedAppIDs: [editor], observation: window))
    #expect(typing.needsReview(observation: window, allowRoutineActions: false))
    #expect(!typing.needsReview(observation: window, allowRoutineActions: true))
    #expect(click.needsReview(observation: window, allowRoutineActions: true))

    let wrongApp = ComputerAction(kind: .typeText, appID: calculator, elementID: "document", text: "Example")
    #expect(!wrongApp.isValid(allowedAppIDs: [editor, calculator], observation: window))
    #expect(!ComputerApp.isEligible("com.apple.Passwords"))
    #expect(!ComputerApp.isEligible("com.apple.loginwindow"))
}

@Test func scopedWindowEvidenceCannotExceedTheAppAndImageGrant() {
    let elements = [ComputerElement(id: "field", role: "AXTextField", label: "Scratch")]
    let image = Data([0xff, 0xd8, 0xff, 0xd9])
    let snapshot = ComputerObservation(appID: editor, windowTitle: "Scratch", elements: elements, screenshot: image)
    #expect(snapshot.isValid(allowImages: true, expectedAppID: editor))
    #expect(!snapshot.isValid(allowImages: false, expectedAppID: editor))
    #expect(!snapshot.isValid(allowImages: true, expectedAppID: calculator))
    let duplicate = ComputerObservation(appID: editor, windowTitle: "Scratch", elements: elements + elements)
    #expect(!duplicate.isValid(allowImages: false, expectedAppID: editor))

    let drag = ComputerAction(kind: .drag, appID: editor, x: 0.5, y: 0.5, endX: 0.5, endY: 0.7)
    #expect(drag.isValid(allowedAppIDs: [editor], observation: snapshot))
    #expect(!drag.supportsBackground)
    let escaped = ComputerAction(kind: .drag, appID: editor, x: 0.5, y: 0.5, endX: 1.001, endY: 0.7)
    #expect(!escaped.isValid(allowedAppIDs: [editor], observation: snapshot))
}
