import XCTest
@testable import OffloadClient

@MainActor
final class OfflineFlowTests: XCTestCase {
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

    // MARK: - Cache Loading

    func testBootstrapLoadsCachedTopics() async throws {
        // Pre-populate cache
        try await store.saveTopics([
            .fixture(topicId: "cached-1", title: "Cached Topic"),
        ])

        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.serverURLString = ""  // No server → loadFromCache path

        model.bootstrap()
        // Give the async Task inside bootstrap time to complete
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.topics.count, 1)
        XCTAssertEqual(model.topics.first?.title, "Cached Topic")
    }

    func testCachedDetailLoadedOnSelect() async throws {
        let detail = TopicDetailResponse.fixture(
            topic: .fixture(topicId: "d1", title: "Detail"),
            documents: ["topic.md": "# Hello"]
        )
        try await store.saveTopicDetail(detail, topicID: "d1")
        try await store.saveTopics([.fixture(topicId: "d1")])

        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.topics = await store.loadTopics()

        model.selectTopic("d1")
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(model.selectedTopicDetail)
        XCTAssertEqual(model.selectedTopicDetail?.documents["topic.md"], "# Hello")
    }

    // MARK: - Offline Topic Creation

    func testCreateTopicOfflineQueuesOperation() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false

        await model.createTopic(title: "Offline Idea", rawInput: "Build something cool", tagsText: "swift,offline")

        // Verify topic appears in list with local- prefix
        XCTAssertEqual(model.topics.count, 1)
        XCTAssertTrue(model.topics[0].topicId.hasPrefix("local-"))
        XCTAssertEqual(model.topics[0].title, "Offline Idea")
        XCTAssertEqual(model.topics[0].tags, ["swift", "offline"])

        // Verify operation queued
        let ops = await store.loadPendingOperations()
        XCTAssertEqual(ops.count, 1)
        guard case let .createTopic(title, rawInput, tags, _, parentTopicId) = ops[0].action else {
            return XCTFail("Expected createTopic action")
        }
        XCTAssertEqual(title, "Offline Idea")
        XCTAssertEqual(rawInput, "Build something cool")
        XCTAssertEqual(tags, ["swift", "offline"])
        XCTAssertNil(parentTopicId)

        // Verify pending count
        XCTAssertEqual(model.pendingOperationCount, 1)
    }

    func testCreateTopicOfflineSetsSelectedDetail() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false

        await model.createTopic(title: "Offline", rawInput: "test", tagsText: "")

        XCTAssertNotNil(model.selectedTopicID)
        XCTAssertTrue(model.selectedTopicID!.hasPrefix("local-"))
        XCTAssertNotNil(model.selectedTopicDetail)
        XCTAssertEqual(model.selectedTopicDetail?.topic.title, "Offline")
    }

    // MARK: - Offline Mutations

    func testApproveRequirementOfflineQueues() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.selectedTopicID = "topic-1"

        await model.approveRequirement()

        let ops = await store.loadPendingOperations()
        XCTAssertEqual(ops.count, 1)
        guard case let .approveRequirement(topicId) = ops[0].action else {
            return XCTFail("Expected approveRequirement")
        }
        XCTAssertEqual(topicId, "topic-1")
        XCTAssertEqual(model.pendingOperationCount, 1)
        XCTAssertEqual(model.statusMessage, "Queued offline")
    }

    func testMultipleOfflineMutationsQueueInOrder() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.selectedTopicID = "topic-1"

        await model.approveRequirement()
        await model.approvePlan()
        await model.refreshPlan()

        let ops = await store.loadPendingOperations()
        XCTAssertEqual(ops.count, 3)

        guard case .approveRequirement = ops[0].action else {
            return XCTFail("Expected approveRequirement first")
        }
        guard case .approvePlan = ops[1].action else {
            return XCTFail("Expected approvePlan second")
        }
        guard case .refreshPlan = ops[2].action else {
            return XCTFail("Expected refreshPlan third")
        }

        XCTAssertEqual(model.pendingOperationCount, 3)
    }

    func testTriggerRunOfflineQueues() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.selectedTopicID = "topic-1"

        await model.triggerRun(executor: "claude", commandText: "build the auth module")

        let ops = await store.loadPendingOperations()
        XCTAssertEqual(ops.count, 1)
        guard case let .triggerRun(topicId, executor, command) = ops[0].action else {
            return XCTFail("Expected triggerRun")
        }
        XCTAssertEqual(topicId, "topic-1")
        XCTAssertEqual(executor, "claude")
        XCTAssertEqual(command, ["build", "the", "auth", "module"])
    }

    // MARK: - Cache Persistence

    func testOfflineCreatedTopicPersistedToCache() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false

        await model.createTopic(title: "Persisted", rawInput: "test", tagsText: "")

        // Verify topics saved to cache
        let cached = await store.loadTopics()
        XCTAssertEqual(cached.count, 1)
        XCTAssertEqual(cached[0].title, "Persisted")

        // Verify detail saved to cache
        let cachedDetail = await store.loadTopicDetail(topicID: cached[0].topicId)
        XCTAssertNotNil(cachedDetail)
    }

    // MARK: - No-op Guards

    func testMutationWithNoSelectedTopicDoesNothing() async throws {
        let model = AppModel(localStore: store, enableNetworkMonitor: false)
        model.isOnline = false
        model.selectedTopicID = nil

        await model.approveRequirement()
        await model.approvePlan()
        await model.markPassed()

        let ops = await store.loadPendingOperations()
        XCTAssertTrue(ops.isEmpty)
        XCTAssertEqual(model.pendingOperationCount, 0)
    }
}
