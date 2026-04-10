import Foundation

actor LocalStore {
    static let `default` = LocalStore()

    private let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(directory: URL? = nil) {
        if let directory {
            root = directory
        } else {
            root = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("offload-cache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Topics

    func saveTopics(_ topics: [TopicSummary]) throws {
        try save(topics, as: "topics.json")
    }

    func loadTopics() -> [TopicSummary] {
        (try? load([TopicSummary].self, from: "topics.json")) ?? []
    }

    // MARK: - Topic Detail

    func saveTopicDetail(_ detail: TopicDetailResponse, topicID: String) throws {
        try save(detail, as: "detail-\(topicID).json")
    }

    func loadTopicDetail(topicID: String) -> TopicDetailResponse? {
        try? load(TopicDetailResponse.self, from: "detail-\(topicID).json")
    }

    // MARK: - Feedback Queue

    func saveFeedbackQueue(_ queue: [FeedbackRequestModel]) throws {
        try save(queue, as: "feedback-queue.json")
    }

    func loadFeedbackQueue() -> [FeedbackRequestModel] {
        (try? load([FeedbackRequestModel].self, from: "feedback-queue.json")) ?? []
    }

    // MARK: - Pending Operations

    func savePendingOperations(_ ops: [PendingOperation]) throws {
        try save(ops, as: "pending-operations.json")
    }

    func loadPendingOperations() -> [PendingOperation] {
        (try? load([PendingOperation].self, from: "pending-operations.json")) ?? []
    }

    func enqueueOperation(_ op: PendingOperation) throws {
        var ops = loadPendingOperations()
        ops.append(op)
        try savePendingOperations(ops)
    }

    var pendingOperationCount: Int {
        loadPendingOperations().count
    }

    // MARK: - Maintenance

    func clearPendingOperations() throws {
        try savePendingOperations([])
    }

    func clearAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Helpers

    private func save<T: Encodable>(_ value: T, as filename: String) throws {
        let data = try encoder.encode(value)
        try data.write(to: root.appendingPathComponent(filename), options: .atomic)
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T {
        let url = root.appendingPathComponent(filename)
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }
}
