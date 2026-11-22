import AidesCore
import SwiftUI

struct NewReviewSheet: View {
    let workspace: Workspace
    var threadID: UUID? = nil
    var projectID: UUID? = nil
    let onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var title = ""
    @ViewState private var instruction = ""
    @ViewState private var modelIDs = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeading("Review a complex task", description: "Each selected model interprets the same task independently. Compare its assumptions before assigning the work.")
            Form {
                TextField("Title", text: $title)
                TextField("Task instructions", text: $instruction, axis: .vertical)
                    .lineLimit(3...7)
                Section("Select two to four models") {
                    ForEach(workspace.state.models) { model in
                        Toggle(isOn: Binding(
                            get: { modelIDs.contains(model.id) },
                            set: { selected in
                                if selected {
                                    modelIDs.insert(model.id)
                                } else {
                                    modelIDs.remove(model.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name)
                                Text(model.kindLabel).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(modelIDs.count >= 4 && !modelIDs.contains(model.id))
                    }
                }
            }
            Text("Cloud models require approval before receiving the instructions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start review") {
                    Task {
                        let selected = workspace.state.models.filter { modelIDs.contains($0.id) }.map(\.id)
                        if let id = await workspace.createReview(ReviewRequest(
                            title: title.trimmed, instruction: instruction.trimmed, modelIDs: selected,
                            threadID: threadID, projectID: projectID
                        )) {
                            dismiss()
                            onCreated(id)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmed.isEmpty || instruction.trimmed.isEmpty || modelIDs.count < 2 || workspace.isWorking)
            }
        }
        .padding(22)
        .frame(width: 510)
    }
}

struct ReviewDetails: View {
    let workspace: Workspace
    let review: WorkItem

    @ViewState private var clarification = ""

    private var firstRound: [WorkItem] {
        workspace.state.tasks.filter { $0.parentID == review.id }
    }

    private var followUp: [WorkItem] {
        let initialIDs = Set(firstRound.map(\.id))
        return workspace.state.tasks.filter { $0.parentID.map(initialIDs.contains) == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(review.instruction).font(.callout).textSelection(.enabled)
            Divider()
            round("Independent interpretations", tasks: firstRound)
            if !followUp.isEmpty {
                Divider()
                round("After clarification", tasks: followUp)
            }
            if review.status == .waiting && followUp.isEmpty {
                Divider()
                if firstRound.contains(where: { $0.status == .completed && $0.result?.trimmed.isEmpty == false }) {
                    TextField("Clarification", text: $clarification, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                    Button("Send clarification") {
                        Task {
                            if await workspace.clarifyReview(review.id, clarification: clarification.trimmed) {
                                clarification = ""
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clarification.trimmed.isEmpty || workspace.isWorking)
                }
                Button("Finish review") { Task { await workspace.finishReview(review.id) } }
                    .disabled(workspace.isWorking)
            }
        }
    }

    private func round(_ name: String, tasks: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(name).font(.headline)
            ForEach(tasks) { task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(workspace.state.models.first { $0.id == task.modelID }?.name ?? task.title)
                        .font(.callout.weight(.medium))
                    TaskStatusView(task: task)
                    if task.status == .waitingApproval {
                        ApprovalDetails(workspace: workspace, task: task)
                    }
                    if let error = task.error {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let result = task.result, !result.isEmpty {
                        Text(result).font(.callout).textSelection(.enabled)
                    }
                    if task.status == .waiting {
                        Button("Resume run") { Task { await workspace.resume(task.id) } }
                            .disabled(workspace.isWorking)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
            }
        }
    }
}

struct ApprovalDetails: View {
    let workspace: Workspace
    let task: WorkItem
    var includesFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloud approval").font(.headline)
            if let provider = workspace.state.models.first(where: { $0.id == task.modelID }) {
                LabeledContent("Provider", value: provider.kindLabel)
            }
            if let project = workspace.state.projects.first(where: { $0.id == task.projectID }) {
                LabeledContent("Project", value: project.name)
            }
            Text(includesFiles ? "The following instructions and the listed file contents will be sent to the provider." : "The following task instructions will be sent to the provider.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(task.instruction)
                .textSelection(.enabled)
                .font(.callout)
            HStack {
                Button("Deny") { Task { await workspace.approve(task.id, approved: false) } }
                Button("Allow run") { Task { await workspace.approve(task.id, approved: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(workspace.isWorking)
        }
    }
}
