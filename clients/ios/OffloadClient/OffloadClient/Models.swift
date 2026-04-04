import Foundation

enum RequirementState: String, Codable {
    case captured
    case clarifying
    case discussed
    case specified
    case approved
}

enum ExecutionState: String, Codable {
    case idle
    case queued
    case implementing
    case implemented
    case humanTesting = "human_testing"
    case passed
    case failed
    case paused
}

enum DecisionState: String, Codable {
    case none
    case needsFeedback = "needs_feedback"
    case blocked
    case pendingImplementation = "pending_implementation"
    case archived
}

struct TopicSummary: Codable, Identifiable, Hashable {
    let topicId: String
    let title: String
    let summary: String
    let rawInput: String
    let parentTopicId: String?
    let tags: [String]
    let priority: String
    let project: String?
    let createdAt: String
    let updatedAt: String
    let requirementState: RequirementState
    let executionState: ExecutionState
    let decisionState: DecisionState
    let requirementApprovedAt: String?
    let planApprovedAt: String?
    let latestRunId: String?
    let pendingFeedbackRequestId: String?
    let assignedExecutor: String?
    let workspacePath: String

    var id: String { topicId }
}

struct FeedbackRequestModel: Codable, Identifiable, Hashable {
    let requestId: String
    let topicId: String
    let requestType: String
    let title: String
    let prompt: String
    let options: [String]
    let status: String
    let createdAt: String
    let resolvedAt: String?
    let allowNote: Bool
    let metadata: [String: String]

    var id: String { requestId }
}

struct RunRecordModel: Codable, Identifiable, Hashable {
    let runId: String
    let topicId: String
    let executor: String
    let status: String
    let createdAt: String
    let updatedAt: String
    let finishedAt: String?
    let summary: String
    let command: [String]
    let artifacts: [String]
    let exitCode: Int?
    let error: String?

    var id: String { runId }
}

struct TopicDetailResponse: Codable {
    let topic: TopicSummary
    let parentTopic: TopicSummary?
    let childTopics: [TopicSummary]
    let documents: [String: String]
    let feedbackRequests: [FeedbackRequestModel]
    let runs: [RunRecordModel]
    let artifacts: [String]
}

struct TopicListResponse: Codable {
    let topics: [TopicSummary]
}

struct FeedbackQueueResponse: Codable {
    let feedbackRequests: [FeedbackRequestModel]
}

struct EventEnvelope: Codable {
    let sequence: Int?
    let eventType: String
    let topicId: String?
    let runId: String?
}

struct TopicCreateRequest: Codable {
    let title: String
    let rawInput: String
    let tags: [String]
    let parentTopicId: String?
}

struct FeedbackResponseRequest: Codable {
    let requestId: String
    let selectedOptions: [String]
    let note: String
    let actor: String
}

struct ActorRequest: Codable {
    let actor: String
}

struct RefreshRequirementRequest: Codable {
    let note: String
}

struct RunCreateRequest: Codable {
    let executor: String
    let command: [String]
}
