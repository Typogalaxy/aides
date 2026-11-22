import AidesCore
import Foundation
import Testing

@Test func storeRestoresTheOriginalConversationAndRevision() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try StateStore(directory: directory, defaultState: AppState())
    let id = await first.snapshot().threads[0].id
    try await first.update { state in
        state.threads[0].messages.append(Message("Preserve this", role: .user))
        state.revision = 1
    }
    let restored = try StateStore(directory: directory, defaultState: AppState())
    let restoredState = await restored.snapshot()
    #expect(restoredState.revision == 1)
    #expect(restoredState.threads[0].id == id)
    #expect(restoredState.threads[0].messages[0].text == "Preserve this")
}

@Test func contextIncludesUsefulHistoryAndExcludesOtherProjectMemories() {
    let projectID = UUID()
    var conversation = Conversation(title: "Engine", role: .project, projectID: projectID)
    let decision = Message("The task scheduler uses Melbourne time", role: .user)
    conversation.messages = [decision] + (1...14).map { Message("Filler \($0)", role: .user) }
    conversation.messages.append(Message("What was the scheduler decision?", role: .user))
    let records = [
        MemoryRecord(key: "scheduler", value: "Prefer calendar time", scope: "project:\(projectID.uuidString.lowercased())", source: "sample"),
        MemoryRecord(key: "scheduler", value: "PRIVATE_OTHER_PROJECT", scope: "project:\(UUID().uuidString.lowercased())", source: "sample")
    ]
    let excerpt = ContextBuilder.build(for: conversation, through: conversation.messages.last?.id,
                                       question: conversation.messages.last!.text, records: records, preference: "Use Chinese")
    #expect(excerpt.notes.contains(decision.id.uuidString))
    #expect(excerpt.notes.contains("Prefer calendar time"))
    #expect(!excerpt.notes.contains("PRIVATE_OTHER_PROJECT"))
    #expect(excerpt.recentMessages.last?.text == "What was the scheduler decision?")
}

@Test func retrievesChineseFactsWithDifferentWording() {
    let conversation = Conversation(title: "秘书", role: .secretary)
    let records = [
        MemoryRecord(key: "服务器配置", value: "机器是 Mac Studio M5 Max", source: "用户确认"),
        MemoryRecord(key: "健身习惯", value: "每周两次", source: "用户确认")
    ]
    let context = ContextBuilder.build(
        for: conversation, through: nil, question: "我现在的服务器是哪台？", records: records, preference: ""
    )
    #expect(context.notes.contains("Mac Studio M5 Max"))
    #expect(!context.notes.contains("每周两次"))
}
