import AidesCore
import AidesExecution
import Foundation
import Vapor

struct PendingCodeProposal: Codable, Sendable {
    let request: CodeProposalRequest
    var result: CodeProposalResult?
    var appliedPaths: [String] = []
}

struct CodeProposalDetails: Encodable {
    let files: [CodeProposalFile]
    let changes: [CodeProposalChange]
    let appliedPaths: [String]
    let summary: String?
}

struct NewCodeProposal: Decodable {
    let title: String
    let instruction: String
    let modelID: UUID
    let projectID: UUID
    let threadID: UUID?
    let paths: [String]
}

struct ApplyCodeChange: Decodable { let path: String }

extension AidesService {
    func createProposal(_ input: NewCodeProposal) async throws -> AppState {
        let title = try Self.required(input.title, max: 120)
        let instruction = try Self.required(input.instruction, max: 12_000)
        guard (1...24).contains(input.paths.count) else {
            throw Abort(.badRequest, reason: "Select between one and 24 exact project paths.")
        }
        let snapshot = await store.snapshot()
        let root = try Self.projectRoot(input.projectID, in: snapshot)
        let files: [CodeProposalFile]
        do {
            files = try input.paths.map { path in
                try ProjectFiles.validate(path: path)
                return try CodeProposalFile(path: path, contents: ProjectFiles.read(path: path, in: root))
            }
        } catch {
            throw Abort(.badRequest, reason: "A selected file is outside the project, unavailable, too large, or cannot be handled as text.")
        }
        let request = CodeProposalRequest(instruction: instruction, files: files)
        let prompt: String
        do { prompt = try CodeProposal.prompt(for: request) } catch {
            throw Abort(.badRequest, reason: error.localizedDescription)
        }
        return try await change { state in
            let scope = try Self.workScope(thread: input.threadID, project: input.projectID, in: state)
            let model = try Self.workModel(input.modelID, kind: .codeProposal, in: state)
            if model?.kind.isLocal == false {
                do { try CloudBoundary.validate(prompt) } catch {
                    throw Abort(.badRequest, reason: error.localizedDescription)
                }
            }
            let task = Self.makeTask(
                title: title, instruction: instruction, threadID: scope.threadID,
                projectID: scope.projectID, profile: model, kind: .codeProposal
            )
            state.app.tasks.append(task)
            state.proposals = (state.proposals ?? [:]).merging([task.id: PendingCodeProposal(request: request)]) { _, new in new }
        }
    }

    func proposalDetails(_ id: UUID) async throws -> CodeProposalDetails {
        let snapshot = await store.snapshot()
        guard let proposal = snapshot.proposals?[id] else { throw Abort(.notFound) }
        return CodeProposalDetails(
            files: proposal.request.files, changes: proposal.result?.changes ?? [],
            appliedPaths: proposal.appliedPaths, summary: proposal.result?.summary
        )
    }

    func applyProposal(_ id: UUID, path: String) async throws -> AppState {
        let snapshot = await store.snapshot()
        guard let pending = snapshot.proposals?[id],
              let edit = pending.result?.changes.first(where: { $0.path == path }) else {
            throw Abort(.notFound, reason: "There is no completed change for that path.")
        }
        if !pending.appliedPaths.contains(path) {
            do {
                try await LocalReview.check("Apply user-approved file replacement to \(path)",
                                            data: edit.proposedContents, in: snapshot)
            } catch {
                throw Abort(.forbidden, reason: error.localizedDescription)
            }
        }
        return try await change { state in
            guard state.app.settings.reviewModelID == snapshot.app.settings.reviewModelID else {
                throw Abort(.conflict, reason: "The review model changed. Review the proposal again.")
            }
            guard let task = state.app.tasks.first(where: { $0.id == id }), task.status == .completed,
                  let projectID = task.projectID, var proposal = state.proposals?[id],
                  let edit = proposal.result?.changes.first(where: { $0.path == path }) else {
                throw Abort(.notFound, reason: "There is no completed change for that path.")
            }
            guard !proposal.appliedPaths.contains(path) else { return }
            let root = try Self.projectRoot(projectID, in: state)
            do {
                let current = try ProjectFiles.read(path: path, in: root)
                // A completed single-file write can survive a process stop before SQLite records it.
                if current?.utf8.elementsEqual(edit.proposedContents.utf8) != true {
                    try ProjectFiles.apply(path: path, expected: edit.originalContents, replacement: edit.proposedContents, in: root)
                }
            } catch {
                throw Abort(.conflict, reason: "The file changed or is unavailable. Create a new proposal from its current contents.")
            }
            proposal.appliedPaths.append(path)
            state.proposals?[id] = proposal
        }
    }

    private static func projectRoot(_ id: UUID, in state: ServerState) throws -> URL {
        guard let path = state.app.projects.first(where: { $0.id == id })?.directory else {
            throw Abort(.notFound, reason: "The project is missing its server workspace.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
