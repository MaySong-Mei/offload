import Foundation
import OSLog

private let log = Logger(subsystem: "com.offload.client", category: "APIClient")

struct APIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct APIClient {
    let baseURL: URL
    let token: String

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private var session: URLSession { .shared }

    func fetchTopics() async throws -> [TopicSummary] {
        try await send("/topics", response: TopicListResponse.self).topics
    }

    func fetchTopicDetail(topicID: String) async throws -> TopicDetailResponse {
        try await send("/topics/\(topicID)", response: TopicDetailResponse.self)
    }

    func fetchFeedbackQueue() async throws -> [FeedbackRequestModel] {
        try await send("/feedback-queue", response: FeedbackQueueResponse.self).feedbackRequests
    }

    func fetchProjects() async throws -> [ProjectInfo] {
        try await send("/projects", response: ProjectListResponse.self).projects
    }

    func fetchReadme(projectPath: String) async throws -> String {
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        return try await send("/projects/readme?path=\(encoded)", response: ReadmeResponse.self).content
    }

    func fetchProjectActivity(projectPath: String) async throws -> ProjectActivityResponse {
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        return try await send("/projects/activity?path=\(encoded)", response: ProjectActivityResponse.self)
    }

    func fetchSensors(project: String) async throws -> [SensorModel] {
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? project
        return try await send("/sensors?project=\(encoded)", response: SensorListResponse.self).sensors
    }

    func fetchSignals(project: String, limit: Int = 30) async throws -> [SignalModel] {
        let encoded = project.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? project
        return try await send("/signals?project=\(encoded)&limit=\(limit)", response: SignalListResponse.self).signals
    }

    func constructSensor(project: String, description: String) async throws -> TopicDetailResponse {
        struct Body: Codable { let project: String; let description: String }
        return try await send(
            "/sensors/construct",
            method: "POST",
            body: Body(project: project, description: description),
            response: TopicDetailResponse.self
        )
    }

    func fetchArchitectureTree(projectPath: String) async throws -> ArchNode {
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        return try await send("/projects/architecture?path=\(encoded)", response: ArchTreeResponse.self).tree
    }

    func fetchFiles(projectPath: String, rel: String = "") async throws -> FileListResponse {
        let encodedPath = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        let encodedRel = rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel
        return try await send("/projects/files?path=\(encodedPath)&rel=\(encodedRel)", response: FileListResponse.self)
    }

    func fetchFileContent(projectPath: String, rel: String) async throws -> FileContentResponse {
        let encodedPath = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        let encodedRel = rel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rel
        return try await send("/projects/file-content?path=\(encodedPath)&rel=\(encodedRel)", response: FileContentResponse.self)
    }

    func fetchAgentStatus() async throws -> [AgentStatusModel] {
        try await send("/agents/status", response: AgentStatusResponse.self).agents
    }

    func fetchInitLog(projectPath: String) async throws -> InitLogResponse {
        let encoded = projectPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? projectPath
        return try await send("/projects/init-log?path=\(encoded)", response: InitLogResponse.self)
    }

    func initializeProject(projectPath: String) async throws {
        struct Body: Codable { let path: String }
        struct Resp: Codable { let status: String }
        _ = try await send(
            "/projects/initialize",
            method: "POST",
            body: Body(path: projectPath),
            response: Resp.self
        )
    }

    func cancelInit(projectPath: String) async throws {
        struct Body: Codable { let path: String }
        struct Resp: Codable { let status: String }
        _ = try await send(
            "/projects/cancel-init",
            method: "POST",
            body: Body(path: projectPath),
            response: Resp.self
        )
    }

    func uninitializeProject(projectPath: String) async throws {
        struct Body: Codable { let path: String }
        struct Resp: Codable { let status: String }
        _ = try await send(
            "/projects/uninitialize",
            method: "POST",
            body: Body(path: projectPath),
            response: Resp.self
        )
    }

    func createTopic(title: String, rawInput: String, tags: [String], project: String? = nil, parentTopicID: String? = nil) async throws -> TopicDetailResponse {
        try await send(
            "/topics",
            method: "POST",
            body: TopicCreateRequest(title: title, rawInput: rawInput, tags: tags, parentTopicId: parentTopicID, project: project),
            response: TopicDetailResponse.self
        )
    }

    func createSubtopic(parentTopicID: String, title: String, rawInput: String, tags: [String], project: String? = nil) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(parentTopicID)/subtopics",
            method: "POST",
            body: TopicCreateRequest(title: title, rawInput: rawInput, tags: tags, parentTopicId: parentTopicID, project: project),
            response: TopicDetailResponse.self
        )
    }

    func refreshRequirement(topicID: String, note: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/refresh-requirement",
            method: "POST",
            body: RefreshRequirementRequest(note: note),
            response: TopicDetailResponse.self
        )
    }

    func refreshPlan(topicID: String, note: String = "") async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/refresh-plan",
            method: "POST",
            body: RefreshRequirementRequest(note: note),
            response: TopicDetailResponse.self
        )
    }

    func approveRequirement(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/approve-requirement",
            method: "POST",
            body: ActorRequest(actor: "ios-controller"),
            response: TopicDetailResponse.self
        )
    }

    func approvePlan(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/approve-plan",
            method: "POST",
            body: ActorRequest(actor: "ios-controller"),
            response: TopicDetailResponse.self
        )
    }

    func submitFeedback(topicID: String, requestID: String, selectedOptions: [String], note: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/feedback-responses",
            method: "POST",
            body: FeedbackResponseRequest(
                requestId: requestID,
                selectedOptions: selectedOptions,
                note: note,
                actor: "ios-controller"
            ),
            response: TopicDetailResponse.self
        )
    }

    func triggerRun(topicID: String, executor: String, command: [String]) async throws -> RunRecordModel {
        try await send(
            "/topics/\(topicID)/runs",
            method: "POST",
            body: RunCreateRequest(executor: executor, command: command),
            response: RunRecordModel.self
        )
    }

    func markHumanTesting(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/mark-human-testing",
            method: "POST",
            body: EmptyBody(),
            response: TopicDetailResponse.self
        )
    }

    func markPassed(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/mark-passed",
            method: "POST",
            body: EmptyBody(),
            response: TopicDetailResponse.self
        )
    }

    func archiveTopic(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/archive",
            method: "POST",
            body: EmptyBody(),
            response: TopicDetailResponse.self
        )
    }

    // MARK: - Chat Sessions

    func fetchChatConfig() async throws -> ChatConfigResponse {
        try await send("/chat/config", response: ChatConfigResponse.self)
    }

    func saveChatApiKey(_ key: String) async throws {
        struct Body: Codable { let anthropicApiKey: String }
        struct Resp: Codable { let status: String }
        _ = try await send("/chat/config", method: "POST", body: Body(anthropicApiKey: key), response: Resp.self)
    }

    func fetchChatSessions() async throws -> [ChatSessionSummary] {
        try await send("/chat/sessions", response: ChatSessionListResponse.self).sessions
    }

    func createChatSession(project: String? = nil) async throws -> ChatSessionSummary {
        try await send(
            "/chat/sessions",
            method: "POST",
            body: ChatCreateSessionRequest(project: project),
            response: ChatSessionSummary.self
        )
    }

    func fetchChatMessages(sessionID: String) async throws -> [ChatMessageDTO] {
        try await send("/chat/sessions/\(sessionID)/messages", response: ChatMessagesResponse.self).messages
    }

    func sendChatMessage(sessionID: String, message: String) async throws {
        _ = try await send(
            "/chat/sessions/\(sessionID)/messages",
            method: "POST",
            body: ChatSendRequest(message: message),
            response: ChatStatusResponse.self
        )
    }

    func cancelChatSession(sessionID: String) async throws {
        _ = try await send(
            "/chat/sessions/\(sessionID)/cancel",
            method: "POST",
            body: EmptyBody(),
            response: ChatStatusResponse.self
        )
    }

    func eventRequest() throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = websocketScheme(for: baseURL.scheme ?? "http")
        components?.path = "/ws"
        guard let url = components?.url else {
            throw APIError(message: "Invalid websocket URL.")
        }
        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send<Response: Decodable>(_ path: String, response: Response.Type) async throws -> Response {
        try await send(path, method: "GET", bodyData: nil, response: response)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ path: String,
        method: String,
        body: Body,
        response: Response.Type
    ) async throws -> Response {
        let bodyData = try encoder.encode(body)
        return try await send(path, method: method, bodyData: bodyData, response: response)
    }

    private func send<Response: Decodable>(
        _ path: String,
        method: String,
        bodyData: Data?,
        response: Response.Type
    ) async throws -> Response {
        // Use URL(string:relativeTo:) to preserve query strings — appending(path:) encodes '?' as '%3F'
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIError(message: "Invalid URL path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        log.debug("→ \(method, privacy: .public) \(url.absoluteString, privacy: .public)")
        do {
            let (data, urlResponse) = try await session.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                log.error("← \(method, privacy: .public) \(path, privacy: .public) - non-HTTP response")
                throw APIError(message: "Unexpected response.")
            }
            log.debug("← \(httpResponse.statusCode) \(method, privacy: .public) \(path, privacy: .public) (\(data.count) bytes)")
            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                if let message = try? decoder.decode(ServerErrorEnvelope.self, from: data).error {
                    throw APIError(message: message)
                }
                throw APIError(message: "Request failed with status \(httpResponse.statusCode).")
            }
            return try decoder.decode(Response.self, from: data)
        } catch {
            log.error("✗ \(method, privacy: .public) \(path, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func websocketScheme(for scheme: String) -> String {
        switch scheme {
        case "https":
            return "wss"
        default:
            return "ws"
        }
    }
}

private struct ServerErrorEnvelope: Codable {
    let error: String
}

private struct EmptyBody: Codable {}
