import Foundation

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

    func createTopic(title: String, rawInput: String, tags: [String], parentTopicID: String? = nil) async throws -> TopicDetailResponse {
        try await send(
            "/topics",
            method: "POST",
            body: TopicCreateRequest(title: title, rawInput: rawInput, tags: tags, parentTopicId: parentTopicID),
            response: TopicDetailResponse.self
        )
    }

    func createSubtopic(parentTopicID: String, title: String, rawInput: String, tags: [String]) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(parentTopicID)/subtopics",
            method: "POST",
            body: TopicCreateRequest(title: title, rawInput: rawInput, tags: tags, parentTopicId: parentTopicID),
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

    func refreshPlan(topicID: String) async throws -> TopicDetailResponse {
        try await send(
            "/topics/\(topicID)/refresh-plan",
            method: "POST",
            body: EmptyBody(),
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

    func triggerRun(topicID: String, command: [String]) async throws -> RunRecordModel {
        try await send(
            "/topics/\(topicID)/runs",
            method: "POST",
            body: RunCreateRequest(executor: "command", command: command),
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
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData
        let (data, urlResponse) = try await session.data(for: request)
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw APIError(message: "Unexpected response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            if let message = try? decoder.decode(ServerErrorEnvelope.self, from: data).error {
                throw APIError(message: message)
            }
            throw APIError(message: "Request failed with status \(httpResponse.statusCode).")
        }
        return try decoder.decode(Response.self, from: data)
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
