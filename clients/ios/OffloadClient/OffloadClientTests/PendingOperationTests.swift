import XCTest
@testable import OffloadClient

final class PendingOperationTests: XCTestCase {
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

    private func roundTrip(_ action: OperationAction) throws -> PendingOperation {
        let op = PendingOperation(action: action)
        let data = try encoder.encode(op)
        return try decoder.decode(PendingOperation.self, from: data)
    }

    // MARK: - Roundtrip Tests

    func testCreateTopicRoundTrip() throws {
        let decoded = try roundTrip(.createTopic(title: "New", rawInput: "Build a thing", tags: ["swift", "ios"], project: nil, parentTopicId: nil))
        guard case let .createTopic(title, rawInput, tags, project, parentTopicId) = decoded.action else {
            return XCTFail("Expected createTopic")
        }
        XCTAssertEqual(title, "New")
        XCTAssertEqual(rawInput, "Build a thing")
        XCTAssertEqual(tags, ["swift", "ios"])
        XCTAssertNil(project)
        XCTAssertNil(parentTopicId)
    }

    func testCreateTopicWithProjectRoundTrip() throws {
        let decoded = try roundTrip(.createTopic(title: "Feature", rawInput: "Add auth", tags: [], project: "/Users/me/my-repo", parentTopicId: nil))
        guard case let .createTopic(_, _, _, project, _) = decoded.action else {
            return XCTFail("Expected createTopic")
        }
        XCTAssertEqual(project, "/Users/me/my-repo")
    }

    func testCreateTopicWithParentRoundTrip() throws {
        let decoded = try roundTrip(.createTopic(title: "Sub", rawInput: "child", tags: [], project: nil, parentTopicId: "parent-1"))
        guard case let .createTopic(_, _, _, _, parentTopicId) = decoded.action else {
            return XCTFail("Expected createTopic")
        }
        XCTAssertEqual(parentTopicId, "parent-1")
    }

    func testApproveRequirementRoundTrip() throws {
        let decoded = try roundTrip(.approveRequirement(topicId: "t-99"))
        guard case let .approveRequirement(topicId) = decoded.action else {
            return XCTFail("Expected approveRequirement")
        }
        XCTAssertEqual(topicId, "t-99")
    }

    func testApprovePlanRoundTrip() throws {
        let decoded = try roundTrip(.approvePlan(topicId: "t-42"))
        guard case let .approvePlan(topicId) = decoded.action else {
            return XCTFail("Expected approvePlan")
        }
        XCTAssertEqual(topicId, "t-42")
    }

    func testRefreshRequirementRoundTrip() throws {
        let decoded = try roundTrip(.refreshRequirement(topicId: "t-1", note: "needs clarification"))
        guard case let .refreshRequirement(topicId, note) = decoded.action else {
            return XCTFail("Expected refreshRequirement")
        }
        XCTAssertEqual(topicId, "t-1")
        XCTAssertEqual(note, "needs clarification")
    }

    func testRefreshPlanRoundTrip() throws {
        let decoded = try roundTrip(.refreshPlan(topicId: "t-7"))
        guard case let .refreshPlan(topicId) = decoded.action else {
            return XCTFail("Expected refreshPlan")
        }
        XCTAssertEqual(topicId, "t-7")
    }

    func testSubmitFeedbackRoundTrip() throws {
        let decoded = try roundTrip(.submitFeedback(topicId: "t-1", requestId: "fb-1", selectedOptions: ["optA"], note: "looks good"))
        guard case let .submitFeedback(topicId, requestId, selectedOptions, note) = decoded.action else {
            return XCTFail("Expected submitFeedback")
        }
        XCTAssertEqual(topicId, "t-1")
        XCTAssertEqual(requestId, "fb-1")
        XCTAssertEqual(selectedOptions, ["optA"])
        XCTAssertEqual(note, "looks good")
    }

    func testTriggerRunRoundTrip() throws {
        let decoded = try roundTrip(.triggerRun(topicId: "t-1", executor: "command", command: ["/usr/bin/echo", "hello"]))
        guard case let .triggerRun(topicId, executor, command) = decoded.action else {
            return XCTFail("Expected triggerRun")
        }
        XCTAssertEqual(topicId, "t-1")
        XCTAssertEqual(executor, "command")
        XCTAssertEqual(command, ["/usr/bin/echo", "hello"])
    }

    func testTriggerRunClaudeExecutorRoundTrip() throws {
        let decoded = try roundTrip(.triggerRun(topicId: "t-1", executor: "claude", command: []))
        guard case let .triggerRun(_, executor, command) = decoded.action else {
            return XCTFail("Expected triggerRun")
        }
        XCTAssertEqual(executor, "claude")
        XCTAssertEqual(command, [])
    }

    func testMarkHumanTestingRoundTrip() throws {
        let decoded = try roundTrip(.markHumanTesting(topicId: "t-5"))
        guard case let .markHumanTesting(topicId) = decoded.action else {
            return XCTFail("Expected markHumanTesting")
        }
        XCTAssertEqual(topicId, "t-5")
    }

    func testMarkPassedRoundTrip() throws {
        let decoded = try roundTrip(.markPassed(topicId: "t-5"))
        guard case let .markPassed(topicId) = decoded.action else {
            return XCTFail("Expected markPassed")
        }
        XCTAssertEqual(topicId, "t-5")
    }

    func testArchiveTopicRoundTrip() throws {
        let decoded = try roundTrip(.archiveTopic(topicId: "t-done"))
        guard case let .archiveTopic(topicId) = decoded.action else {
            return XCTFail("Expected archiveTopic")
        }
        XCTAssertEqual(topicId, "t-done")
    }

    // MARK: - Identity Preservation

    func testIdAndDatePreserved() throws {
        let op = PendingOperation(action: .refreshPlan(topicId: "t-1"))
        let data = try encoder.encode(op)
        let decoded = try decoder.decode(PendingOperation.self, from: data)
        XCTAssertEqual(decoded.id, op.id)
        XCTAssertEqual(
            decoded.createdAt.timeIntervalSince1970,
            op.createdAt.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - Array Roundtrip

    func testArrayRoundTrip() throws {
        let ops = [
            PendingOperation(action: .createTopic(title: "A", rawInput: "a", tags: [], project: nil, parentTopicId: nil)),
            PendingOperation(action: .approveRequirement(topicId: "t-1")),
            PendingOperation(action: .archiveTopic(topicId: "t-2")),
        ]
        let data = try encoder.encode(ops)
        let decoded = try decoder.decode([PendingOperation].self, from: data)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].id, ops[0].id)
        XCTAssertEqual(decoded[2].id, ops[2].id)
    }
}
