import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var serverURLString: String
    @Published var apiToken: String
    @Published var topics: [TopicSummary] = []
    @Published var feedbackQueue: [FeedbackRequestModel] = []
    @Published var selectedTopicID: String?
    @Published var selectedTopicDetail: TopicDetailResponse?
    @Published var isLoading = false
    @Published var statusMessage = "Disconnected"
    @Published var errorMessage: String?

    private let defaults = UserDefaults.standard
    private var eventTask: Task<Void, Never>?

    init() {
        self.serverURLString = defaults.string(forKey: "offload.serverURL") ?? "http://127.0.0.1:8080"
        self.apiToken = defaults.string(forKey: "offload.apiToken") ?? ""
    }

    deinit {
        eventTask?.cancel()
    }

    func bootstrap() {
        guard !serverURLString.isEmpty else { return }
        connect()
    }

    func connect() {
        defaults.set(serverURLString, forKey: "offload.serverURL")
        defaults.set(apiToken, forKey: "offload.apiToken")
        statusMessage = "Connecting..."
        Task {
            await reload()
            await startEventStream()
        }
    }

    func reload() async {
        guard let client = makeClient() else {
            errorMessage = "Invalid server URL."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            topics = try await client.fetchTopics()
            feedbackQueue = try await client.fetchFeedbackQueue()
            if selectedTopicID == nil {
                selectedTopicID = topics.first?.topicId
            }
            if let selectedTopicID {
                selectedTopicDetail = try await client.fetchTopicDetail(topicID: selectedTopicID)
            }
            statusMessage = "Connected"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Connection failed"
        }
    }

    func selectTopic(_ topicID: String?) {
        selectedTopicID = topicID
        guard let topicID else {
            selectedTopicDetail = nil
            return
        }
        Task {
            await refreshTopic(topicID: topicID)
        }
    }

    func createTopic(title: String, rawInput: String, tagsText: String) async {
        guard let client = makeClient() else { return }
        do {
            let tags = tagsText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let detail = try await client.createTopic(title: title, rawInput: rawInput, tags: tags)
            selectedTopicID = detail.topic.topicId
            selectedTopicDetail = detail
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshRequirement(note: String) async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.refreshRequirement(topicID: topicID, note: note)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshPlan() async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.refreshPlan(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approveRequirement() async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.approveRequirement(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approvePlan() async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.approvePlan(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitFeedback(requestID: String, selectedOptions: [String], note: String) async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.submitFeedback(
                topicID: topicID,
                requestID: requestID,
                selectedOptions: selectedOptions,
                note: note
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func triggerRun(commandText: String) async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        let command = commandText
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        do {
            _ = try await client.triggerRun(topicID: topicID, command: command)
            await refreshTopic(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markHumanTesting() async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.markHumanTesting(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markPassed() async {
        guard let topicID = selectedTopicID, let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.markPassed(topicID: topicID)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshTopic(topicID: String) async {
        guard let client = makeClient() else { return }
        do {
            selectedTopicDetail = try await client.fetchTopicDetail(topicID: topicID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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
                    await reload()
                }
            } catch {
                statusMessage = "Realtime updates offline"
            }
        }
    }

    private func makeClient() -> APIClient? {
        guard let url = URL(string: serverURLString) else { return nil }
        return APIClient(baseURL: url, token: apiToken)
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

