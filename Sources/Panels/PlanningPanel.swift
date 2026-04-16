import AppKit
import Combine
import SwiftUI

/// Panel type for the Factory planning view.
/// Shows beads sidebar + plan/detail view in a single tab.
@MainActor
final class PlanningPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .planning

    @Published var displayTitle: String = "Planning"
    var displayIcon: String? { "list.bullet.clipboard" }

    // UI state
    @Published var beads: [BeadSummary] = []
    @Published var epics: [EpicInfo] = []
    @Published var selectedBeadId: String?
    @Published var selectedDetail: BeadDetail?
    @Published var epicFilter: String = "all"
    @Published var assignmentFilter: AssignmentFilter = .mine
    @Published var isLoading = false
    @Published var lastSync: Date?

    private var refreshTimer: Timer?

    init(id: UUID = UUID()) {
        self.id = id
    }

    func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func focus() {
        startRefreshTimer()
        Task { await refresh() }
    }

    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    // MARK: - Data

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // Use factory CLI with JSON output for structured data
        if let json = await runFactory(["list", "--json"]) {
            if let data = json.data(using: .utf8),
               let items = try? JSONDecoder().decode([CLIBeadSummary].self, from: data) {
                beads = items.map { $0.toBeadSummary() }
            }
        }

        lastSync = Date()
    }

    func loadDetail(for beadId: String) async {
        if let json = await runFactory(["show", beadId, "--json"]) {
            if let data = json.data(using: .utf8),
               let detail = try? JSONDecoder().decode(CLIBeadDetail.self, from: data) {
                selectedDetail = detail.toBeadDetail()
            }
        }
    }

    func investigate(beadId: String) {
        let cmuxCLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let jiraKey = beadId.uppercased()
        Task {
            await loadDetail(for: beadId)
            let title = selectedDetail?.title ?? ""
            let desc = (selectedDetail?.description ?? "")
                .replacingOccurrences(of: "'", with: "'\\''")

            // Write context to a temp file for the system prompt
            let promptFile = "/tmp/factory-investigate-\(beadId).md"
            let systemPrompt = """
            # Investigating \(jiraKey): \(title)

            You are investigating this ticket to understand its scope and plan the work.

            ## Description

            \(selectedDetail?.description ?? "No description")

            ## Instructions

            1. Read the description carefully
            2. Explore the relevant codebase to understand what needs to change
            3. Assess complexity and risks
            4. Propose an implementation approach
            5. Record findings: run `bd comment \(beadId) "Investigation: <findings>"`

            You have access to the full codebase. Use Read, Grep, Glob, Bash as needed.
            """
            try? systemPrompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

            // Launch interactive claude session with the system prompt
            let cmd = "claude --system-prompt-file \(promptFile) --allowedTools 'Bash,Read,Grep,Glob'"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmuxCLI)
            process.arguments = ["new-workspace", "--name", jiraKey, "--command", cmd]
            try? process.run()
        }
    }

    func delegate(beadId: String) {
        Task {
            let _ = await runFactory(["delegate", beadId, "--formula", "implement"])
        }
    }

    // MARK: - Private

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private func runFactory(_ args: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Users/clavery/factory/target/debug/factory")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: "/Users/clavery/factory")

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - CLI JSON Types (Decodable)

private struct CLIBeadSummary: Decodable {
    let id: String
    let title: String
    let status: String
    let jira_status: String?
    let priority: Int
    let issue_type: String
    let assignee: String?
    let labels: [String]?
    let parent: String?
    let pr: String?
    let pr_state: String?
    let ci: String?
    let review: String?
    let attention: [String]?

    func toBeadSummary() -> BeadSummary {
        BeadSummary(
            id: id, title: title, status: status,
            jiraStatus: jira_status, priority: priority,
            issueType: issue_type, assignee: assignee,
            labels: labels ?? [], parent: parent,
            pr: pr, prState: pr_state, ci: ci,
            review: review, attention: attention ?? []
        )
    }
}

private struct CLIBeadDetail: Decodable {
    let id: String
    let title: String
    let description: String?
    let status: String
    let priority: Int
    let issue_type: String?
    let assignee: String?
    let external_ref: String?
    let parent: String?
    let labels: [String]?
    let created_at: String?
    let updated_at: String?

    func toBeadDetail() -> BeadDetail {
        BeadDetail(
            id: id, title: title,
            description: description ?? "",
            status: status, jiraStatus: nil,
            priority: priority, issueType: issue_type,
            assignee: assignee, externalRef: external_ref,
            parent: parent, labels: labels ?? [],
            createdAt: created_at, updatedAt: updated_at
        )
    }
}

// MARK: - Data Types

struct BeadSummary: Identifiable {
    let id: String
    let title: String
    let status: String
    let jiraStatus: String?
    let priority: Int
    let issueType: String
    let assignee: String?
    let labels: [String]
    let parent: String?
    let pr: String?
    let prState: String?
    let ci: String?
    let review: String?
    let attention: [String]

    var isEpic: Bool { issueType == "epic" }
    var jiraKey: String { id.uppercased() }
    var displayStatus: String { jiraStatus ?? status }
}

struct EpicInfo: Identifiable {
    let id: String
    let title: String
    let childCount: Int
}

struct BeadDetail {
    let id: String
    let title: String
    let description: String
    let status: String
    let jiraStatus: String?
    let priority: Int
    let issueType: String?
    let assignee: String?
    let externalRef: String?
    let parent: String?
    let labels: [String]
    let createdAt: String?
    let updatedAt: String?

    var jiraKey: String { id.uppercased() }
    var isEpic: Bool { issueType == "epic" }
    var isLocal: Bool { externalRef == nil }
}

enum AssignmentFilter: String, CaseIterable {
    case mine = "Mine"
    case open = "Open"
    case all = "All"
}
