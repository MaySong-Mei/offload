import SwiftUI

// MARK: - Root (3-column NavigationSplitView)

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var showingNewTopicSheet = false
    @State private var showingSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectsView(model: model, showingSettings: $showingSettings)
        } content: {
            if model.selectedProjectKey != nil {
                ProjectDashboardView(model: model, showingNewTopicSheet: $showingNewTopicSheet)
            } else {
                ContentUnavailableView {
                    Label("Choose a Project", systemImage: "folder")
                } description: {
                    Text("Select a project from the sidebar to see its topics.")
                }
            }
        } detail: {
            if let detail = model.selectedTopicDetail {
                TopicDetailView(model: model, detail: detail)
            } else {
                ContentUnavailableView {
                    Label("No Topic Selected", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Choose a topic from the list or create a new one.")
                }
            }
        }
        .sheet(isPresented: $showingNewTopicSheet) {
            NewTopicSheet(model: model, parentTopic: nil)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model)
        }
        .task {
            model.bootstrap()
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
                    Label("\(topicCount)", systemImage: "doc.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

    // --- Outer loop: items needing human action ---

    private var needsRequirementApproval: [TopicSummary] {
        topics.filter { $0.requirementState == .specified && $0.requirementApprovedAt == nil }
    }

    private var needsPlanApproval: [TopicSummary] {
        topics.filter { $0.requirementApprovedAt != nil && $0.planApprovedAt == nil && $0.executionState == .idle }
    }

    private var needsHumanTesting: [TopicSummary] {
        topics.filter { $0.executionState == .humanTesting }
    }

    private var failedTopics: [TopicSummary] {
        topics.filter { $0.executionState == .failed }
    }

    private var pendingFeedback: [FeedbackRequestModel] {
        let topicIds = Set(topics.map(\.topicId))
        return model.feedbackQueue.filter { topicIds.contains($0.topicId) }
    }

    private var actionRequiredCount: Int {
        needsRequirementApproval.count + needsPlanApproval.count + needsHumanTesting.count + failedTopics.count + pendingFeedback.count
    }

    // --- Inner loop: agent activity ---

    private var implementingTopics: [TopicSummary] {
        topics.filter { $0.executionState == .implementing || $0.executionState == .queued }
    }

    private var recentlyCompleted: [TopicSummary] {
        topics.filter { $0.executionState == .implemented || $0.executionState == .passed }
    }

    // --- Pipeline ---

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
        List(selection: Binding(
            get: { model.selectedTopicID },
            set: { model.selectTopic($0) }
        )) {
            // Meta Card → taps through to project detail
            if let activity = model.projectActivity {
                Section {
                    NavigationLink {
                        ProjectDetailView(model: model, activity: activity, readmeContent: readmeContent)
                    } label: {
                        ProjectMetaCard(activity: activity)
                    }
                }
            }

            // Recent Agent Changes
            if let activity = model.projectActivity, !activity.recentRuns.isEmpty {
                Section {
                    recentChangesSection(runs: activity.recentRuns, commits: activity.recentCommits)
                } header: {
                    Label("Recent Changes", systemImage: "clock.arrow.circlepath")
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

            // Section 1: Action Required
            if actionRequiredCount > 0 {
                Section {
                    actionRequiredSection
                } header: {
                    Label("Action Required (\(actionRequiredCount))", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }

            // Section 2: Agent Activity
            if !implementingTopics.isEmpty || !recentlyCompleted.isEmpty {
                Section {
                    agentActivitySection
                } header: {
                    Label("Agent Activity", systemImage: "cpu")
                }
            }

            // Section 3: Topics Pipeline
            Section {
                pipelineSection
            } header: {
                Label("Pipeline", systemImage: "chart.bar")
            }

            // Section 4: All Topics
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
                        TopicRow(topic: topic)
                            .tag(topic.topicId)
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

    // MARK: Section 1 — Action Required

    @ViewBuilder
    private var actionRequiredSection: some View {
        ForEach(pendingFeedback) { fb in
            ActionCard(
                icon: "bubble.left.fill",
                color: .orange,
                title: fb.title,
                subtitle: "Feedback requested for topic"
            ) {
                model.selectTopic(fb.topicId)
            }
        }
        ForEach(needsRequirementApproval) { topic in
            ActionCard(
                icon: "checkmark.circle",
                color: .blue,
                title: topic.title,
                subtitle: "Requirement ready for approval"
            ) {
                model.selectTopic(topic.topicId)
            } action: {
                Task { await model.selectAndApproveRequirement(topic.topicId) }
            } actionLabel: {
                Label("Approve", systemImage: "checkmark")
            }
        }
        ForEach(needsPlanApproval) { topic in
            ActionCard(
                icon: "map",
                color: .teal,
                title: topic.title,
                subtitle: "Plan ready for approval"
            ) {
                model.selectTopic(topic.topicId)
            } action: {
                Task { await model.selectAndApprovePlan(topic.topicId) }
            } actionLabel: {
                Label("Approve", systemImage: "checkmark")
            }
        }
        ForEach(needsHumanTesting) { topic in
            ActionCard(
                icon: "person.fill.checkmark",
                color: .purple,
                title: topic.title,
                subtitle: "Ready for human testing"
            ) {
                model.selectTopic(topic.topicId)
            }
        }
        ForEach(failedTopics) { topic in
            ActionCard(
                icon: "xmark.circle.fill",
                color: .red,
                title: topic.title,
                subtitle: "Run failed — needs attention"
            ) {
                model.selectTopic(topic.topicId)
            }
        }
    }

    // MARK: Section 2 — Agent Activity

    @ViewBuilder
    private var agentActivitySection: some View {
        ForEach(implementingTopics) { topic in
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.subheadline.weight(.medium))
                    Text("Agent is working…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(topic.topicId)
        }
        ForEach(recentlyCompleted.prefix(3)) { topic in
            HStack(spacing: 10) {
                Image(systemName: topic.executionState == .passed ? "checkmark.circle.fill" : "hammer.fill")
                    .foregroundStyle(topic.executionState == .passed ? .green : .teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(topic.title)
                        .font(.subheadline.weight(.medium))
                    Text(topic.executionState == .passed ? "Passed" : "Implemented")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tag(topic.topicId)
        }
    }

    // MARK: Section 3 — Pipeline

    private var pipelineSection: some View {
        let active = pipelineCounts.filter { $0.count > 0 }
        return Group {
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
                        Text(Self.relativeTime(date))
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

    // MARK: Section 5 — Project Context

    @ViewBuilder
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
                Label("Topic Stats", systemImage: "chart.bar")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
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

private struct TopicDetailView: View {
    @ObservedObject var model: AppModel
    let detail: TopicDetailResponse
    @State private var refreshNote = ""
    @State private var commandText = "/usr/bin/printf hello-from-ios"
    @State private var showingNewSubtopicSheet = false
    @State private var selectedExecutor = "command"
    @State private var promptText = ""
    @State private var readmeContent: String?
    @State private var loadedReadmeForProject: String?

    private var pendingFeedback: [FeedbackRequestModel] {
        detail.feedbackRequests.filter { $0.status == "pending" }
    }

    private var canArchive: Bool {
        detail.topic.executionState == .passed && detail.topic.decisionState != .archived
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Project README
                if let readme = readmeContent, !readme.isEmpty {
                    readmeSection(content: readme)
                }

                // Feedback (prominent when present)
                if !pendingFeedback.isEmpty {
                    feedbackSection
                }

                // Workflow actions
                actionsSection

                // Run trigger
                runTriggerSection

                // Subtopics
                if !detail.childTopics.isEmpty {
                    subtopicsSection
                }

                // Agent Conversation (streaming)
                agentConversationSection

                // Documents
                documentsSection

                // Run history
                if !detail.runs.isEmpty {
                    runsSection
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(detail.topic.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSubtopicSheet = true
                } label: {
                    Label("New Subtopic", systemImage: "plus.circle")
                }
            }
        }
        .sheet(isPresented: $showingNewSubtopicSheet) {
            NewTopicSheet(model: model, parentTopic: detail.topic)
        }
        .task(id: detail.topic.project) {
            await loadReadmeIfNeeded()
        }
    }

    private func loadReadmeIfNeeded() async {
        guard let project = detail.topic.project, !project.isEmpty else {
            readmeContent = nil
            loadedReadmeForProject = nil
            return
        }
        if loadedReadmeForProject == project { return }
        loadedReadmeForProject = project
        readmeContent = await model.fetchReadme(projectPath: project)
    }

    @ViewBuilder
    private func readmeSection(content: String) -> some View {
        DisclosureGroup {
            ReadmeView(content: content)
                .padding(.top, 8)
        } label: {
            Label("README", systemImage: "doc.text.fill")
                .font(.headline)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail.topic.title)
                .font(.title.weight(.bold))

            if !detail.topic.summary.isEmpty {
                Text(detail.topic.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                StatusChip(text: detail.topic.requirementState.rawValue, category: .requirement)
                StatusChip(text: detail.topic.executionState.rawValue, category: .execution)
                if detail.topic.decisionState != .none {
                    StatusChip(text: detail.topic.decisionState.rawValue, category: .decision)
                }
            }

            if let project = detail.topic.project, !project.isEmpty {
                Label(project, systemImage: "folder.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !detail.topic.workspacePath.isEmpty {
                Label(detail.topic.workspacePath, systemImage: "externaldrive")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let parentTopic = detail.parentTopic {
                Button {
                    model.selectTopic(parentTopic.topicId)
                } label: {
                    Label(parentTopic.title, systemImage: "arrow.turn.up.left")
                        .font(.subheadline)
                }
                .tint(.secondary)
            }
        }
    }

    // MARK: Feedback

    private var feedbackSection: some View {
        CardContainer {
            Label("Pending Feedback", systemImage: "bell.badge.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            ForEach(pendingFeedback) { request in
                FeedbackRequestCard(model: model, request: request)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: Workflow Actions

    private var actionsSection: some View {
        CardContainer {
            Label("Workflow", systemImage: "arrow.triangle.branch")
                .font(.headline)

            // Requirement stage
            VStack(alignment: .leading, spacing: 8) {
                Text("Requirement")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ActionButton("Approve", icon: "checkmark.circle", style: .primary) {
                        await model.approveRequirement()
                    }
                    ActionButton("Refresh", icon: "arrow.clockwise", style: .secondary) {
                        await model.refreshRequirement(note: refreshNote)
                    }
                }

                TextField("Clarification note…", text: $refreshNote)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
            }

            Divider()

            // Plan stage
            VStack(alignment: .leading, spacing: 8) {
                Text("Plan")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ActionButton("Approve", icon: "checkmark.circle", style: .primary) {
                        await model.approvePlan()
                    }
                    ActionButton("Refresh", icon: "arrow.clockwise", style: .secondary) {
                        await model.refreshPlan()
                    }
                }
            }

            Divider()

            // Testing stage
            VStack(alignment: .leading, spacing: 8) {
                Text("Testing")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ActionButton("Start Testing", icon: "person.fill.checkmark", style: .secondary) {
                        await model.markHumanTesting()
                    }
                    ActionButton("Confirm Passed", icon: "checkmark.seal", style: .primary) {
                        await model.markPassed()
                    }
                }
            }

            if canArchive {
                Divider()
                ActionButton("Archive Topic", icon: "archivebox", style: .primary) {
                    await model.archiveTopic()
                }
            }
        }
    }

    // MARK: Run / Agent Launch

    private var runTriggerSection: some View {
        CardContainer {
            Label("Launch Run", systemImage: "terminal")
                .font(.headline)

            Picker("Executor", selection: $selectedExecutor) {
                Text("Command").tag("command")
                Text("Claude Agent").tag("claude")
            }
            .pickerStyle(.segmented)

            if selectedExecutor == "command" {
                HStack(spacing: 8) {
                    TextField("Command", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())

                    Button {
                        Task { await model.triggerRun(executor: "command", commandText: commandText) }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.body)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The agent will use the topic's requirement and plan as context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("Additional instructions (optional)", text: $promptText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                        .lineLimit(3...6)

                    if let project = detail.topic.project, !project.isEmpty {
                        Label("Will run in: \(project)", systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await model.triggerRun(executor: "claude", commandText: promptText) }
                    } label: {
                        Label("Launch Agent", systemImage: "cpu")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: Subtopics

    private var subtopicsSection: some View {
        CardContainer {
            Label("Subtopics", systemImage: "list.bullet.indent")
                .font(.headline)

            ForEach(detail.childTopics) { child in
                Button {
                    model.selectTopic(child.topicId)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(child.title)
                                .font(.subheadline.weight(.medium))
                            Text(child.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Agent Conversation

    @ViewBuilder
    private var agentConversationSection: some View {
        let lines = model.agentConversation.filter { $0.topicId == detail.topic.topicId }
        let hasConversation = !lines.isEmpty || detail.documents.keys.contains("conversation.md")

        if hasConversation {
            VStack(alignment: .leading, spacing: 12) {
                Label("Agent Conversation", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.headline)

                // Live stream (if active)
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines.suffix(20)) { line in
                            HStack(alignment: .top, spacing: 6) {
                                if !line.stage.isEmpty {
                                    Text(line.stage)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.teal)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                Text(line.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }

                // Saved conversation document
                if let conv = detail.documents["conversation.md"], !conv.isEmpty {
                    NavigationLink {
                        ScrollView {
                            Text(conv)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle("Conversation Log")
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        Label("View Full Log", systemImage: "doc.text")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    // MARK: Documents

    private var documentsSection: some View {
        VStack(spacing: 12) {
            ForEach([
                (key: "topic.md", title: "Overview", icon: "doc.text"),
                (key: "requirement.md", title: "Requirement", icon: "checklist"),
                (key: "plan.md", title: "Plan", icon: "map"),
                (key: "notes.md", title: "Notes", icon: "note.text"),
            ], id: \.key) { doc in
                let content = detail.documents[doc.key] ?? ""
                if !content.isEmpty {
                    DocumentSection(title: doc.title, icon: doc.icon, bodyText: content)
                }
            }
        }
    }

    // MARK: Runs

    private var runsSection: some View {
        CardContainer {
            Label("Run History", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            ForEach(detail.runs) { run in
                RunCard(run: run)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title)
                .font(.subheadline.weight(.semibold))
            Text(request.prompt)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !request.options.isEmpty {
                Picker("Choice", selection: $selectedOption) {
                    ForEach(request.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onAppear {
                    if selectedOption.isEmpty {
                        selectedOption = request.options.first ?? ""
                    }
                }
            }

            if request.allowNote {
                TextField("Optional note…", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
            }

            Button {
                Task {
                    let selection = selectedOption.isEmpty ? [] : [selectedOption]
                    await model.submitFeedback(requestID: request.requestId, selectedOptions: selection, note: note)
                }
            } label: {
                Label("Send Feedback", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
