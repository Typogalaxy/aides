import AidesCore
import SwiftUI

struct ConversationSidebar: View {
    let conversations: [Conversation]
    let projects: [Project]
    @Binding var selection: UUID?
    let newConversation: () -> Void

    @ViewState private var query = ""
    @ViewState private var isSearching = false
    @ViewState private var collapsedProjects: Set<UUID> = []
    @ViewState private var showsArchived = false
    @FocusState private var isSearchFocused: Bool

    private var searchText: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let active = conversations.filter { $0.archivedAt == nil }
        let archived = conversations.filter { $0.archivedAt != nil }
        let projectThreads = Dictionary(grouping: active.filter { $0.projectID != nil }, by: \.projectID)
        let visibleProjects = projects.filter { projectThreads[$0.id] != nil }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Aides")
                    .desktopUIFont(.title2, weight: .semibold)
                Spacer()
                Button(action: toggleSearch) {
                    Image(systemName: isSearching ? "xmark" : "magnifyingglass")
                        .desktopUIFont(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 29, height: 29)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(isSearching ? "Close search" : "Search conversations")
                .accessibilityLabel(isSearching ? "Close search" : "Search conversations")
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            .padding(.leading, 17)
            .padding(.trailing, 11)
            .padding(.top, 15)
            .padding(.bottom, 9)

            Button(action: newConversation) {
                Label("New chat", systemImage: "square.and.pencil")
                    .desktopUIFont(.body, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.aidesAccent.opacity(0.11), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aidesAccent)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            if isSearching {
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
                    .onExitCommand(perform: toggleSearch)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 11) {
                    if searchText.isEmpty {
                        ForEach(active.filter { $0.role == .secretary }) { conversation in
                            conversationRow(conversation)
                        }
                        if !visibleProjects.isEmpty {
                            sidebarSection("Projects") {
                                ForEach(visibleProjects) { project in
                                    projectGroup(project, conversations: projectThreads[project.id] ?? [])
                                }
                            }
                        }
                        let projectIDs = Set(visibleProjects.map(\.id))
                        let looseConversations = active.reversed().filter {
                            $0.role != .secretary && !($0.projectID.map(projectIDs.contains) ?? false)
                        }
                        if !looseConversations.isEmpty {
                            sidebarSection("Conversations") {
                                ForEach(looseConversations) { conversation in
                                    conversationRow(conversation)
                                }
                            }
                        }
                        let recent = recentConversations(in: active)
                        if !recent.isEmpty {
                            sidebarSection("Recent") {
                                ForEach(recent) { conversation in
                                    conversationRow(conversation)
                                }
                            }
                        }
                        if !archived.isEmpty {
                            DisclosureGroup(isExpanded: $showsArchived) {
                                ForEach(archived.reversed()) { conversation in
                                    conversationRow(conversation, icon: "archivebox")
                                }
                            } label: {
                                Text("Archived").desktopUIFont(.callout, weight: .medium)
                            }
                            .padding(.horizontal, 6)
                        }
                    } else {
                        let projectNames = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
                        let matches = conversations.reversed().filter {
                            $0.title.localizedStandardContains(searchText) ||
                            $0.projectID.flatMap { projectNames[$0] }?.localizedStandardContains(searchText) == true
                        }
                        if matches.isEmpty {
                            Text("No matching conversations")
                                .desktopUIFont(.callout)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        } else {
                            ForEach(matches) { conversation in
                                conversationRow(conversation, icon: conversation.archivedAt == nil ? nil : "archivebox")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toggleSearch() {
        isSearching.toggle()
        if !isSearching { query = "" }
        isSearchFocused = isSearching
    }

    private func recentConversations(in active: [Conversation]) -> [Conversation] {
        Array(active.filter { $0.role != .secretary && !$0.messages.isEmpty }
            .sorted { ($0.messages.last?.createdAt ?? .distantPast) > ($1.messages.last?.createdAt ?? .distantPast) }
            .prefix(6))
    }

    private func sidebarSection<Content: View>(_ name: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .desktopUIFont(.callout, weight: .medium)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            content()
        }
    }

    private func projectGroup(_ project: Project, conversations: [Conversation]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !collapsedProjects.contains(project.id) },
            set: { expanded in
                if expanded {
                    collapsedProjects.remove(project.id)
                } else {
                    collapsedProjects.insert(project.id)
                }
            }
        )) {
            ForEach(conversations.reversed()) { conversation in
                conversationRow(conversation)
            }
            .padding(.leading, 7)
        } label: {
            Label(project.name, systemImage: "folder")
                .desktopUIFont(.body, weight: .medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
    }

    private func conversationRow(_ conversation: Conversation, icon: String? = nil) -> some View {
        let selected = selection == conversation.id
        return Button {
            selection = conversation.id
        } label: {
            Label(conversation.title, systemImage: icon ?? conversation.icon)
                .desktopUIFont(.body, weight: selected ? .medium : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(selected ? Color.aidesAccent.opacity(0.15) : .clear, in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(conversation.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
