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
    let metadata: [String: AnyCodable]

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
    let payload: [String: AnyCodable]?
}

/// Lightweight wrapper for heterogeneous JSON payloads.
struct AnyCodable: Codable, Hashable {
    let value: String  // stored as string for simplicity

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let b = try? container.decode(Bool.self) {
            value = String(b)
        } else if let d = try? container.decode(Double.self) {
            value = String(d)
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct ProjectInfo: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let hasReadme: Bool
    let isInitialized: Bool
    let initStatus: String
    let summary: String?
    let initError: String?

    var id: String { path }

    var statusLabel: String {
        switch initStatus {
        case "ready": return "Ready"
        case "initializing": return "Initializing…"
        case "failed": return "Failed"
        default: return "Not Initialized"
        }
    }
}

struct ProjectListResponse: Codable {
    let projects: [ProjectInfo]
}

struct ReadmeResponse: Codable {
    let content: String
}

struct InitLogResponse: Codable {
    let log: [String]
    let status: String
}

struct ProjectActivityResponse: Codable {
    let meta: ProjectMeta
    let recentRuns: [RecentRun]
    let recentCommits: [RecentCommit]
}

struct ProjectMeta: Codable {
    let name: String
    let path: String
    let summary: String?
    let topicStats: TopicStats
    let architectureExcerpt: String?
}

struct TopicStats: Codable {
    let total: Int
    let active: Int
    let completed: Int
    let archived: Int
}

struct RecentRun: Codable, Identifiable {
    let topicId: String
    let topicTitle: String
    let runId: String
    let executor: String
    let status: String
    let finishedAt: String?
    let summary: String
    let reportExcerpt: String?

    var id: String { runId }
}

struct RecentCommit: Codable, Identifiable {
    let hash: String
    let message: String
    let date: String
    let author: String

    var id: String { hash }
}

struct AgentStreamEvent: Identifiable {
    let id = UUID()
    let topicId: String
    let stage: String
    let claudeEventType: String   // "assistant", "tool_result", "result", "system"
    let text: String?             // assistant text output
    let toolName: String?         // tool_use name (e.g. "Read", "Glob")
    let toolInput: String?        // tool input (truncated)
    let toolResult: String?       // tool result (truncated)
    let result: String?           // final result text
    let timestamp = Date()
}

struct SensorModel: Codable, Identifiable {
    let sensorId: String
    let project: String
    let name: String
    let description: String
    let status: String       // building, testing, active, paused, failed
    let schedule: String
    let sourceTopicId: String?
    let createdAt: String
    let lastRunAt: String?
    let lastError: String?
    let consecutiveFailures: Int

    var id: String { sensorId }
}

struct SignalModel: Codable, Identifiable {
    let signalId: String
    let sensorId: String
    let project: String
    let severity: String     // info, warning, critical
    let title: String
    let detail: String
    let count: Int
    let source: String
    let createdAt: String

    var id: String { signalId }
}

struct SensorListResponse: Codable {
    let sensors: [SensorModel]
}

struct SignalListResponse: Codable {
    let signals: [SignalModel]
}

struct ArchNode: Codable, Identifiable {
    let id: String
    let label: String
    let type: String   // "project", "group", "layer", "module"
    let desc: String
    let children: [ArchNode]
}

struct ArchTreeResponse: Codable {
    let tree: ArchNode
}

struct FileEntry: Codable, Identifiable {
    let name: String
    let relPath: String
    let isDir: Bool
    let size: Int?

    var id: String { relPath }
}

struct FileListResponse: Codable {
    let entries: [FileEntry]
    let rel: String
    let error: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([FileEntry].self, forKey: .entries)
        rel = try container.decode(String.self, forKey: .rel)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

struct FileContentResponse: Codable {
    let rel: String
    let content: String?
    let truncated: Bool?
    let binary: Bool?
    let size: Int?
}

struct AgentStatusModel: Codable, Identifiable {
    let name: String
    let displayName: String
    let available: Bool
    let version: String?
    let error: String?
    let authStatus: String?  // "authenticated", "needs_login", "unknown"
    let detail: String?

    var id: String { name }
}

struct AgentStatusResponse: Codable {
    let agents: [AgentStatusModel]
}

struct TopicCreateRequest: Codable {
    let title: String
    let rawInput: String
    let tags: [String]
    let parentTopicId: String?
    let project: String?
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
