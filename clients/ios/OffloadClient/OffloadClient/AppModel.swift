import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "com.offload.client", category: "AppModel")

@MainActor
final class AppModel: ObservableObject {
    // MARK: - Published State

    @Published var serverURLString: String
    @Published var apiToken: String
    @Published var topics: [TopicSummary] = []
    @Published var feedbackQueue: [FeedbackRequestModel] = []
    @Published var selectedTopicID: String?
    @Published var selectedTopicDetail: TopicDetailResponse?
    @Published var isLoading = false
    @Published var statusMessage = "Disconnected"
    @Published var errorMessage: String?
    @Published var isOnline = true
    @Published var pendingOperationCount = 0
    @Published var isSyncing = false
    @Published var projects: [ProjectInfo] = []
    @Published var selectedProjectKey: String? = nil  // path of project, "" for ungrouped, nil for none
    @Published var projectInitLogs: [String: [String]] = [:]
    @Published var projectActivity: ProjectActivityResponse?
    @Published var agentStatuses: [AgentStatusModel] = []
    @Published var isCheckingAgents = false
    @Published var sensors: [SensorModel] = []
    @Published var signals: [SignalModel] = []
    @Published var agentConversation: [AgentStreamEvent] = []

    // Combined list: server-discovered projects + projects referenced by topics + ungrouped slot
    var allProjectGroups: [(key: String, name: String, hasReadme: Bool, topicCount: Int)] {
        var groups: [String: (name: String, hasReadme: Bool, count: Int)] = [:]
        // Start from discovered projects (so empty repos still appear)
        for p in projects {
            groups[p.path] = (p.name, p.hasReadme, 0)
        }
        // Walk topics
        var ungroupedCount = 0
        for t in topics {
            if let proj = t.project, !proj.isEmpty {
                if var existing = groups[proj] {
                    existing.count += 1
                    groups[proj] = existing
                } else {
                    let displayName = (proj as NSString).lastPathComponent
                    groups[proj] = (displayName.isEmpty ? proj : displayName, false, 1)
                }
            } else {
                ungroupedCount += 1
            }
        }
        var result: [(key: String, name: String, hasReadme: Bool, topicCount: Int)] = groups
            .map { (key: $0.key, name: $0.value.name, hasReadme: $0.value.hasReadme, topicCount: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if ungroupedCount > 0 || !topics.isEmpty {
            result.append((key: "", name: "Ungrouped", hasReadme: false, topicCount: ungroupedCount))
        }
        return result
    }

    func topicsForSelectedProject() -> [TopicSummary] {
        guard let key = selectedProjectKey else { return [] }
        if key.isEmpty {
            return topics.filter { ($0.project ?? "").isEmpty }
        }
        return topics.filter { $0.project == key }
    }

    // MARK: - Private

    private let defaults = UserDefaults.standard
    private let localStore: LocalStore
    private var eventTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.offload.network-monitor")
    private let enableNetworkMonitor: Bool

    // MARK: - Init

    init(localStore: LocalStore = .default, enableNetworkMonitor: Bool = true) {
        self.localStore = localStore
        self.enableNetworkMonitor = enableNetworkMonitor
        self.serverURLString = defaults.string(forKey: "offload.serverURL") ?? "http://127.0.0.1:8080"
        self.apiToken = defaults.string(forKey: "offload.apiToken") ?? ""
        if enableNetworkMonitor {
            startNetworkMonitor()
        }
    }

    deinit {
        eventTask?.cancel()
        pathMonitor.cancel()
    }

    // MARK: - Network Monitor

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                if wasOffline && self.isOnline {
                    await self.syncPendingOperations()
                }
                self.updateStatusMessage()
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    private func updateStatusMessage() {
        if !isOnline {
            statusMessage = "Offline"
        }
    }

    // MARK: - Bootstrap & Connect

    func bootstrap() {
        log.info("bootstrap: serverURL=\(self.serverURLString, privacy: .public)")
        Task { await loadFromCache() }
        guard !serverURLString.isEmpty else { return }
        connect()
    }

    func connect() {
        log.info("connect: url=\(self.serverURLString, privacy: .public) tokenPresent=\(!self.apiToken.isEmpty)")
        defaults.set(serverURLString, forKey: "offload.serverURL")
        defaults.set(apiToken, forKey: "offload.apiToken")
        statusMessage = "Connecting…"
        Task {
            await reload()
            if pendingOperationCount > 0 {
                await syncPendingOperations()
            }
            await startEventStream()
        }
    }

    // MARK: - Cache

    private func loadFromCache() async {
        let cachedTopics = await localStore.loadTopics()
        if topics.isEmpty && !cachedTopics.isEmpty {
            topics = cachedTopics
        }
        let cachedFeedback = await localStore.loadFeedbackQueue()
        if feedbackQueue.isEmpty && !cachedFeedback.isEmpty {
            feedbackQueue = cachedFeedback
        }
        if let id = selectedTopicID, selectedTopicDetail == nil {
            if let cached = await localStore.loadTopicDetail(topicID: id) {
                selectedTopicDetail = cached
            }
        }
        pendingOperationCount = await localStore.pendingOperationCount
    }

    // MARK: - Reload

    func reload() async {
        log.info("reload: starting")
        guard let client = makeClient() else {
            log.error("reload: invalid url")
            errorMessage = "Invalid server URL."
            await loadFromCache()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            topics = try await client.fetchTopics()
            log.info("reload: fetched \(self.topics.count) topics")
            feedbackQueue = try await client.fetchFeedbackQueue()
            log.info("reload: fetched \(self.feedbackQueue.count) feedback items")
            if let fetched = try? await client.fetchProjects() {
                projects = fetched
                log.info("reload: fetched \(self.projects.count) projects")
            }

            try? await localStore.saveTopics(topics)
            try? await localStore.saveFeedbackQueue(feedbackQueue)

            // If a topic is already selected, refresh its detail
            if let selectedTopicID, topics.contains(where: { $0.topicId == selectedTopicID }) {
                selectedTopicDetail = try await client.fetchTopicDetail(topicID: selectedTopicID)
                try? await localStore.saveTopicDetail(selectedTopicDetail!, topicID: selectedTopicID)
            }
            statusMessage = "Connected"
            errorMessage = nil
            log.info("reload: success")
        } catch {
            log.error("reload: failed - \(error.localizedDescription, privacy: .public)")
            print("[reload] FAILED: \(error)")
            await loadFromCache()
            if topics.isEmpty {
                errorMessage = error.localizedDescription
            }
            statusMessage = isOnline ? "Connection failed" : "Offline"
        }
    }

    // MARK: - Selection

    func selectTopic(_ topicID: String?) {
        selectedTopicID = topicID
        guard let topicID else {
            selectedTopicDetail = nil
            return
        }
        Task { await refreshTopic(topicID: topicID) }
    }

    private func refreshTopic(topicID: String) async {
        if let client = makeClient() {
            do {
                selectedTopicDetail = try await client.fetchTopicDetail(topicID: topicID)
                try? await localStore.saveTopicDetail(selectedTopicDetail!, topicID: topicID)
                errorMessage = nil
                return
            } catch {
                // fall through to cache
            }
        }
        if let cached = await localStore.loadTopicDetail(topicID: topicID) {
            selectedTopicDetail = cached
        }
    }

    // MARK: - Create Topic

    func createTopic(title: String, rawInput: String, tagsText: String, project: String? = nil, parentTopicID: String? = nil) async {
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if isOnline, let client = makeClient() {
            do {
                let detail: TopicDetailResponse
                if let parentTopicID {
                    detail = try await client.createSubtopic(parentTopicID: parentTopicID, title: title, rawInput: rawInput, tags: tags, project: project)
                } else {
                    detail = try await client.createTopic(title: title, rawInput: rawInput, tags: tags, project: project)
                }
                selectedTopicID = detail.topic.topicId
                selectedTopicDetail = detail
                await reload()
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        // Offline: queue + create local draft
        let op = PendingOperation(action: .createTopic(title: title, rawInput: rawInput, tags: tags, project: project, parentTopicId: parentTopicID))
        await enqueueOffline(op)

        let now = ISO8601DateFormatter().string(from: Date())
        let localTopic = TopicSummary(
            topicId: "local-\(op.id.uuidString)",
            title: title.isEmpty ? "Untitled" : title,
            summary: String(rawInput.prefix(200)),
            rawInput: rawInput,
            parentTopicId: parentTopicID,
            tags: tags,
            priority: "normal",
            project: project,
            createdAt: now,
            updatedAt: now,
            requirementState: .captured,
            executionState: .idle,
            decisionState: .none,
            requirementApprovedAt: nil,
            planApprovedAt: nil,
            latestRunId: nil,
            pendingFeedbackRequestId: nil,
            assignedExecutor: nil,
            workspacePath: ""
        )
        topics.append(localTopic)
        try? await localStore.saveTopics(topics)

        let localDetail = TopicDetailResponse(
            topic: localTopic,
            parentTopic: nil,
            childTopics: [],
            documents: [:],
            feedbackRequests: [],
            runs: [],
            artifacts: []
        )
        selectedTopicID = localTopic.topicId
        selectedTopicDetail = localDetail
        try? await localStore.saveTopicDetail(localDetail, topicID: localTopic.topicId)
    }

    // MARK: - Mutations (online or queued)

    func selectAndApproveRequirement(_ topicID: String) async {
        selectedTopicID = topicID
        await performAction(.approveRequirement(topicId: topicID)) { client in
            try await client.approveRequirement(topicID: topicID)
        }
    }

    func selectAndApprovePlan(_ topicID: String) async {
        selectedTopicID = topicID
        await performAction(.approvePlan(topicId: topicID)) { client in
            try await client.approvePlan(topicID: topicID)
        }
    }

    func approveRequirement() async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.approveRequirement(topicId: topicID)) { client in
            try await client.approveRequirement(topicID: topicID)
        }
    }

    func approvePlan() async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.approvePlan(topicId: topicID)) { client in
            try await client.approvePlan(topicID: topicID)
        }
    }

    func refreshRequirement(note: String) async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.refreshRequirement(topicId: topicID, note: note)) { client in
            try await client.refreshRequirement(topicID: topicID, note: note)
        }
    }

    func refreshPlan(note: String = "") async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.refreshPlan(topicId: topicID)) { client in
            try await client.refreshPlan(topicID: topicID, note: note)
        }
    }

    func submitFeedback(requestID: String, selectedOptions: [String], note: String) async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.submitFeedback(topicId: topicID, requestId: requestID, selectedOptions: selectedOptions, note: note)) { client in
            try await client.submitFeedback(topicID: topicID, requestID: requestID, selectedOptions: selectedOptions, note: note)
        }
    }

    func markHumanTesting() async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.markHumanTesting(topicId: topicID)) { client in
            try await client.markHumanTesting(topicID: topicID)
        }
    }

    func markPassed() async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.markPassed(topicId: topicID)) { client in
            try await client.markPassed(topicID: topicID)
        }
    }

    func archiveTopic() async {
        guard let topicID = selectedTopicID else { return }
        await performAction(.archiveTopic(topicId: topicID)) { client in
            try await client.archiveTopic(topicID: topicID)
        }
    }

    func triggerRun(executor: String, commandText: String) async {
        guard let topicID = selectedTopicID else { return }
        let command = commandText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        if isOnline, let client = makeClient() {
            do {
                _ = try await client.triggerRun(topicID: topicID, executor: executor, command: command)
                await refreshTopic(topicID: topicID)
                await reload()
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        await enqueueOffline(PendingOperation(action: .triggerRun(topicId: topicID, executor: executor, command: command)))
    }

    // MARK: - Sync

    func syncPendingOperations() async {
        guard !isSyncing, isOnline, let client = makeClient() else { return }
        isSyncing = true
        defer { isSyncing = false }

        var operations = await localStore.loadPendingOperations()
        guard !operations.isEmpty else { return }

        while let op = operations.first {
            do {
                try await executeOperation(op, with: client)
                operations.removeFirst()
            } catch {
                errorMessage = "Sync error: \(error.localizedDescription)"
                break
            }
        }

        try? await localStore.savePendingOperations(operations)
        pendingOperationCount = operations.count
        await reload()
    }

    // MARK: - Helpers

    private func performAction(_ action: OperationAction, online: (APIClient) async throws -> TopicDetailResponse) async {
        if isOnline, let client = makeClient() {
            do {
                selectedTopicDetail = try await online(client)
                if let topicID = selectedTopicID {
                    try? await localStore.saveTopicDetail(selectedTopicDetail!, topicID: topicID)
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            await enqueueOffline(PendingOperation(action: action))
        }
    }

    private func enqueueOffline(_ op: PendingOperation) async {
        do {
            try await localStore.enqueueOperation(op)
            pendingOperationCount = await localStore.pendingOperationCount
            statusMessage = "Queued offline"
        } catch {
            errorMessage = "Failed to save offline: \(error.localizedDescription)"
        }
    }

    private func executeOperation(_ op: PendingOperation, with client: APIClient) async throws {
        switch op.action {
        case let .createTopic(title, rawInput, tags, project, parentTopicId):
            if let parentTopicId {
                _ = try await client.createSubtopic(parentTopicID: parentTopicId, title: title, rawInput: rawInput, tags: tags, project: project)
            } else {
                _ = try await client.createTopic(title: title, rawInput: rawInput, tags: tags, project: project)
            }
        case let .approveRequirement(topicId):
            _ = try await client.approveRequirement(topicID: topicId)
        case let .approvePlan(topicId):
            _ = try await client.approvePlan(topicID: topicId)
        case let .refreshRequirement(topicId, note):
            _ = try await client.refreshRequirement(topicID: topicId, note: note)
        case let .refreshPlan(topicId):
            _ = try await client.refreshPlan(topicID: topicId)
        case let .submitFeedback(topicId, requestId, selectedOptions, note):
            _ = try await client.submitFeedback(topicID: topicId, requestID: requestId, selectedOptions: selectedOptions, note: note)
        case let .triggerRun(topicId, executor, command):
            _ = try await client.triggerRun(topicID: topicId, executor: executor, command: command)
        case let .markHumanTesting(topicId):
            _ = try await client.markHumanTesting(topicID: topicId)
        case let .markPassed(topicId):
            _ = try await client.markPassed(topicID: topicId)
        case let .archiveTopic(topicId):
            _ = try await client.archiveTopic(topicID: topicId)
        }
    }

    func fetchActivity(projectPath: String) async {
        guard let client = makeClient() else { return }
        do {
            projectActivity = try await client.fetchProjectActivity(projectPath: projectPath)
        } catch {
            print("[Activity] fetch failed for \(projectPath): \(error)")
        }
    }

    func fetchAgentStatuses() async {
        guard let client = makeClient() else { return }
        isCheckingAgents = true
        do {
            agentStatuses = try await client.fetchAgentStatus()
        } catch {
            print("[Agents] fetch failed: \(error)")
        }
        isCheckingAgents = false
    }

    func fetchSensorsAndSignals(projectPath: String) async {
        guard let client = makeClient() else { return }
        sensors = (try? await client.fetchSensors(project: projectPath)) ?? []
        signals = (try? await client.fetchSignals(project: projectPath)) ?? []
    }

    func constructSensor(project: String, description: String) async -> TopicDetailResponse? {
        guard let client = makeClient() else { return nil }
        return try? await client.constructSensor(project: project, description: description)
    }

    func fetchReadme(projectPath: String) async -> String? {
        guard let client = makeClient() else { return nil }
        return try? await client.fetchReadme(projectPath: projectPath)
    }

    func cancelInit(_ project: ProjectInfo) async {
        guard let client = makeClient() else { return }
        do {
            try await client.cancelInit(projectPath: project.path)
            let fresh = try await client.fetchProjects()
            projects = fresh
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninitializeProject(_ project: ProjectInfo) async {
        guard let client = makeClient() else { return }
        do {
            // Server does the deletion; only update UI after server confirms success.
            try await client.uninitializeProject(projectPath: project.path)
            // Reload from server — the real state after deletion.
            let fresh = try await client.fetchProjects()
            projects = fresh
            projectInitLogs.removeValue(forKey: project.path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func initializeProject(_ project: ProjectInfo) async {
        guard let client = makeClient() else { return }
        do {
            try await client.initializeProject(projectPath: project.path)
            // Reload once to get the authoritative "initializing" status.
            // From here, WebSocket events drive UI updates (no polling).
            if let fresh = try? await client.fetchProjects() {
                projects = fresh
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeClient() -> APIClient? {
        guard let url = URL(string: serverURLString) else { return nil }
        return APIClient(baseURL: url, token: apiToken)
    }

    private func startEventStream() async {
        eventTask?.cancel()
        guard let client = makeClient() else { return }
        eventTask = Task {
            do {
                let stream = try makeEventStream(using: client)
                for try await event in stream {
                    if Task.isCancelled { break }
                    if event.eventType == "heartbeat" || event.eventType == "hello" {
                        continue
                    }
                    // Run/topic events → targeted partial refresh (not full reload)
                    if event.eventType == "run.finished" || event.eventType == "run.started" || event.eventType == "topic.updated" {
                        let affectedTopicId = event.payload?["topic_id"]?.value
                            ?? event.topicId

                        // 1. Refresh only the affected topic if it's currently selected
                        if let tid = affectedTopicId, tid == self.selectedTopicID {
                            await self.refreshTopic(topicID: tid)
                        }

                        // 2. Refresh topics list (lightweight — just summaries)
                        if let client = self.makeClient() {
                            if let fresh = try? await client.fetchTopics() {
                                self.topics = fresh
                            }
                            if let fresh = try? await client.fetchFeedbackQueue() {
                                self.feedbackQueue = fresh
                            }
                        }

                        // 3. Refresh activity only for the current project dashboard
                        if event.eventType == "run.finished" {
                            if let key = self.selectedProjectKey, !key.isEmpty {
                                await self.fetchActivity(projectPath: key)
                            }
                        }
                        continue
                    }
                    // Agent streaming output → append structured event to conversation
                    if event.eventType == "agent.stream" {
                        if let tid = event.topicId {
                            let p = event.payload
                            let streamEvent = AgentStreamEvent(
                                topicId: tid,
                                stage: p?["stage"]?.value ?? "",
                                claudeEventType: p?["claude_event_type"]?.value ?? "",
                                text: p?["text"]?.value,
                                toolName: p?["tool_name"]?.value,
                                toolInput: p?["tool_input"]?.value,
                                toolResult: p?["tool_result"]?.value,
                                result: p?["result"]?.value
                            )
                            self.agentConversation.append(streamEvent)
                            if self.agentConversation.count > 500 {
                                self.agentConversation.removeFirst(self.agentConversation.count - 500)
                            }
                        }
                        continue
                    }
                    // Feedback requested → refresh topic if it's selected
                    if event.eventType == "feedback.requested" {
                        if let tid = event.topicId, tid == self.selectedTopicID {
                            await self.refreshTopic(topicID: tid)
                        }
                        if let client = self.makeClient() {
                            if let fresh = try? await client.fetchFeedbackQueue() {
                                self.feedbackQueue = fresh
                            }
                        }
                        continue
                    }
                    // Handle init events without full reload
                    if event.eventType == "project.init.log" {
                        if let path = event.payload?["project_path"]?.value,
                           let line = event.payload?["line"]?.value {
                            var lines = self.projectInitLogs[path] ?? []
                            lines.append(line)
                            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                            self.projectInitLogs[path] = lines
                        }
                        continue
                    }
                    if event.eventType == "project.init.status" {
                        // Status changed — reload projects from server
                        if let client = self.makeClient(),
                           let fresh = try? await client.fetchProjects() {
                            self.projects = fresh
                        }
                        continue
                    }
                    await reload()
                }
            } catch {
                statusMessage = "Realtime updates offline"
            }
        }
    }

    private func makeEventStream(using client: APIClient) throws -> AsyncThrowingStream<EventEnvelope, Error> {
        let request = try client.eventRequest()
        let task = URLSession.shared.webSocketTask(with: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return AsyncThrowingStream { continuation in
            task.resume()

            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        switch message {
                        case let .string(text):
                            let event = try decoder.decode(EventEnvelope.self, from: Data(text.utf8))
                            continuation.yield(event)
                        case let .data(data):
                            let event = try decoder.decode(EventEnvelope.self, from: data)
                            continuation.yield(event)
                        @unknown default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                receiveTask.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
