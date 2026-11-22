import AidesCore
import Foundation

struct PairingRequest: Decodable { let code: String; let name: String }
struct PairingResult: Encodable { let token: String; let deviceID: UUID }
struct InviteResult: Encodable { let code: String }
struct HealthResult: Encodable { let status = "ok" }
struct NewThread: Decodable { let title: String; let role: ConversationRole; let projectID: UUID? }
struct NewMessage: Decodable { let text: String }
struct ArchiveThread: Decodable { let report: String }
struct NewProject: Decodable { let name: String; let directory: String? }
struct NewTask: Decodable {
    let title: String
    let instruction: String?
    let threadID: UUID?
    let projectID: UUID?
    let modelID: UUID?
    let scheduledAt: Date?
    let kind: WorkKind?
}
struct NewReview: Decodable {
    let title: String
    let instruction: String
    let modelIDs: [UUID]
    let threadID: UUID?
    let projectID: UUID?
}
struct NewSchedule: Decodable {
    let title: String
    let threadID: UUID?
    let projectID: UUID?
    let modelID: UUID?
    let kind: WorkKind
    let repeatRule: RepeatRule
    let timeZone: String
    let firstRun: Date
}
struct SchedulePause: Decodable { let paused: Bool }
struct TaskApproval: Decodable { let approved: Bool }
struct ClarifyReview: Decodable { let clarification: String }
struct SettingsChange: Decodable { let defaultModelID: UUID?; let preference: String? }
struct NewModel: Decodable {
    let name: String
    let kind: ProviderKind
    let endpoint: String
    let model: String
    let apiKey: String?
}
struct NewMemory: Decodable {
    let key: String
    let value: String
    let scope: String
    let sensitivity: MemorySensitivity
}
