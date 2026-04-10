import Foundation
@testable import OffloadClient

extension TopicSummary {
    static func fixture(
        topicId: String = "topic-1",
        title: String = "Test Topic",
        summary: String = "A test summary",
        rawInput: String = "raw input text",
        parentTopicId: String? = nil,
        tags: [String] = [],
        requirementState: RequirementState = .captured,
        executionState: ExecutionState = .idle,
        decisionState: DecisionState = .none
    ) -> TopicSummary {
        TopicSummary(
            topicId: topicId,
            title: title,
            summary: summary,
            rawInput: rawInput,
            parentTopicId: parentTopicId,
            tags: tags,
            priority: "normal",
            project: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            requirementState: requirementState,
            executionState: executionState,
            decisionState: decisionState,
            requirementApprovedAt: nil,
            planApprovedAt: nil,
            latestRunId: nil,
            pendingFeedbackRequestId: nil,
            assignedExecutor: nil,
            workspacePath: "/tmp/test"
        )
    }
}

extension TopicDetailResponse {
    static func fixture(
        topic: TopicSummary = .fixture(),
        parentTopic: TopicSummary? = nil,
        childTopics: [TopicSummary] = [],
        documents: [String: String] = [:],
        feedbackRequests: [FeedbackRequestModel] = [],
        runs: [RunRecordModel] = [],
        artifacts: [String] = []
    ) -> TopicDetailResponse {
        TopicDetailResponse(
            topic: topic,
            parentTopic: parentTopic,
            childTopics: childTopics,
            documents: documents,
            feedbackRequests: feedbackRequests,
            runs: runs,
            artifacts: artifacts
        )
    }
}

extension FeedbackRequestModel {
    static func fixture(
        requestId: String = "fb-1",
        topicId: String = "topic-1",
        title: String = "Need input",
        prompt: String = "Choose an option",
        options: [String] = ["A", "B"],
        status: String = "pending"
    ) -> FeedbackRequestModel {
        FeedbackRequestModel(
            requestId: requestId,
            topicId: topicId,
            requestType: "choice",
            title: title,
            prompt: prompt,
            options: options,
            status: status,
            createdAt: "2026-01-01T00:00:00Z",
            resolvedAt: nil,
            allowNote: true,
            metadata: [:]
        )
    }
}
