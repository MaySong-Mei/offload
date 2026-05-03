import SwiftUI
import WebKit

// MARK: - Shared Helpers

private func _relativeTime(_ isoDate: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: isoDate) ?? ISO8601DateFormatter().date(from: isoDate) else {
        return isoDate.prefix(10).description
    }
    let interval = Date.now.timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3600 { return "\(Int(interval / 60))m ago" }
    if interval < 86400 { return "\(Int(interval / 3600))h ago" }
    return "\(Int(interval / 86400))d ago"
}

// MARK: - Root (3-column NavigationSplitView)

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var showingSettings = false
    @State private var navPath = NavigationPath()

    // chatOffset: -screenWidth..-panelWidth = right panel, 0 = fullscreen, sidebarWidth..screenWidth = sidebar
    @State private var chatOffset: CGFloat = 0
    private let sidebarWidth: CGFloat = 300
    private let panelWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let screenWidth = geo.size.width
            // f: 0→1 card effect intensity (works for both directions)
            let f = min(abs(chatOffset) / min(sidebarWidth, panelWidth), 1.0)
            let isOpen = abs(chatOffset) > 1

            ZStack(alignment: .leading) {
                // Layer 0: Gray base
                Color(.systemGroupedBackground).ignoresSafeArea()

                // Layer 1: White bezel
                RoundedRectangle(cornerRadius: f * 24, style: .continuous)
                    .fill(Color(.systemBackground))
                    .ignoresSafeArea()
                    .scaleEffect(1.0 - f * 0.055)
                    .offset(x: chatOffset)

                // Layer 2: Chat card
                NavigationStack(path: $navPath) {
                    ChatView(model: model)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { toggleSidebar() } label: {
                                    Image(systemName: "line.3.horizontal")
                                        .font(.body.weight(.medium))
                                }
                            }
                            ToolbarItem(placement: .principal) {
                                ProjectPickerPill(model: model)
                            }
                            ToolbarItem(placement: .navigationBarTrailing) {
                                HStack(spacing: 16) {
                                    Button { model.openTerminal() } label: {
                                        Image(systemName: "terminal")
                                            .font(.body.weight(.medium))
                                    }
                                    Button { toggleRightPanel() } label: {
                                        Image(systemName: "square.stack.3d.up")
                                            .font(.body.weight(.medium))
                                    }
                                }
                            }
                        }
                        .navigationDestination(for: ProjectNavItem.self) { item in
                            ProjectDashboardView(model: model, showingNewTopicSheet: .constant(false))
                                .onAppear { model.selectedProjectKey = item.path }
                                .navigationTitle(item.name)
                        }
                }
                .frame(width: screenWidth)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .scaleEffect(1.0 - f * 0.06)
                .shadow(color: .black.opacity(Double(f) * 0.15), radius: 16, x: chatOffset > 0 ? -4 : 4)
                .offset(x: chatOffset)
                .allowsHitTesting(!isOpen)

                // Layer 3: Panels (on top so they receive touches)
                if chatOffset > 0 {
                    ChatSidebarView(model: model, showingSettings: $showingSettings, onDismiss: {
                        closePanel()
                    }, onOpenProject: { path, name in
                        closePanel()
                        navPath = NavigationPath()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            navPath.append(ProjectNavItem(path: path, name: name))
                        }
                    }, expandFraction: max((chatOffset - sidebarWidth) / (screenWidth - sidebarWidth), 0))
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    .frame(width: chatOffset)
                    .clipped()
                    .ignoresSafeArea()
                } else if chatOffset < 0 {
                    RightPanelView(model: model, expandFraction: max((-chatOffset - panelWidth) / (screenWidth - panelWidth), 0), onDismiss: { closePanel() })
                        .padding(.top, geo.safeAreaInsets.top)
                        .padding(.bottom, geo.safeAreaInsets.bottom)
                        .frame(width: -chatOffset)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .ignoresSafeArea()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onChanged { value in
                        let isFromLeftEdge = value.startLocation.x < 30
                        let isFromRightEdge = value.startLocation.x > screenWidth - 30
                        let isShowing = abs(chatOffset) > 1
                        let isHorizontal = abs(value.translation.width) > abs(value.translation.height)

                        guard (isFromLeftEdge || isFromRightEdge || isShowing) && isHorizontal else { return }

                        let newOffset: CGFloat
                        if isShowing {
                            newOffset = chatOffset + value.translation.width
                        } else {
                            newOffset = value.translation.width
                        }

                        // Clamp: if sidebar is open (>0), don't allow going negative; vice versa
                        if chatOffset > 0 {
                            chatOffset = min(max(newOffset, 0), screenWidth)
                        } else if chatOffset < 0 {
                            chatOffset = min(max(newOffset, -screenWidth), 0)
                        } else {
                            // From closed: direction determined by drag
                            chatOffset = min(max(newOffset, -screenWidth), screenWidth)
                        }
                    }
                    .onEnded { value in
                        let predicted = chatOffset + (value.predictedEndTranslation.width - value.translation.width) * 0.5
                        snapBidirectional(predicted: predicted, screenWidth: screenWidth)
                    }
            )
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model)
        }
        .fullScreenCover(isPresented: $model.showTerminal) {
            NavigationStack {
                TerminalView(model: model, projectPath: model.terminalProjectPath)
            }
        }
        .task {
            model.bootstrap()
        }
    }

    private func snapBidirectional(predicted: CGFloat, screenWidth: CGFloat) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            if predicted > (sidebarWidth + screenWidth) / 2 {
                chatOffset = screenWidth           // sidebar extended
            } else if predicted > sidebarWidth / 2 {
                chatOffset = sidebarWidth           // sidebar shown
            } else if predicted < -(panelWidth + screenWidth) / 2 {
                chatOffset = -screenWidth           // right panel extended
            } else if predicted < -panelWidth / 2 {
                chatOffset = -panelWidth            // right panel shown
            } else {
                chatOffset = 0                     // closed
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if chatOffset < -1 {
                chatOffset = 0  // close right panel first
            } else if chatOffset < 1 {
                chatOffset = sidebarWidth
            } else if chatOffset > sidebarWidth + 1 {
                chatOffset = sidebarWidth
            } else {
                chatOffset = 0
            }
        }
    }

    private func toggleRightPanel() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if chatOffset > 1 {
                chatOffset = 0  // close sidebar first
            } else if chatOffset > -1 {
                chatOffset = -panelWidth
            } else if chatOffset < -panelWidth - 1 {
                chatOffset = -panelWidth
            } else {
                chatOffset = 0
            }
        }
    }

    private func closePanel() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if chatOffset > sidebarWidth + 1 {
                chatOffset = sidebarWidth
            } else if chatOffset < -panelWidth - 1 {
                chatOffset = -panelWidth
            } else {
                chatOffset = 0
            }
        }
    }
}

struct ProjectNavItem: Hashable {
    let path: String
    let name: String
}

// MARK: - Chat Sidebar

private struct ChatSidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var showingSettings: Bool
    var onDismiss: () -> Void
    var onOpenProject: (String, String) -> Void
    var expandFraction: CGFloat = 0  // 0 = compact (300pt), 1 = full screen

    private var projectSessions: [(project: String, name: String, sessions: [ChatSessionSummary])] {
        let grouped = Dictionary(grouping: model.chatSessions.filter { $0.project != nil }) { $0.project! }
        return grouped.map { path, sessions in
            let name = model.projects.first(where: { $0.path == path })?.name
                ?? (path as NSString).lastPathComponent
            return (project: path, name: name, sessions: sessions)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var ideaSessions: [ChatSessionSummary] {
        model.chatSessions.filter { $0.project == nil }
    }

    @State private var expandedProjects: Set<String>? = nil  // nil = not yet initialized

    // Auto-expand projects that have sessions
    private var effectiveExpanded: Set<String> {
        if let manual = expandedProjects { return manual }
        // Default: expand projects that have chat sessions
        return Set(model.chatSessions.compactMap { $0.project })
    }

    private func projectSessionCount(for path: String) -> Int {
        model.chatSessions.filter { $0.project == path }.count
    }

    private func sessionsForProject(_ path: String) -> [ChatSessionSummary] {
        model.chatSessions.filter { $0.project == path }
    }

    private func projectName(for path: String?) -> String? {
        guard let path else { return nil }
        return model.projects.first(where: { $0.path == path })?.name
            ?? (path as NSString).lastPathComponent
    }

    @State private var showingDashboard = false

    private var isExtended: Bool { expandFraction > 0.5 }

    var body: some View {
        VStack(spacing: 0) {
            // Header — tappable to open dashboard
            Button {
                showingDashboard = true
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Offload")
                            .font(isExtended ? .title.weight(.bold) : .title2.weight(.bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.statusMessage == "Connected" ? Color.green : (model.statusMessage == "Disconnected" ? Color.red : Color.orange))
                            .frame(width: 7, height: 7)
                        Text(model.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isExtended {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(model.projects.filter { $0.isInitialized }.count) projects")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(model.chatSessions.count) chats")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, isExtended ? 16 : 12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingDashboard) {
                ServerDashboardSheet(model: model)
            }

            // Session list
            List {
                // Projects section
                if !model.projects.isEmpty {
                    Section {
                        ForEach(model.projects.filter { $0.isInitialized }) { project in
                            let count = projectSessionCount(for: project.path)
                            let isExpanded = effectiveExpanded.contains(project.path) || isExtended

                            // Project row
                            HStack(spacing: 10) {
                                Button {
                                    onOpenProject(project.path, project.name)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .font(isExtended ? .title3 : .body)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(project.name)
                                                .font(isExtended ? .body.weight(.medium) : .subheadline)
                                                .foregroundStyle(.primary)
                                            if isExtended, let summary = project.summary, !summary.isEmpty {
                                                Text(summary)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                if !isExtended {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            var current = effectiveExpanded
                                            if current.contains(project.path) {
                                                current.remove(project.path)
                                            } else {
                                                current.insert(project.path)
                                            }
                                            expandedProjects = current
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if count > 0 {
                                                Text("\(count)")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Image(systemName: effectiveExpanded.contains(project.path) ? "chevron.down" : "chevron.right")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(.systemGray5), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Text("\(count) chats")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // Sessions — auto-expanded in extended mode
                            if isExpanded {
                                ForEach(sessionsForProject(project.path)) { session in
                                    ChatSessionRow(session: session, isSelected: session.sessionId == model.selectedChatSessionID)
                                        .padding(.leading, isExtended ? 28 : 20)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.selectChatSession(session.sessionId)
                                            onDismiss()
                                        }
                                }
                            }
                        }
                    } header: {
                        Text("Projects")
                    }
                }

                // Recents — all sessions sorted by most recent
                Section {
                    ForEach(model.chatSessions) { session in
                        ChatSessionRow(session: session, isSelected: session.sessionId == model.selectedChatSessionID, projectName: projectName(for: session.project))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectChatSession(session.sessionId)
                                onDismiss()
                            }
                    }
                } header: {
                    Text("Recents")
                }
            }
            .listStyle(.plain)

            // Bottom: New Chat button
            HStack {
                Spacer()
                Button {
                    Task { await model.createChatSession() }
                    onDismiss()
                } label: {
                    Label("Chat", systemImage: "square.and.pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Project chat menu
            if !model.projects.isEmpty {
                Menu {
                    ForEach(model.projects) { project in
                        Button(project.name) {
                            Task { await model.createChatSession(project: project.path) }
                            onDismiss()
                        }
                    }
                } label: {
                    Label("Project Chat", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
    }
}

private struct ChatSessionRow: View {
    let session: ChatSessionSummary
    var isSelected: Bool = false
    var projectName: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let projectName {
                        Text(projectName)
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(_relativeTime(session.lastMessageAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}

private struct ConnectionStatusView: View {
    @ObservedObject var model: AppModel
    @Binding var showingSettings: Bool

    var body: some View {
        Button { showingSettings = true } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(model.statusMessage)
                    .font(.caption2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.systemGray5), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch model.statusMessage {
        case "Connected": return .green
        case "Disconnected": return .red
        default: return .orange
        }
    }
}

// MARK: - Right Panel (Devices, Processing, Terminal)

private struct RightPanelView: View {
    @ObservedObject var model: AppModel
    var expandFraction: CGFloat = 0  // 0 = compact, 1 = full screen
    var onDismiss: () -> Void

    private var isExtended: Bool { expandFraction > 0.5 }

    // Current session's project
    private var currentProject: String? {
        guard let sid = model.selectedChatSessionID,
              let session = model.chatSessions.first(where: { $0.sessionId == sid }) else { return nil }
        return session.project
    }

    private var relevantTopics: [TopicSummary] {
        if isExtended {
            return model.topics
        }
        guard let project = currentProject else { return [] }
        return model.topics.filter { $0.project == project }
    }

    private var activeTopics: [TopicSummary] {
        relevantTopics.filter { $0.executionState == .implementing || $0.executionState == .queued }
    }

    private var pendingTopics: [TopicSummary] {
        relevantTopics.filter { $0.decisionState == .needsFeedback || $0.decisionState == .pendingImplementation }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isExtended ? "All Activity" : "Activity")
                    .font(isExtended ? .title.weight(.bold) : .title2.weight(.bold))
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let project = currentProject, !isExtended {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(model.projects.first { $0.path == project }?.name ?? (project as NSString).lastPathComponent)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            List {
                // Processing / Active
                if !activeTopics.isEmpty {
                    Section {
                        ForEach(activeTopics) { topic in
                            HStack(spacing: 10) {
                                ProgressView()
                                    .controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(String(describing: topic.executionState))
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        Label("Processing", systemImage: "bolt.fill")
                    }
                }

                // Pending feedback / action needed
                if !pendingTopics.isEmpty {
                    Section {
                        ForEach(pendingTopics) { topic in
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.body)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(topic.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(String(describing: topic.decisionState))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    } header: {
                        Label("Needs Attention", systemImage: "hand.raised.fill")
                    }
                }

                // All topics summary
                Section {
                    HStack {
                        Text("Total")
                        Spacer()
                        Text("\(relevantTopics.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Active")
                        Spacer()
                        Text("\(relevantTopics.filter { $0.decisionState != .archived }.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Completed")
                        Spacer()
                        Text("\(relevantTopics.filter { $0.executionState == .passed }.count)")
                            .foregroundStyle(.green)
                    }
                } header: {
                    Label(isExtended ? "All Topics" : "Topics", systemImage: "list.bullet")
                }

                // Server status
                Section {
                    HStack {
                        Circle()
                            .fill(model.statusMessage == "Connected" ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(model.statusMessage)
                            .font(.subheadline)
                        Spacer()
                        Text(model.serverURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } header: {
                    Label("Server", systemImage: "server.rack")
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Server Dashboard Sheet

private struct ServerDashboardSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Connection
                Section("Server") {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.statusMessage == "Connected" ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(model.statusMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("URL")
                        Spacer()
                        Text(model.serverURLString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Projects
                Section("Projects (\(model.projects.count))") {
                    ForEach(model.projects) { project in
                        HStack {
                            Image(systemName: project.isInitialized ? "folder.fill" : "folder")
                                .foregroundStyle(project.isInitialized ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.subheadline.weight(.medium))
                                if let summary = project.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(project.statusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Topics summary
                Section("Topics (\(model.topics.count))") {
                    let active = model.topics.filter { $0.decisionState != .archived }
                    let archived = model.topics.filter { $0.decisionState == .archived }
                    HStack {
                        Text("Active")
                        Spacer()
                        Text("\(active.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Archived")
                        Spacer()
                        Text("\(archived.count)")
                            .foregroundStyle(.secondary)
                    }
                }

                // Chat sessions
                Section("Chat Sessions (\(model.chatSessions.count))") {
                    let projectBound = model.chatSessions.filter { $0.project != nil }.count
                    let freeFloating = model.chatSessions.filter { $0.project == nil }.count
                    HStack {
                        Text("Project-bound")
                        Spacer()
                        Text("\(projectBound)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Free-floating")
                        Spacer()
                        Text("\(freeFloating)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Offload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Projects (column 1)

private struct ProjectsView: View {
    @ObservedObject var model: AppModel
    @Binding var showingSettings: Bool

    var body: some View {
        List(selection: Binding(
            get: { model.selectedProjectKey },
            set: { newKey in
                // Clear topic selection when switching projects to stop at dashboard
                if newKey != model.selectedProjectKey {
                    model.selectedTopicID = nil
                    model.selectedTopicDetail = nil
                }
                model.selectedProjectKey = newKey
            }
        )) {
            Section {
                ForEach(model.projects) { project in
                    ProjectCard(model: model, project: project)
                        .tag(project.path)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
            } header: {
                Text("Projects")
            }

            if !model.topics.filter({ ($0.project ?? "").isEmpty }).isEmpty {
                Section {
                    Label("Ungrouped", systemImage: "tray")
                        .font(.subheadline.weight(.medium))
                        .tag("")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Offload")
        .overlay {
            if model.projects.isEmpty && !model.isLoading {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder.badge.questionmark")
                } description: {
                    Text("Configure the server to scan a directory containing git repositories.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: connectionIcon)
                        .foregroundStyle(model.isOnline ? .green : .secondary)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .refreshable {
            await model.reload()
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = model.errorMessage {
                ErrorBanner(message: errorMessage) {
                    model.errorMessage = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.errorMessage)
    }

    private var connectionIcon: String {
        model.isOnline ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
    }
}

// MARK: - Project Card

private struct ProjectCard: View {
    @ObservedObject var model: AppModel
    let project: ProjectInfo
    @State private var showingUninstallConfirm = false
    @State private var showingReinitConfirm = false
    @State private var showingFullLog = false

    private var topicCount: Int {
        model.topics.filter { $0.project == project.path }.count
    }

    private var activeTopicCount: Int {
        model.topics.filter {
            $0.project == project.path &&
            ($0.executionState == .queued || $0.executionState == .implementing)
        }.count
    }

    private var initializingContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Initializing…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.cancelInit(project) }
                } label: {
                    Text("Cancel")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            InitLogPreview(log: model.projectInitLogs[project.path] ?? [], onTap: { showingFullLog = true })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(project.isInitialized ? Color.accentColor : Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(project.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                if project.isInitialized || project.initStatus == "failed" {
                    Menu {
                        Button {
                            model.openTerminal(for: project.path)
                        } label: {
                            Label("Open Terminal", systemImage: "terminal")
                        }
                        if project.initStatus == "ready" {
                            Button {
                                showingReinitConfirm = true
                            } label: {
                                Label("Re-initialize", systemImage: "arrow.clockwise")
                            }
                        }
                        if project.initStatus == "failed" {
                            Button {
                                Task { await model.initializeProject(project) }
                            } label: {
                                Label("Retry Initialize", systemImage: "arrow.clockwise")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            showingUninstallConfirm = true
                        } label: {
                            Label("Uninstall Offload", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            switch project.initStatus {
            case "ready":
                if let summary = project.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if activeTopicCount > 0 {
                        Text("\(activeTopicCount) active")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor, in: Capsule())
                        Text("/ \(topicCount) topics")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("\(topicCount)", systemImage: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Ready")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: Capsule())
                }

            case "initializing":
                initializingContent

            case "failed":
                Text(project.initError ?? "Initialization failed.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Button("Retry") {
                    Task { await model.initializeProject(project) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            default:  // not_initialized
                Text("Not yet onboarded to Offload.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.initializeProject(project) }
                } label: {
                    Label("Initialize", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showingFullLog) {
            InitLogSheet(model: model, project: project)
        }
        .confirmationDialog(
            "Uninstall Offload from \(project.name)?",
            isPresented: $showingUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) {
                Task { await model.uninitializeProject(project) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the .offload/ directory from the repo and strips the .gitignore entry. Your source files are untouched. You can re-initialize later.")
        }
        .confirmationDialog(
            "Re-initialize \(project.name)?",
            isPresented: $showingReinitConfirm,
            titleVisibility: .visible
        ) {
            Button("Re-initialize") {
                Task { await model.initializeProject(project) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Claude will re-read the repo and overwrite .offload/context/*.md. Existing topics are preserved.")
        }
    }
}

// MARK: - Project Dashboard (column 2)

private struct ProjectDashboardView: View {
    @ObservedObject var model: AppModel
    @Binding var showingNewTopicSheet: Bool
    @State private var readmeContent: String?
    @State private var showingNewSensorSheet = false

    private var topics: [TopicSummary] {
        model.topicsForSelectedProject()
    }

    private var projectName: String {
        if let key = model.selectedProjectKey {
            if key.isEmpty { return "Ungrouped" }
            if let p = model.projects.first(where: { $0.path == key }) { return p.name }
            return (key as NSString).lastPathComponent
        }
        return "Dashboard"
    }

    private var selectedProject: ProjectInfo? {
        guard let key = model.selectedProjectKey else { return nil }
        return model.projects.first { $0.path == key }
    }

    // --- Agent activity (used by meta card) ---

    private var implementingTopics: [TopicSummary] {
        topics.filter { $0.executionState == .implementing || $0.executionState == .queued }
    }

    // --- Pipeline (used by meta card) ---

    private var pipelineCounts: [(label: String, state: String, count: Int, color: Color)] {
        let states: [(String, String, Color)] = [
            ("Captured", "captured", .secondary),
            ("Specified", "specified", .blue),
            ("Approved", "approved", .teal),
            ("Building", "implementing", .indigo),
            ("Testing", "human_testing", .orange),
            ("Passed", "passed", .green),
            ("Archived", "archived", .secondary),
        ]
        return states.map { label, state, color in
            let count: Int
            switch state {
            case "captured": count = topics.filter { $0.requirementState == .captured }.count
            case "specified": count = topics.filter { $0.requirementState == .specified || $0.requirementState == .clarifying || $0.requirementState == .discussed }.count
            case "approved": count = topics.filter { $0.requirementApprovedAt != nil && $0.planApprovedAt == nil }.count
            case "implementing": count = topics.filter { $0.executionState == .implementing || $0.executionState == .queued }.count
            case "human_testing": count = topics.filter { $0.executionState == .humanTesting }.count
            case "passed": count = topics.filter { $0.executionState == .passed && $0.decisionState != .archived }.count
            case "archived": count = topics.filter { $0.decisionState == .archived }.count
            default: count = 0
            }
            return (label, state, count, color)
        }
    }

    var body: some View {
        List {
            // Meta Card → taps through to project detail
            if let activity = model.projectActivity {
                Section {
                    NavigationLink {
                        ProjectDetailView(model: model, activity: activity, readmeContent: readmeContent)
                    } label: {
                        ProjectMetaCard(
                            activity: activity,
                            pipelineCounts: pipelineCounts.map { ($0.label, $0.count, $0.color) },
                            implementingCount: implementingTopics.count
                        )
                    }
                }
            }

            // Signals (from sensors)
            if !model.signals.isEmpty || !model.sensors.isEmpty {
                Section {
                    signalsSection
                } header: {
                    HStack {
                        Label("Signals", systemImage: "sensor.fill")
                        Spacer()
                        if !model.sensors.isEmpty {
                            Text("\(model.sensors.count) sensor\(model.sensors.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            // All Topics
            Section {
                if topics.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Text("No topics yet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("New Topic") { showingNewTopicSheet = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                } else {
                    ForEach(topics) { topic in
                        NavigationLink {
                            TopicDetailLauncher(model: model, topicId: topic.topicId)
                        } label: {
                            TopicRow(topic: topic)
                        }
                    }
                }
            } header: {
                Label("All Topics (\(topics.count))", systemImage: "list.bullet")
            }

            // Section 5: README (if no meta card yet, keep accessible)
            if model.projectActivity == nil, let readme = readmeContent, !readme.isEmpty {
                Section {
                    NavigationLink {
                        ScrollView {
                            ReadmeView(content: readme).padding()
                        }
                        .navigationTitle("README")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("README", systemImage: "doc.text.fill")
                    }
                } header: {
                    Label("Project Context", systemImage: "book.closed")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { model.openTerminal() } label: {
                    Image(systemName: "terminal")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingNewTopicSheet = true } label: {
                        Label("New Topic", systemImage: "plus")
                    }
                    Button { showingNewSensorSheet = true } label: {
                        Label("Add Sensor", systemImage: "sensor.fill")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingNewSensorSheet) {
            NewSensorSheet(model: model)
        }
        .task(id: model.selectedProjectKey) {
            model.projectActivity = nil
            await loadReadme()
            if let key = model.selectedProjectKey, !key.isEmpty {
                async let _ = model.fetchActivity(projectPath: key)
                async let _ = model.fetchSensorsAndSignals(projectPath: key)
            }
        }
        .onAppear {
            if let key = model.selectedProjectKey, !key.isEmpty {
                Task {
                    await model.fetchActivity(projectPath: key)
                    await model.fetchSensorsAndSignals(projectPath: key)
                }
            }
        }
    }


    // MARK: Recent Changes

    @ViewBuilder
    private func recentChangesSection(runs: [RecentRun], commits: [RecentCommit]) -> some View {
        ForEach(runs.prefix(5)) { run in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: run.status == "succeeded" ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(run.status == "succeeded" ? .green : .red)
                        .font(.caption)
                    Text(run.topicTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if let date = run.finishedAt {
                        Text(_relativeTime(date))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let excerpt = run.reportExcerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
        if !commits.isEmpty {
            DisclosureGroup {
                ForEach(commits.prefix(5)) { commit in
                    HStack(spacing: 8) {
                        Text(commit.hash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(commit.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } label: {
                Label("Git Commits", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func relativeTime(_ isoDate: String) -> String {
        _relativeTime(isoDate)
    }

    // MARK: Section 5 — Project Context

    private func loadReadme() async {
        guard let key = model.selectedProjectKey, !key.isEmpty else {
            readmeContent = nil
            return
        }
        readmeContent = await model.fetchReadme(projectPath: key)
    }

    // MARK: Signals Section

    @ViewBuilder
    private var signalsSection: some View {
        // Show recent signals
        if model.signals.isEmpty {
            ForEach(model.sensors) { sensor in
                SensorRow(sensor: sensor)
            }
        } else {
            ForEach(model.signals.prefix(5)) { signal in
                SignalRow(signal: signal)
            }
            // Show sensor health below signals
            ForEach(model.sensors) { sensor in
                SensorRow(sensor: sensor)
            }
        }
    }
}

// MARK: - Signal Row

private struct SignalRow: View {
    let signal: SignalModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(severityColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .font(.subheadline)
                    .lineLimit(1)
                if !signal.detail.isEmpty {
                    Text(signal.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if signal.count > 1 {
                Text("\u{00D7}\(signal.count)")
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(severityColor)
            }
        }
    }

    private var severityColor: Color {
        switch signal.severity {
        case "critical": return .red
        case "warning": return .orange
        default: return .blue
        }
    }
}

// MARK: - Sensor Row

private struct SensorRow: View {
    let sensor: SensorModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            Text(sensor.name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(sensor.status)
                .font(.caption2.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.12), in: Capsule())
        }
    }

    private var statusIcon: String {
        switch sensor.status {
        case "active": return "antenna.radiowaves.left.and.right"
        case "building": return "hammer"
        case "testing": return "checkmark.circle.badge.questionmark"
        case "paused": return "pause.circle"
        case "failed": return "exclamationmark.triangle"
        default: return "sensor.fill"
        }
    }

    private var statusColor: Color {
        switch sensor.status {
        case "active": return .green
        case "building": return .blue
        case "testing": return .orange
        case "failed": return .red
        case "paused": return .secondary
        default: return .secondary
        }
    }
}

// MARK: - New Sensor Sheet

private struct NewSensorSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What do you want to observe?", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Describe the sensor")
                } footer: {
                    Text("Examples: \"Monitor crash reports from Sentry\", \"Watch for new GitHub issues with bug label\", \"Check API response time every 5 minutes\"")
                }
            }
            .navigationTitle("Add Sensor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        guard let key = model.selectedProjectKey, !key.isEmpty else { return }
        isSubmitting = true
        if let detail = await model.constructSensor(project: key, description: description) {
            // Select the newly created topic so user sees it
            model.selectedTopicID = detail.topic.topicId
            model.selectedTopicDetail = detail
        }
        isSubmitting = false
        dismiss()
    }
}

// MARK: - Project Meta Card

private struct ProjectMetaCard: View {
    let activity: ProjectActivityResponse
    var pipelineCounts: [(label: String, count: Int, color: Color)] = []
    var implementingCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.meta.name)
                        .font(.title3.weight(.bold))
                    if let summary = activity.meta.summary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }

            // Stats row
            HStack(spacing: 0) {
                StatBadge(label: "Topics", value: activity.meta.topicStats.total, color: .primary)
                Spacer()
                StatBadge(label: "Active", value: activity.meta.topicStats.active, color: .blue)
                Spacer()
                StatBadge(label: "Done", value: activity.meta.topicStats.completed, color: .green)
                Spacer()
                StatBadge(label: "Archived", value: activity.meta.topicStats.archived, color: .secondary)
            }
            .padding(.vertical, 4)

            // Pipeline dots
            let activePipeline = pipelineCounts.filter { $0.count > 0 }
            if !activePipeline.isEmpty {
                HStack(spacing: 8) {
                    ForEach(activePipeline, id: \.label) { item in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 8, height: 8)
                            Text("\(item.count)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(item.color)
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Agent activity indicator
            if implementingCount > 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(implementingCount) topic\(implementingCount == 1 ? "" : "s") building…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Architecture excerpt
            if let arch = activity.meta.architectureExcerpt, !arch.isEmpty {
                Text(arch)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(4)
    }
}

private struct StatBadge: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(value > 0 ? color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 50)
    }
}

// MARK: - Project Detail View (from Meta Card tap)

private struct ProjectDetailView: View {
    @ObservedObject var model: AppModel
    let activity: ProjectActivityResponse
    let readmeContent: String?

    var body: some View {
        List {
            // Summary
            if let summary = activity.meta.summary {
                Section {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Summary", systemImage: "text.alignleft")
                }
            }

            // Architecture — interactive tree
            if activity.meta.architectureExcerpt != nil {
                Section {
                    NavigationLink {
                        ArchitectureTreeView(model: model, projectPath: activity.meta.path)
                    } label: {
                        HStack {
                            Label("Architecture Map", systemImage: "building.columns")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } header: {
                    Label("Architecture", systemImage: "building.columns")
                }
            }

            // Recent Agent Changes
            if !activity.recentRuns.isEmpty {
                Section {
                    ForEach(activity.recentRuns.prefix(5)) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: run.status == "succeeded" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(run.status == "succeeded" ? .green : .red)
                                    .font(.caption)
                                Text(run.topicTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                            }
                            if !run.summary.isEmpty {
                                Text(run.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } header: {
                    Label("Recent Changes", systemImage: "clock.arrow.circlepath")
                }
            }

            // Pipeline
            Section {
                pipelineView
            } header: {
                Label("Pipeline", systemImage: "chart.bar")
            }

            // Stats
            Section {
                HStack(spacing: 0) {
                    StatBadge(label: "Topics", value: activity.meta.topicStats.total, color: .primary)
                    Spacer()
                    StatBadge(label: "Active", value: activity.meta.topicStats.active, color: .blue)
                    Spacer()
                    StatBadge(label: "Done", value: activity.meta.topicStats.completed, color: .green)
                    Spacer()
                    StatBadge(label: "Archived", value: activity.meta.topicStats.archived, color: .secondary)
                }
            } header: {
                Label("Topic Stats", systemImage: "chart.bar.fill")
            }

            // Recent Commits
            if !activity.recentCommits.isEmpty {
                Section {
                    ForEach(activity.recentCommits.prefix(8)) { commit in
                        HStack(spacing: 8) {
                            Text(commit.hash)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .frame(width: 65, alignment: .leading)
                            Text(commit.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Label("Recent Commits", systemImage: "point.3.filled.connected.trianglepath.dotted")
                }
            }

            // README
            if let readme = readmeContent, !readme.isEmpty {
                Section {
                    NavigationLink {
                        ScrollView {
                            ReadmeView(content: readme).padding()
                        }
                        .navigationTitle("README")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("README", systemImage: "doc.text.fill")
                    }
                }
            }

            // File Browser
            Section {
                NavigationLink {
                    FileBrowserView(model: model, projectPath: activity.meta.path, rel: "")
                } label: {
                    Label("Browse Files", systemImage: "folder")
                }
            } header: {
                Label("Files", systemImage: "doc.on.doc")
            } footer: {
                Text(activity.meta.path)
                    .font(.caption2.monospaced())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(activity.meta.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var topics: [TopicSummary] {
        model.topicsForSelectedProject()
    }

    private var pipelineCounts: [(label: String, state: String, count: Int, color: Color)] {
        let states: [(String, String, Color)] = [
            ("Captured", "captured", .secondary),
            ("Specified", "specified", .blue),
            ("Approved", "approved", .teal),
            ("Building", "implementing", .indigo),
            ("Testing", "human_testing", .orange),
            ("Passed", "passed", .green),
            ("Archived", "archived", .secondary),
        ]
        return states.map { label, state, color in
            let count: Int
            switch state {
            case "captured": count = topics.filter { $0.requirementState == .captured }.count
            case "specified": count = topics.filter { $0.requirementState == .specified || $0.requirementState == .clarifying || $0.requirementState == .discussed }.count
            case "approved": count = topics.filter { $0.requirementApprovedAt != nil && $0.planApprovedAt == nil }.count
            case "implementing": count = topics.filter { $0.executionState == .implementing || $0.executionState == .queued }.count
            case "human_testing": count = topics.filter { $0.executionState == .humanTesting }.count
            case "passed": count = topics.filter { $0.executionState == .passed && $0.decisionState != .archived }.count
            case "archived": count = topics.filter { $0.decisionState == .archived }.count
            default: count = 0
            }
            return (label, state, count, color)
        }
    }

    @ViewBuilder
    private var pipelineView: some View {
        let active = pipelineCounts.filter { $0.count > 0 }
        if active.isEmpty {
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Image(systemName: "arrow.right.arrow.left")
                        .font(.title3)
                        .foregroundStyle(.quaternary)
                    Text("No topics in pipeline yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                Spacer()
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(active, id: \.state) { item in
                        VStack(spacing: 3) {
                            Text("\(item.count)")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(item.color)
                            Text(item.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 50)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                        .background(item.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Architecture Tree (interactive top-down)

private struct ArchitectureTreeView: View {
    @ObservedObject var model: AppModel
    let projectPath: String

    @State private var tree: ArchNode?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading architecture…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let tree {
                ScrollView([.horizontal, .vertical]) {
                    VStack(spacing: 0) {
                        ArchNodeCard(node: tree, depth: 0)
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView {
                    Label("No Architecture", systemImage: "building.columns")
                } description: {
                    Text("Initialize this project to generate architecture data.")
                }
            }
        }
        .navigationTitle("Architecture")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .task { await load() }
    }

    private func load() async {
        guard let url = URL(string: model.serverURLString) else {
            isLoading = false
            return
        }
        let client = APIClient(baseURL: url, token: model.apiToken)
        tree = try? await client.fetchArchitectureTree(projectPath: projectPath)
        isLoading = false
    }
}

/// A single node in the architecture tree — recursively renders children.
private struct ArchNodeCard: View {
    let node: ArchNode
    let depth: Int

    @State private var isExpanded = true
    @State private var showDetail = false

    private var hasChildren: Bool { !node.children.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // This node's card
            Button {
                if hasChildren {
                    withAnimation(.easeInOut(duration: 0.25)) { isExpanded.toggle() }
                } else {
                    showDetail = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: nodeIcon)
                        .font(.caption)
                        .foregroundStyle(nodeColor)
                        .frame(width: 18)

                    Text(node.label)
                        .font(labelFont)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if hasChildren {
                        Text("(\(node.children.count))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 4)

                    if hasChildren {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(nodeColor.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDetail) {
                ArchNodeDetailSheet(node: node)
            }

            // Connector line + children
            if hasChildren && isExpanded {
                // Vertical connector
                Rectangle()
                    .fill(nodeColor.opacity(0.3))
                    .frame(width: 1.5, height: 12)

                // Children
                VStack(spacing: 6) {
                    ForEach(node.children) { child in
                        HStack(alignment: .top, spacing: 0) {
                            // Horizontal connector
                            Rectangle()
                                .fill(nodeColor.opacity(0.2))
                                .frame(width: 16, height: 1.5)
                                .padding(.top, 14)

                            ArchNodeCard(node: child, depth: depth + 1)
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .frame(minWidth: depth == 0 ? 280 : 200, alignment: .leading)
        .onAppear {
            // Auto-collapse deep nodes
            if depth >= 2 { isExpanded = false }
        }
    }

    private var nodeIcon: String {
        switch node.type {
        case "project": return "folder.fill"
        case "group": return "square.stack.3d.up"
        case "layer": return "rectangle.3.group"
        case "module": return "doc.text"
        default: return "circle.fill"
        }
    }

    private var nodeColor: Color {
        switch node.type {
        case "project": return .blue
        case "group": return .purple
        case "layer": return .teal
        case "module": return .orange
        default: return .secondary
        }
    }

    private var labelFont: Font {
        switch node.type {
        case "project": return .subheadline.weight(.bold)
        case "group": return .subheadline.weight(.semibold)
        case "layer": return .caption.weight(.semibold)
        case "module": return .caption
        default: return .caption
        }
    }

    private var cardBackground: Color {
        switch node.type {
        case "project": return Color.blue.opacity(0.08)
        case "group": return Color.purple.opacity(0.06)
        case "layer": return Color.teal.opacity(0.06)
        case "module": return Color(.secondarySystemGroupedBackground)
        default: return Color(.secondarySystemGroupedBackground)
        }
    }
}

/// Detail sheet shown when tapping a leaf node
private struct ArchNodeDetailSheet: View {
    let node: ArchNode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Type badge
                    HStack {
                        Text(node.type.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badgeColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(badgeColor)

                        Spacer()
                    }

                    // Description
                    if !node.desc.isEmpty {
                        Text(node.desc)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    // Children list
                    if !node.children.isEmpty {
                        Divider()
                        Text("Contains")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)

                        ForEach(node.children) { child in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(childColor(child))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.label)
                                        .font(.caption.weight(.medium))
                                    if !child.desc.isEmpty {
                                        Text(child.desc)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(node.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var badgeColor: Color {
        switch node.type {
        case "project": return .blue
        case "group": return .purple
        case "layer": return .teal
        case "module": return .orange
        default: return .secondary
        }
    }

    private func childColor(_ child: ArchNode) -> Color {
        switch child.type {
        case "layer": return .teal
        case "module": return .orange
        default: return .secondary
        }
    }
}

// MARK: - File Browser

private struct FileBrowserView: View {
    @ObservedObject var model: AppModel
    let projectPath: String
    let rel: String

    @State private var entries: [FileEntry] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var title: String {
        if rel.isEmpty { return "Files" }
        return (rel as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("Empty", systemImage: "folder")
                } description: {
                    Text("No files in this directory.")
                }
            } else {
                List(entries) { entry in
                    if entry.isDir {
                        NavigationLink {
                            FileBrowserView(model: model, projectPath: projectPath, rel: entry.relPath)
                        } label: {
                            fileRow(entry)
                        }
                    } else {
                        NavigationLink {
                            FileContentView(model: model, projectPath: projectPath, rel: entry.relPath)
                        } label: {
                            fileRow(entry)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadFiles()
        }
    }

    @ViewBuilder
    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDir ? "folder.fill" : fileIcon(for: entry.name))
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            Text(entry.name)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            if !entry.isDir, let size = entry.size {
                Text(formatSize(size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func loadFiles() async {
        guard let client = makeClient() else {
            errorMessage = "Not connected"
            isLoading = false
            return
        }
        do {
            let result = try await client.fetchFiles(projectPath: projectPath, rel: rel)
            entries = result.entries
            if let err = result.error {
                errorMessage = err
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func makeClient() -> APIClient? {
        guard let url = URL(string: model.serverURLString) else { return nil }
        return APIClient(baseURL: url, token: model.apiToken)
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "py", "js", "ts", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.badge.gearshape"
        case "md", "txt", "rst":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico":
            return "photo"
        case "xcodeproj", "xcworkspace":
            return "hammer"
        default:
            return "doc"
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - File Content View

private struct FileContentView: View {
    @ObservedObject var model: AppModel
    let projectPath: String
    let rel: String

    @State private var content: String?
    @State private var isBinary = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var fileSize: Int?

    private var fileName: String {
        (rel as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isBinary {
                ContentUnavailableView {
                    Label("Binary File", systemImage: "doc.zipper")
                } description: {
                    Text("\(fileName) (\(formatSize(fileSize ?? 0)))\nBinary files cannot be displayed.")
                }
            } else if let error = errorMessage {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let content {
                ScrollView(.horizontal) {
                    ScrollView(.vertical) {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                    }
                }
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let size = fileSize {
                ToolbarItem(placement: .status) {
                    Text(formatSize(size))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        guard let url = URL(string: model.serverURLString) else {
            errorMessage = "Not connected"
            isLoading = false
            return
        }
        let client = APIClient(baseURL: url, token: model.apiToken)
        do {
            let result = try await client.fetchFileContent(projectPath: projectPath, rel: rel)
            fileSize = result.size
            if result.binary == true {
                isBinary = true
            } else {
                content = result.content
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Action Card

private struct ActionCard<ActionLabel: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let onTap: () -> Void
    var action: (() -> Void)?
    var actionLabel: (() -> ActionLabel)?

    init(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        onTap: @escaping () -> Void,
        action: (() -> Void)? = nil,
        @ViewBuilder actionLabel: @escaping () -> ActionLabel
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.onTap = onTap
        self.action = action
        self.actionLabel = actionLabel
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let action, let actionLabel {
                    Button(action: action) {
                        actionLabel()
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// Convenience init without action button
extension ActionCard where ActionLabel == EmptyView {
    init(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        onTap: @escaping () -> Void
    ) {
        self.icon = icon
        self.color = color
        self.title = title
        self.subtitle = subtitle
        self.onTap = onTap
        self.action = nil
        self.actionLabel = nil
    }
}

// MARK: - Settings Sheet

// MARK: - Init Log Preview (inline in card)

private struct InitLogPreview: View {
    let log: [String]
    let onTap: () -> Void

    var body: some View {
        if !log.isEmpty {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(log.suffix(5).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text("Tap for full log →")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Init Log Sheet

private struct InitLogSheet: View {
    @ObservedObject var model: AppModel
    let project: ProjectInfo
    @Environment(\.dismiss) private var dismiss

    private var log: [String] {
        model.projectInitLogs[project.path] ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding()
                }
                .onChange(of: log.count) { _, newCount in
                    if newCount > 0 {
                        withAnimation {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Init: \(project.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if project.initStatus == "initializing" {
                        Button("Cancel Init", role: .destructive) {
                            Task { await model.cancelInit(project) }
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var anthropicApiKey = ""
    @State private var hasApiKey = false
    @State private var apiKeyPreview = ""
    @State private var apiKeySaved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $model.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote.monospaced())
                    SecureField("API token (optional)", text: $model.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        model.connect()
                    } label: {
                        Label("Connect", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } header: {
                    Text("Server")
                } footer: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isOnline ? .green : .secondary)
                            .frame(width: 6, height: 6)
                        Text(model.statusMessage)
                    }
                }

                // MARK: Claude API Key
                Section {
                    SecureField("sk-ant-…", text: $anthropicApiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                    Button {
                        Task {
                            guard let client = model.makeClient() else { return }
                            do {
                                try await client.saveChatApiKey(anthropicApiKey)
                                apiKeySaved = true
                                anthropicApiKey = ""
                                // Refresh config
                                if let config = try? await client.fetchChatConfig() {
                                    apiKeyPreview = config.apiKeyPreview
                                    hasApiKey = config.hasApiKey
                                }
                            } catch {
                                model.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Save Key", systemImage: "key")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(anthropicApiKey.isEmpty)
                } header: {
                    Text("Claude API")
                } footer: {
                    if hasApiKey {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("Key configured: \(apiKeyPreview)")
                        }
                    } else {
                        Text("Required for chat. Get a key from console.anthropic.com")
                    }
                }

                // MARK: Agents
                Section {
                    if model.isCheckingAgents {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking agents…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.agentStatuses.isEmpty {
                        Button {
                            Task { await model.fetchAgentStatuses() }
                        } label: {
                            Label("Check Agent Status", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!model.isOnline)
                    } else {
                        ForEach(model.agentStatuses) { agent in
                            AgentStatusRow(agent: agent)
                        }
                        Button {
                            Task { await model.fetchAgentStatuses() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Label("Agents", systemImage: "cpu")
                } footer: {
                    Text("Agents installed on the server that can execute tasks.")
                }

                if model.pendingOperationCount > 0 {
                    Section("Pending Sync") {
                        HStack {
                            Label("Queued changes", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            Text("\(model.pendingOperationCount)")
                                .foregroundStyle(.orange)
                                .fontWeight(.semibold)
                        }
                        if model.isOnline && !model.isSyncing {
                            Button("Sync Now") {
                                Task { await model.syncPendingOperations() }
                            }
                        }
                    }
                }

                if !model.feedbackQueue.isEmpty {
                    Section("Feedback") {
                        Label("Pending requests: \(model.feedbackQueue.count)", systemImage: "bell.badge.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if model.isOnline && model.agentStatuses.isEmpty {
                    await model.fetchAgentStatuses()
                }
                // Load API key status
                if let client = model.makeClient() {
                    if let config = try? await client.fetchChatConfig() {
                        hasApiKey = config.hasApiKey
                        apiKeyPreview = config.apiKeyPreview
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct AgentStatusRow: View {
    let agent: AgentStatusModel

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(.subheadline.weight(.medium))
                    if let version = agent.version {
                        Text(version)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if agent.available {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(authColor)
                            .frame(width: 5, height: 5)
                        Text(authLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = agent.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Status badge
            Text(agent.available ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(agent.available ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (agent.available ? Color.green : Color.secondary).opacity(0.12),
                    in: Capsule()
                )
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch agent.name {
        case "claude": return "brain"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "command": return "terminal"
        default: return "cpu"
        }
    }

    private var iconColor: Color {
        agent.available ? .accentColor : .secondary
    }

    private var authColor: Color {
        switch agent.authStatus {
        case "authenticated": return .green
        case "needs_login": return .orange
        default: return .secondary
        }
    }

    private var authLabel: String {
        switch agent.authStatus {
        case "authenticated": return "Authenticated"
        case "needs_login": return "Needs login"
        default: return "Auth unknown"
        }
    }
}

// MARK: - Topic Row

private struct TopicRow: View {
    let topic: TopicSummary

    private var isLocal: Bool { topic.topicId.hasPrefix("local-") }

    private var needsAttention: Bool {
        topic.executionState == .failed
            || topic.executionState == .humanTesting
            || (topic.requirementState == .specified && topic.requirementApprovedAt == nil)
            || (topic.requirementApprovedAt != nil && topic.planApprovedAt == nil && topic.executionState == .idle)
            || topic.pendingFeedbackRequestId != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if needsAttention {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Text(topic.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if isLocal {
                    Text("offline")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
            }
            if !topic.summary.isEmpty {
                Text(topic.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                StatusChip(text: topic.requirementState.rawValue, category: .requirement)
                StatusChip(text: topic.executionState.rawValue, category: .execution)
                if topic.decisionState != .none {
                    StatusChip(text: topic.decisionState.rawValue, category: .decision)
                }
                Spacer()
                Text(_relativeTime(topic.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Connection Panel

private struct ConnectionPanel: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    var isConnected: Bool { model.statusMessage == "Connected" }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 12) {
                TextField("Server URL", text: $model.serverURLString)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote.monospaced())

                SecureField("API token (optional)", text: $model.apiToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)

                Button {
                    model.connect()
                } label: {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Server")
                        .font(.subheadline.weight(.medium))
                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(isConnected ? .green : .secondary)
                }
            } icon: {
                Image(systemName: isConnected ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(isConnected ? .green : .secondary)
                    .symbolEffect(.pulse, isActive: model.isLoading)
            }
        }
    }
}

// MARK: - Error Banner

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.red.gradient, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - New Topic Sheet

private struct NewTopicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let parentTopic: TopicSummary?
    @State private var title = ""
    @State private var rawInput = ""
    @State private var tagsText = ""
    @State private var project = ""

    private var isValid: Bool {
        !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if let parentTopic {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(parentTopic.title)
                                    .font(.subheadline.weight(.medium))
                                Text(parentTopic.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } icon: {
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Parent Topic")
                    }
                }

                Section {
                    TextField("Title", text: $title)
                    TextField("Tags (comma separated)", text: $tagsText)
                        .textInputAutocapitalization(.never)

                    if !model.projects.isEmpty {
                        Menu {
                            Button("None") { project = "" }
                            Divider()
                            ForEach(model.projects) { p in
                                Button {
                                    project = p.path
                                } label: {
                                    Label(p.name, systemImage: p.hasReadme ? "doc.text" : "folder")
                                }
                            }
                        } label: {
                            HStack {
                                Label("Project", systemImage: "folder.fill")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(project.isEmpty ? "None" : (URL(fileURLWithPath: project).lastPathComponent))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        TextField("Project (repo path)", text: $project)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                    }
                } header: {
                    Text("Details")
                }

                Section {
                    TextEditor(text: $rawInput)
                        .frame(minHeight: 200)
                } header: {
                    Text("Description")
                } footer: {
                    Text("Describe the idea, task, or goal in natural language.")
                }
            }
            .navigationTitle(parentTopic == nil ? "New Topic" : "New Subtopic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await model.createTopic(
                                title: title,
                                rawInput: rawInput,
                                tagsText: tagsText,
                                project: project.isEmpty ? nil : project,
                                parentTopicID: parentTopic?.topicId
                            )
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            // Auto-fill project from the currently selected project in sidebar
            if project.isEmpty, let key = model.selectedProjectKey, !key.isEmpty {
                project = key
            }
        }
    }
}

// MARK: - Topic Detail

/// Loads topic detail on appear and shows TopicDetailView.
/// Used as NavigationLink destination so topics can be tapped from the list.
private struct TopicDetailLauncher: View {
    @ObservedObject var model: AppModel
    let topicId: String

    var body: some View {
        Group {
            if let detail = model.selectedTopicDetail, detail.topic.topicId == topicId {
                TopicDetailView(model: model, detail: detail)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            model.selectTopic(topicId)
        }
    }
}

private struct TopicDetailView: View {
    @ObservedObject var model: AppModel
    let detail: TopicDetailResponse
    @State private var refreshNote = ""
    @State private var planNote = ""
    @State private var commandText = "/usr/bin/printf hello-from-ios"
    @State private var showingNewSubtopicSheet = false
    @State private var selectedExecutor = "command"
    @State private var promptText = ""
    @State private var readmeContent: String?
    @State private var loadedReadmeForProject: String?

    private var pendingFeedback: [FeedbackRequestModel] {
        detail.feedbackRequests.filter { $0.status == "pending" }
    }

    private var resolvedFeedback: [FeedbackRequestModel] {
        detail.feedbackRequests.filter { $0.status == "resolved" }
    }

    private var canArchive: Bool {
        detail.topic.executionState == .passed && detail.topic.decisionState != .archived
    }

    // Live stream lines for this topic
    private var streamEvents: [AgentStreamEvent] {
        model.agentConversation.filter { $0.topicId == detail.topic.topicId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    sectionDivider("Topic", timestamp: detail.topic.createdAt)
                    Text(detail.topic.rawInput)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                    HStack(spacing: 6) {
                        StatusChip(text: detail.topic.requirementState.rawValue, category: .requirement)
                        StatusChip(text: detail.topic.executionState.rawValue, category: .execution)
                        if detail.topic.decisionState != .none {
                            StatusChip(text: detail.topic.decisionState.rawValue, category: .decision)
                        }
                    }
                    .padding(.bottom, 16)

                    // Live agent session (all stages — always visible as history)
                    let allStream = streamEvents.filter { $0.claudeEventType != "system" }
                    if !allStream.isEmpty {
                        sectionDivider("Agent", subtitle: allStream.last?.stage ?? "")
                        claudeSessionBlock(events: allStream)
                    }

                    // Resolved feedback (past Q&A)
                    ForEach(resolvedFeedback) { request in
                        sectionDivider("Agent")
                        Text(request.prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 8)
                        // Show options that were available
                        HStack(spacing: 6) {
                            ForEach(request.options, id: \.self) { opt in
                                Text(opt)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.bottom, 4)
                        Text("Answered")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .padding(.bottom, 16)
                    }

                    // Requirement stage (stream already shown above)

                    // Requirement document
                    if let req = detail.documents["requirement.md"],
                       !req.contains("Awaiting clarification") {
                        sectionDivider("Requirement")
                        documentLink(title: "Requirement", content: req)
                        if detail.topic.requirementApprovedAt != nil {
                            statusBadge("Approved", color: .green)
                        }
                    }

                    // Pending feedback (interactive)
                    ForEach(pendingFeedback) { request in
                        sectionDivider("Agent")
                        FeedbackRequestCard(model: model, request: request)
                            .padding(.bottom, 16)
                    }

                    // Plan stage (stream already shown above)

                    // Plan document
                    if let plan = detail.documents["plan.md"],
                       !plan.contains("Pending — requirement must be approved first") {
                        sectionDivider("Plan")
                        documentLink(title: "Implementation Plan", content: plan)
                        if detail.topic.planApprovedAt != nil {
                            statusBadge("Approved", color: .green)
                        }
                    }

                    // Contextual actions
                    workflowActions

                    // Runs
                    ForEach(detail.runs) { run in
                        sectionDivider("Run", subtitle: run.executor)
                        runBlock(run: run)
                    }

                    // Archive
                    if detail.topic.decisionState == .archived {
                        sectionDivider("Archived")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(detail.topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showingNewSubtopicSheet = true } label: {
                        Label("New Subtopic", systemImage: "plus.circle")
                    }
                    if let conv = detail.documents["conversation.md"], !conv.isEmpty {
                        NavigationLink {
                            ScrollView {
                                Text(conv)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding()
                            }
                            .navigationTitle("Full Log")
                        } label: {
                            Label("Conversation Log", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingNewSubtopicSheet) {
            NewTopicSheet(model: model, parentTopic: detail.topic)
        }
    }

    // MARK: - Claude Code Style Components

    @ViewBuilder
    private func sectionDivider(_ label: String, subtitle: String = "", timestamp: String = "") -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 12, height: 1)
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !timestamp.isEmpty {
                    Text(_relativeTime(timestamp))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 8)
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func claudeSessionBlock(events: [AgentStreamEvent]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events.suffix(30)) { event in
                switch event.claudeEventType {
                case "assistant":
                    if let text = event.text, !text.isEmpty,
                       !text.trimmingCharacters(in: .whitespaces).hasPrefix("[{"),
                       !text.trimmingCharacters(in: .whitespaces).hasPrefix("{\"") {
                        Text(text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                    if let tool = event.toolName {
                        HStack(spacing: 6) {
                            Image(systemName: toolIcon(tool))
                                .font(.caption2)
                                .foregroundStyle(.teal)
                            Text(tool)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.teal)
                            if let input = event.toolInput, !input.isEmpty {
                                Text(input)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                case "tool_result":
                    if let result = event.toolResult, !result.isEmpty {
                        Text(result)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(4)
                            .padding(.leading, 12)
                    }
                case "result":
                    // Result is the final output — only show if it's human-readable (not JSON)
                    if let result = event.result, !result.isEmpty,
                       !result.trimmingCharacters(in: .whitespaces).hasPrefix("[{"),
                       !result.trimmingCharacters(in: .whitespaces).hasPrefix("{\"") {
                        Divider()
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .padding(.bottom, 12)
    }

    private func toolIcon(_ name: String) -> String {
        switch name {
        case "Read": return "doc.text"
        case "Glob": return "magnifyingglass"
        case "Grep": return "text.magnifyingglass"
        case "Bash": return "terminal"
        case "Edit", "Write": return "pencil"
        default: return "wrench"
        }
    }

    @ViewBuilder
    private func documentLink(title: String, content: String) -> some View {
        NavigationLink {
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func statusBadge(_ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func runBlock(run: RunRecordModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: run.status == "succeeded" ? "checkmark.circle.fill" : run.status == "running" ? "progress.indicator" : "xmark.circle.fill")
                    .foregroundStyle(run.status == "succeeded" ? .green : run.status == "running" ? .blue : .red)
                    .font(.caption)
                Text(run.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(run.status == "succeeded" ? .green : run.status == "running" ? .blue : .red)
                Spacer()
                if let finished = run.finishedAt {
                    Text(_relativeTime(finished))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
            Text(run.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Contextual Workflow Actions

    @ViewBuilder
    private var workflowActions: some View {
        let topic = detail.topic

        if topic.decisionState == .archived {
            EmptyView()
        } else if topic.executionState == .humanTesting {
            sectionDivider("Action")
            ActionButton("Confirm Passed", icon: "checkmark.seal", style: .primary) {
                await model.markPassed()
            }
            .padding(.bottom, 12)
        } else if topic.executionState == .implemented {
            sectionDivider("Action")
            ActionButton("Start Testing", icon: "person.fill.checkmark", style: .secondary) {
                await model.markHumanTesting()
            }
            .padding(.bottom, 12)
        } else if topic.planApprovedAt != nil && topic.executionState == .idle {
            sectionDivider("Execute")
            ActionButton("Launch Claude Agent", icon: "play.circle.fill", style: .primary) {
                await model.triggerRun(executor: "claude", commandText: "")
            }
            .padding(.bottom, 12)
        } else if topic.requirementApprovedAt != nil && topic.planApprovedAt == nil {
            if let plan = detail.documents["plan.md"],
               !plan.contains("Pending — requirement must be approved first") {
                sectionDivider("Review Plan")
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ActionButton("Approve & Execute", icon: "play.circle", style: .primary) {
                            await model.approvePlan()
                        }
                        ActionButton("Revise", icon: "arrow.clockwise", style: .secondary) {
                            await model.refreshPlan(note: planNote)
                            planNote = ""
                        }
                    }
                    TextField("Adjustments or constraints…", text: $planNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .lineLimit(1...3)
                }
                .padding(.bottom, 12)
            }
        } else if topic.requirementApprovedAt == nil {
            if let req = detail.documents["requirement.md"],
               !req.contains("Awaiting clarification"),
               pendingFeedback.isEmpty {
                sectionDivider("Review Requirement")
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        ActionButton("Approve", icon: "checkmark.circle", style: .primary) {
                            await model.approveRequirement()
                        }
                        ActionButton("Revise", icon: "arrow.clockwise", style: .secondary) {
                            await model.refreshRequirement(note: refreshNote)
                            refreshNote = ""
                        }
                    }
                    TextField("Revision notes…", text: $refreshNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .lineLimit(1...3)
                }
                .padding(.bottom, 12)
            }
        }

        if canArchive {
            sectionDivider("Complete")
            ActionButton("Archive Topic", icon: "archivebox", style: .secondary) {
                await model.archiveTopic()
            }
            .padding(.bottom, 12)
        }
    }

}

// MARK: - Action Button

private enum ActionButtonStyle {
    case primary, secondary
}

private struct ActionButton: View {
    let title: String
    let icon: String
    let style: ActionButtonStyle
    let action: () async -> Void

    init(_ title: String, icon: String, style: ActionButtonStyle, action: @escaping () async -> Void) {
        self.title = title
        self.icon = icon
        self.style = style
        self.action = action
    }

    var body: some View {
        if style == .primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
        }
        .controlSize(.small)
    }
}

// MARK: - Feedback Card

private struct FeedbackRequestCard: View {
    @ObservedObject var model: AppModel
    let request: FeedbackRequestModel
    @State private var selectedOption = ""
    @State private var note = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title & prompt
            Text(request.title)
                .font(.subheadline.weight(.semibold))
            Text(request.prompt)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // Tappable option chips
            if !request.options.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(request.options, id: \.self) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedOption = option
                            }
                        } label: {
                            Text(option)
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    selectedOption == option
                                        ? Color.orange
                                        : Color(.tertiarySystemFill),
                                    in: Capsule()
                                )
                                .foregroundStyle(selectedOption == option ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Note field — always visible, more inviting
            TextField(
                request.allowNote ? "Add a note (optional)…" : "Additional context…",
                text: $note,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.footnote)
            .lineLimit(1...4)

            // Submit
            Button {
                isSubmitting = true
                Task {
                    let selection = selectedOption.isEmpty ? [] : [selectedOption]
                    await model.submitFeedback(requestID: request.requestId, selectedOptions: selection, note: note)
                    isSubmitting = false
                }
            } label: {
                if isSubmitting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Submit", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .disabled(selectedOption.isEmpty && note.isEmpty)
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Simple flow layout for wrapping option chips
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        var subviewIndex = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[subviewIndex].sizeThatFits(.unspecified)
                subviews[subviewIndex].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
                subviewIndex += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row { var count: Int; var height: CGFloat }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0
        var currentCount = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && currentCount > 0 {
                rows.append(Row(count: currentCount, height: currentHeight))
                currentWidth = 0
                currentHeight = 0
                currentCount = 0
            }
            currentWidth += size.width + spacing
            currentHeight = max(currentHeight, size.height)
            currentCount += 1
        }
        if currentCount > 0 {
            rows.append(Row(count: currentCount, height: currentHeight))
        }
        return rows
    }
}

// MARK: - Document Section

// MARK: - README Renderer

private struct ReadmeView: View {
    let content: String

    private var blocks: [ReadmeBlock] {
        ReadmeParser.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ReadmeBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(for: level))
                .fontWeight(.bold)
                .padding(.top, level == 1 ? 4 : 2)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let code):
            Text(code)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        case .listItem(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .blank:
            EmptyView()
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private enum ReadmeBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(String)
    case listItem(String)
    case blank
}

private enum ReadmeParser {
    static func parse(_ content: String) -> [ReadmeBlock] {
        var blocks: [ReadmeBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                let joined = paragraphLines.joined(separator: " ")
                blocks.append(.paragraph(joined))
                paragraphLines.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Code block
            if trimmed.hasPrefix("```") {
                flushParagraph()
                i += 1
                var codeLines: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n")))
                continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                flushParagraph()
                var level = 0
                for char in trimmed {
                    if char == "#" { level += 1 } else { break }
                }
                level = min(level, 6)
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // List item
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                let text = String(trimmed.dropFirst(2))
                blocks.append(.listItem(text))
                i += 1
                continue
            }

            // Numbered list
            if let firstChar = trimmed.first, firstChar.isNumber {
                if let dotIndex = trimmed.firstIndex(of: "."),
                   trimmed.distance(from: trimmed.startIndex, to: dotIndex) <= 3,
                   trimmed.index(after: dotIndex) < trimmed.endIndex,
                   trimmed[trimmed.index(after: dotIndex)] == " " {
                    flushParagraph()
                    let text = String(trimmed[trimmed.index(dotIndex, offsetBy: 2)...])
                    blocks.append(.listItem(text))
                    i += 1
                    continue
                }
            }

            paragraphLines.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }
}

private struct DocumentSection: View {
    let title: String
    let icon: String
    let bodyText: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Label(title, systemImage: icon)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 16)

                Text(bodyText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Run Card

private struct RunCard: View {
    let run: RunRecordModel

    var statusColor: Color {
        switch run.status {
        case "success", "passed": .green
        case "failed", "error": .red
        case "running", "implementing": .blue
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(run.executor, systemImage: "gearshape.2")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(run.status.replacingOccurrences(of: "_", with: " "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !run.command.isEmpty {
                Text(run.command.joined(separator: " "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            if !run.artifacts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.artifacts, id: \.self) { artifact in
                        Text(artifact)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Card Container

private struct CardContainer<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Status Chip

private enum StatusCategory {
    case requirement, execution, decision
}

private struct StatusChip: View {
    let text: String
    let category: StatusCategory

    private var chipColor: Color {
        switch category {
        case .requirement:
            switch text {
            case "approved": return .green
            case "specified": return .teal
            case "discussed": return .blue
            case "clarifying": return .orange
            default: return .secondary
            }
        case .execution:
            switch text {
            case "passed": return .green
            case "implemented", "human_testing": return .teal
            case "implementing", "queued": return .blue
            case "failed": return .red
            case "paused": return .orange
            default: return .secondary
            }
        case .decision:
            switch text {
            case "archived": return .secondary
            case "needs_feedback": return .orange
            case "blocked": return .red
            case "pending_implementation": return .blue
            default: return .secondary
            }
        }
    }

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(chipColor)
            .background(chipColor.opacity(0.12), in: Capsule())
    }
}

// MARK: - Chat View

struct ChatView: View {
    @ObservedObject var model: AppModel
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if model.chatMessages.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.tertiary)
                                Text("What are you thinking about?")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                                Text("Describe what you want to build, fix, or change.")
                                    .font(.subheadline)
                                    .foregroundStyle(.tertiary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }
                        ForEach(model.chatMessages) { message in
                            ChatBubble(message: message, model: model)
                                .id(message.id)
                                .transition(.opacity)
                        }
                        if model.isAgentWorking || model.isChatStreaming {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color(.systemGray3))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .id("working")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: model.chatMessages.count) { _ in
                    withAnimation {
                        if let last = model.chatMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input bar
            chatInputBar
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var chatInputBar: some View {
        let bar = HStack(spacing: 8) {
            TextField("What's on your mind?", text: $inputText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .onSubmit { sendMessage() }

            if model.isChatStreaming || model.isAgentWorking {
                Button {
                    Task {
                        await model.cancelChat()
                        inputText = model.lastSentMessage
                        model.lastSentMessage = ""
                    }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
            } else {
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                }
                .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)

        if #available(iOS 26.0, *) {
            bar.glassEffect(in: .rect(cornerRadius: 22))
        } else {
            bar.background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        Task {
            await model.sendChatMessage(text)
        }
    }
}

private struct ProjectPickerPill: View {
    @ObservedObject var model: AppModel

    private var currentSession: ChatSessionSummary? {
        guard let sid = model.selectedChatSessionID else { return nil }
        return model.chatSessions.first { $0.sessionId == sid }
    }

    private var displayLabel: String {
        if model.isChatStreaming { return "Thinking…" }
        if let path = model.defaultProjectPath {
            return model.projects.first { $0.path == path }?.name
                ?? (path as NSString).lastPathComponent
        }
        return "Offload"
    }

    var body: some View {
        if model.isChatStreaming {
            // Streaming state — non-interactive pill
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Thinking…")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.orange.opacity(0.15), in: Capsule())
            .foregroundStyle(.orange)
        } else {
            // Project picker menu
            Menu {
                Button {
                    // No project — keep as free chat or do nothing if already free
                } label: {
                    Label("No Project", systemImage: "bubble.left")
                }

                Divider()

                ForEach(model.projects.filter { $0.isInitialized }) { project in
                    Button {
                        Task { await model.createChatSession(project: project.path) }
                    } label: {
                        Label(project.name, systemImage: "folder.fill")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if currentSession?.project != nil {
                        Image(systemName: "folder.fill")
                            .font(.caption)
                    }
                    Text(displayLabel)
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color(.systemGray5), in: Capsule())
                .foregroundStyle(.primary)
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    @ObservedObject var model: AppModel

    var body: some View {
        switch message.role {
        case "tool":
            ToolCallLine(content: message.content)
                .padding(.horizontal, 16)

        case "terminal":
            InlineTerminalView(content: message.content)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

        case "system":
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

        case "user":
            HStack {
                Spacer(minLength: 48)
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 4)

        default:
            // Assistant — plain text, generous spacing
            if let card = message.card {
                ChatCardView(card: card, model: model)
                    .padding(.horizontal, 14)
            } else {
                MarkdownContentView(text: message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Inline Terminal View

private class InlineTerminalCoordinator: NSObject, WKScriptMessageHandler {
    var onHeight: ((CGFloat) -> Void)?

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let height = body["height"] as? CGFloat {
            DispatchQueue.main.async { self.onHeight?(height) }
        }
    }
}

private struct InlineTerminalView: View {
    let content: String
    @State private var contentHeight: CGFloat = 60

    var body: some View {
        InlineTerminalWebView(content: content, height: $contentHeight)
            .frame(height: min(contentHeight, 400))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InlineTerminalWebView: UIViewRepresentable {
    let content: String
    @Binding var height: CGFloat

    func makeCoordinator() -> InlineTerminalCoordinator {
        let coord = InlineTerminalCoordinator()
        coord.onHeight = { h in height = h }
        return coord
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(
            WeakScriptMessageHandler(context.coordinator), name: "terminalSize"
        )
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false

        if let htmlURL = Bundle.main.url(forResource: "terminalInline", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        // Write content after page loads — use base64 to safely pass ANSI codes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let data = content.data(using: .utf8) {
                let b64 = data.base64EncodedString()
                webView.evaluateJavaScript("writeBase64('\(b64)');", completionHandler: nil)
            }
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: InlineTerminalCoordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalSize")
    }
}

// MARK: - Tool Call Block

private struct ToolCallLine: View {
    let content: String
    @State private var isExpanded = false

    // Parse "ToolName rest" or "$ command" from the first line
    private var toolName: String {
        let first = content.components(separatedBy: "\n").first ?? content
        if first.hasPrefix("$ ") { return "Bash" }
        // "Read /path", "Edit /path", "Write /path", "Grep ...", "Glob ..."
        let parts = first.split(separator: " ", maxSplits: 1)
        if let name = parts.first { return String(name) }
        return "Tool"
    }

    private var toolDetail: String {
        let first = content.components(separatedBy: "\n").first ?? content
        if first.hasPrefix("$ ") { return String(first.dropFirst(2)) }
        let parts = first.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    private var hasResult: Bool { content.contains("\n") }

    private var resultText: String {
        let lines = content.components(separatedBy: "\n")
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resultLines: [String] {
        let lines = content.components(separatedBy: "\n")
        return Array(lines.dropFirst())
    }

    private func lineColor(_ line: String) -> Color {
        if line.hasPrefix("+ ") { return .green }
        if line.hasPrefix("- ") { return .red }
        return Color(.tertiaryLabel)
    }

    private var accentColor: Color {
        switch toolName {
        case "Bash": return .orange
        case "Read": return .blue
        case "Edit": return .yellow
        case "Write": return .green
        case "Grep", "Glob": return .purple
        case "Agent": return .cyan
        default: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 1)
                .fill(accentColor.opacity(0.5))
                .frame(width: 2)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                // Header: tool name + detail
                HStack(spacing: 6) {
                    Text(toolName)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(accentColor)
                    Text(toolDetail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Color(.secondaryLabel))
                        .lineLimit(1)
                    Spacer()
                    if hasResult {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                }

                // Expandable output
                if isExpanded && hasResult {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(resultLines.prefix(16).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(lineColor(line))
                                .lineLimit(1)
                        }
                        if resultLines.count > 16 {
                            Text("... \(resultLines.count - 16) more lines")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color(.quaternaryLabel))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if hasResult {
                withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
            }
        }
    }
}

// MARK: - Markdown Rendering

private struct MarkdownContentView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    CodeBlockView(language: lang, code: code)
                case .text(let content):
                    if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(inlineMarkdown(content))
                            .font(.body)
                    }
                }
            }
        }
    }

    // Parse text into code blocks and regular text blocks
    private func parseBlocks(_ input: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                // Flush text buffer
                if !textBuffer.isEmpty {
                    blocks.append(.text(textBuffer.joined(separator: "\n")))
                    textBuffer = []
                }
                // Extract language hint
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang.isEmpty ? nil : lang, codeLines.joined(separator: "\n")))
                i += 1 // skip closing ```
            } else {
                textBuffer.append(line)
                i += 1
            }
        }
        if !textBuffer.isEmpty {
            blocks.append(.text(textBuffer.joined(separator: "\n")))
        }
        return blocks
    }

    // Convert inline markdown to AttributedString
    private func inlineMarkdown(_ text: String) -> AttributedString {
        // Use iOS built-in markdown parsing
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}

private enum MarkdownBlock {
    case text(String)
    case code(String?, String)  // (language, code)
}

private struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label + copy button
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(.systemGray5))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
            }
        }
        .background(Color(.systemGray5).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ChatCardView: View {
    let card: ChatCard
    @ObservedObject var model: AppModel
    @State private var selectedOption: String?
    @State private var noteText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title)
                .font(.headline)

            if !card.prompt.isEmpty {
                Text(card.prompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !card.options.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(card.options, id: \.self) { option in
                        Button(action: { selectedOption = option }) {
                            Text(option)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    selectedOption == option ? Color.orange.opacity(0.3) : Color(.systemGray5),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedOption != nil {
                    Button("Send") {
                        Task {
                            await model.respondToChatCard(
                                card: card,
                                selectedOptions: [selectedOption].compactMap { $0 },
                                note: noteText
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Terminal

struct TerminalView: View {
    @ObservedObject var model: AppModel
    var projectPath: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TerminalWebView(model: model, projectPath: projectPath)
            .ignoresSafeArea(.all, edges: .bottom)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
}

/// Weak wrapper to avoid WKWebView retain cycle on script message handlers.
private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(c, didReceive: message)
    }
}

struct TerminalWebView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    var projectPath: String?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "terminalEvent")
        // Allow inline media playback
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.118, green: 0.118, blue: 0.118, alpha: 1) // #1e1e1e
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false

        context.coordinator.webView = webView

        // Load terminal.html from bundle
        if let htmlURL = Bundle.main.url(forResource: "terminal", withExtension: "html") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        // Build the WebSocket URL for pty
        context.coordinator.buildAndConnect(model: model, projectPath: projectPath)

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "terminalEvent")
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        private var didConnect = false

        func buildAndConnect(model: AppModel, projectPath: String?) {
            // Wait for page load, then call connectPTY
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connect(model: model, projectPath: projectPath)
            }
        }

        private func connect(model: AppModel, projectPath: String?) {
            guard let webView = webView else { return }
            guard !didConnect else { return }

            // Build WebSocket URL from server base URL
            let baseURL = model.serverURLString.trimmingCharacters(in: .whitespaces)
            guard !baseURL.isEmpty else { return }

            var wsBase = baseURL
            if wsBase.hasPrefix("http://") {
                wsBase = "ws://" + wsBase.dropFirst(7)
            } else if wsBase.hasPrefix("https://") {
                wsBase = "wss://" + wsBase.dropFirst(8)
            } else {
                wsBase = "ws://" + wsBase
            }
            // Remove trailing slash
            if wsBase.hasSuffix("/") { wsBase = String(wsBase.dropLast()) }

            var ptyURL = "\(wsBase)/pty"
            var params: [String] = []
            if let path = projectPath, !path.isEmpty {
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
                params.append("cwd=\(encoded)")
            }
            if !model.apiToken.isEmpty {
                let encoded = model.apiToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model.apiToken
                params.append("token=\(encoded)")
            }
            if !params.isEmpty {
                ptyURL += "?" + params.joined(separator: "&")
            }

            // JSON-encode the URL to prevent JS injection
            if let jsonData = try? JSONSerialization.data(withJSONObject: ptyURL),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                let js = "connectPTY(\(jsonStr));"
                webView.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        print("Terminal connect error: \(error)")
                    }
                }
            }
            didConnect = true
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                print("Terminal ready")
            case "closed":
                print("Terminal connection closed")
            default:
                break
            }
        }
    }
}
