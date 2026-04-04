import SwiftUI

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var showingNewTopicSheet = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                ConnectionPanel(model: model)
                HStack {
                    Text("Feedback queue")
                        .font(.headline)
                    Spacer()
                    Text("\(model.feedbackQueue.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                List(model.topics, selection: Binding(
                    get: { model.selectedTopicID },
                    set: { model.selectTopic($0) }
                )) { topic in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(topic.title)
                            .font(.headline)
                        Text(topic.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            StatusChip(text: topic.requirementState.rawValue)
                            StatusChip(text: topic.executionState.rawValue)
                            StatusChip(text: topic.decisionState.rawValue)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(topic.topicId)
                }
                .overlay {
                    if model.topics.isEmpty {
                        ContentUnavailableView("No Topics", systemImage: "tray", description: Text("Capture a new idea to start the loop."))
                    }
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Offload")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewTopicSheet = true
                    } label: {
                        Label("New Topic", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let detail = model.selectedTopicDetail {
                TopicDetailView(model: model, detail: detail)
            } else {
                ContentUnavailableView("Select A Topic", systemImage: "square.and.pencil", description: Text("Choose a topic from the list or create a new one."))
            }
        }
        .sheet(isPresented: $showingNewTopicSheet) {
            NewTopicSheet(model: model)
        }
        .task {
            model.bootstrap()
        }
    }
}

private struct ConnectionPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.headline)
            TextField("Server URL", text: $model.serverURLString)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            SecureField("API token (optional)", text: $model.apiToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Connect") {
                    model.connect()
                }
                .buttonStyle(.borderedProminent)

                Button("Reload") {
                    Task { await model.reload() }
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(model.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NewTopicSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var title = ""
    @State private var rawInput = ""
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Tags, comma separated", text: $tagsText)
                TextEditor(text: $rawInput)
                    .frame(minHeight: 220)
            }
            .navigationTitle("New Topic")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await model.createTopic(title: title, rawInput: rawInput, tagsText: tagsText)
                            dismiss()
                        }
                    }
                    .disabled(rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct TopicDetailView: View {
    @ObservedObject var model: AppModel
    let detail: TopicDetailResponse
    @State private var refreshNote = ""
    @State private var commandText = "/usr/bin/printf hello-from-ios"

    private var pendingFeedback: [FeedbackRequestModel] {
        detail.feedbackRequests.filter { $0.status == "pending" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(detail.topic.title)
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text(detail.topic.summary)
                            .foregroundStyle(.secondary)
                        HStack {
                            StatusChip(text: detail.topic.requirementState.rawValue)
                            StatusChip(text: detail.topic.executionState.rawValue)
                            StatusChip(text: detail.topic.decisionState.rawValue)
                        }
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Actions")
                        .font(.headline)
                    HStack {
                        Button("Approve Requirement") {
                            Task { await model.approveRequirement() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Approve Plan") {
                            Task { await model.approvePlan() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Refresh Plan") {
                            Task { await model.refreshPlan() }
                        }
                        .buttonStyle(.bordered)
                    }

                    TextField("Clarification note for requirement refresh", text: $refreshNote)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Refresh Requirement") {
                            Task { await model.refreshRequirement(note: refreshNote) }
                        }
                        .buttonStyle(.bordered)

                        Button("Mark Human Testing") {
                            Task { await model.markHumanTesting() }
                        }
                        .buttonStyle(.bordered)

                        Button("Mark Passed") {
                            Task { await model.markPassed() }
                        }
                        .buttonStyle(.bordered)
                    }

                    TextField("Command to run", text: $commandText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Trigger Run") {
                        Task { await model.triggerRun(commandText: commandText) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                if !pendingFeedback.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Pending Feedback")
                            .font(.headline)
                        ForEach(pendingFeedback) { request in
                            FeedbackRequestCard(model: model, request: request)
                        }
                    }
                }

                DocumentSection(title: "Overview", bodyText: detail.documents["topic.md"] ?? "")
                DocumentSection(title: "Requirement", bodyText: detail.documents["requirement.md"] ?? "")
                DocumentSection(title: "Plan", bodyText: detail.documents["plan.md"] ?? "")
                DocumentSection(title: "Notes", bodyText: detail.documents["notes.md"] ?? "")

                VStack(alignment: .leading, spacing: 12) {
                    Text("Runs")
                        .font(.headline)
                    ForEach(detail.runs) { run in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(run.executor)
                                    .font(.headline)
                                Spacer()
                                StatusChip(text: run.status)
                            }
                            Text(run.summary)
                            if !run.command.isEmpty {
                                Text(run.command.joined(separator: " "))
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if !run.artifacts.isEmpty {
                                Text(run.artifacts.joined(separator: "\n"))
                                    .font(.footnote.monospaced())
                            }
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(detail.topic.title)
    }
}

private struct FeedbackRequestCard: View {
    @ObservedObject var model: AppModel
    let request: FeedbackRequestModel
    @State private var selectedOption = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title)
                .font(.headline)
            Text(request.prompt)
                .foregroundStyle(.secondary)
            if !request.options.isEmpty {
                Picker("Choice", selection: $selectedOption) {
                    ForEach(request.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .onAppear {
                    if selectedOption.isEmpty {
                        selectedOption = request.options.first ?? ""
                    }
                }
            }
            if request.allowNote {
                TextField("Optional note", text: $note)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Send Feedback") {
                Task {
                    let selection = selectedOption.isEmpty ? [] : [selectedOption]
                    await model.submitFeedback(requestID: request.requestId, selectedOptions: selection, note: note)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DocumentSection: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(bodyText)
                .font(.body.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

private struct StatusChip: View {
    let text: String

    var body: some View {
        Text(text.replacingOccurrences(of: "_", with: " "))
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }
}

