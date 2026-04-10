import XCTest
@testable import OffloadClient

final class LocalStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: LocalStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        store = LocalStore(directory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Topics

    func testSaveAndLoadTopics() async throws {
        let topics = [
            TopicSummary.fixture(topicId: "t1", title: "First"),
            TopicSummary.fixture(topicId: "t2", title: "Second"),
        ]
        try await store.saveTopics(topics)

        let loaded = await store.loadTopics()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].topicId, "t1")
        XCTAssertEqual(loaded[1].title, "Second")
    }

    func testLoadTopicsReturnsEmptyWhenNoFile() async {
        let loaded = await store.loadTopics()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Topic Detail

    func testSaveAndLoadTopicDetail() async throws {
        let detail = TopicDetailResponse.fixture(
            topic: .fixture(topicId: "d1", title: "Detail Test"),
            documents: ["topic.md": "# Overview"]
        )
        try await store.saveTopicDetail(detail, topicID: "d1")

        let loaded = await store.loadTopicDetail(topicID: "d1")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.topic.topicId, "d1")
        XCTAssertEqual(loaded?.documents["topic.md"], "# Overview")
    }

    func testLoadTopicDetailReturnsNilWhenMissing() async {
        let loaded = await store.loadTopicDetail(topicID: "nonexistent")
        XCTAssertNil(loaded)
    }

    // MARK: - Feedback Queue

    func testSaveAndLoadFeedbackQueue() async throws {
        let queue = [
            FeedbackRequestModel.fixture(requestId: "f1"),
            FeedbackRequestModel.fixture(requestId: "f2"),
        ]
        try await store.saveFeedbackQueue(queue)

        let loaded = await store.loadFeedbackQueue()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].requestId, "f1")
    }

    // MARK: - Pending Operations

    func testEnqueueAndLoadOperations() async throws {
        let op1 = PendingOperation(action: .approveRequirement(topicId: "t1"))
        let op2 = PendingOperation(action: .refreshPlan(topicId: "t2"))
        try await store.enqueueOperation(op1)
        try await store.enqueueOperation(op2)

        let loaded = await store.loadPendingOperations()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, op1.id)
        XCTAssertEqual(loaded[1].id, op2.id)
    }

    func testPendingOperationCount() async throws {
        XCTAssertEqual(await store.pendingOperationCount, 0)

        try await store.enqueueOperation(PendingOperation(action: .refreshPlan(topicId: "t1")))
        XCTAssertEqual(await store.pendingOperationCount, 1)

        try await store.enqueueOperation(PendingOperation(action: .refreshPlan(topicId: "t2")))
        XCTAssertEqual(await store.pendingOperationCount, 2)
    }

    func testClearPendingOperations() async throws {
        try await store.enqueueOperation(PendingOperation(action: .refreshPlan(topicId: "t1")))
        try await store.clearPendingOperations()

        let loaded = await store.loadPendingOperations()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Clear All

    func testClearAll() async throws {
        try await store.saveTopics([.fixture()])
        try await store.enqueueOperation(PendingOperation(action: .refreshPlan(topicId: "t1")))

        await store.clearAll()

        XCTAssertTrue(await store.loadTopics().isEmpty)
        XCTAssertTrue(await store.loadPendingOperations().isEmpty)
    }

    // MARK: - Overwrite

    func testSaveTopicsOverwritesPrevious() async throws {
        try await store.saveTopics([.fixture(topicId: "old")])
        try await store.saveTopics([.fixture(topicId: "new1"), .fixture(topicId: "new2")])

        let loaded = await store.loadTopics()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].topicId, "new1")
    }
}
