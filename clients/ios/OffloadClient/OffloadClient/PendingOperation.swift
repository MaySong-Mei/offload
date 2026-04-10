import Foundation

struct PendingOperation: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let action: OperationAction

    init(action: OperationAction) {
        self.id = UUID()
        self.createdAt = Date()
        self.action = action
    }
}

enum OperationAction: Codable {
    case createTopic(title: String, rawInput: String, tags: [String], project: String?, parentTopicId: String?)
    case approveRequirement(topicId: String)
    case approvePlan(topicId: String)
    case refreshRequirement(topicId: String, note: String)
    case refreshPlan(topicId: String)
    case submitFeedback(topicId: String, requestId: String, selectedOptions: [String], note: String)
    case triggerRun(topicId: String, executor: String, command: [String])
    case markHumanTesting(topicId: String)
    case markPassed(topicId: String)
    case archiveTopic(topicId: String)
}
