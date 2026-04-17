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

    // Session tracking: bead ID → claude session ID
    @Published var beadSessions: [String: String] = [:]

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

    // MARK: - Data (via factory CLI until MySQLNIO is added via Xcode UI)

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

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
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch { return nil }
    }

    func investigate(beadId: String) {
        let cmuxCLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let jiraKey = beadId.uppercased()

        // Check if there's an existing session for this bead
        if let sessionId = beadSessions[beadId] {
            // Resume existing session in a new workspace
            let cmd = "claude --resume \(sessionId) --dangerously-skip-permissions --mcp-config ~/.factory/mcp-servers.json"
            Task {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cmuxCLI)
                process.arguments = ["new-workspace", "--name", "\(jiraKey) ↩", "--command", cmd]
                try? process.run()
            }
            return
        }

        // New investigation — load formula from ~/.factory/formulas/
        Task {
            await loadDetail(for: beadId)

            // Load investigate formula from disk and template with bead context
            let template = FactoryConfig.readFormula("investigate")
                ?? "# Investigate {{BEAD_ID}}: {{TITLE}}\n\n{{DESCRIPTION}}\n\nExplore the codebase and report findings."
            let systemPrompt = templateFormula(template, beadId: beadId, jiraKey: jiraKey)

            let promptFile = "/tmp/factory-investigate-\(beadId).md"
            try? systemPrompt.write(toFile: promptFile, atomically: true, encoding: .utf8)

            let sessionName = "factory-\(beadId)"
            let kickoff = "Investigate \(jiraKey). Read your system prompt for the full ticket description. Explore the codebase, assess what needs to change, and give me your findings and a proposed plan."
                .replacingOccurrences(of: "'", with: "'\\''")

            let cmd = "(sleep 5 && cmux send --workspace $CMUX_WORKSPACE_ID '\(kickoff)\\n') & claude --dangerously-skip-permissions --system-prompt-file \(promptFile) --mcp-config ~/.factory/mcp-servers.json --name \(sessionName)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmuxCLI)
            process.arguments = ["new-workspace", "--name", jiraKey, "--command", cmd]
            try? process.run()
        }
    }

    /// Look up a Claude session ID by name
    private func lookupClaudeSession(name: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude", "sessions", "--json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for session in json {
                    if let title = session["title"] as? String, title.contains(name),
                       let id = session["id"] as? String {
                        return id
                    }
                }
            }
        } catch {}
        return nil
    }

    func delegate(beadId: String, formula: String = "implement") {
        let cmuxCLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let jiraKey = beadId.uppercased()

        Task {
            await loadDetail(for: beadId)

            // Load formula from ~/.factory/formulas/ and template with bead context
            let template = FactoryConfig.readFormula(formula)
                ?? "# \(formula.capitalized) {{BEAD_ID}}: {{TITLE}}\n\n{{DESCRIPTION}}"
            let systemPrompt = templateFormula(template, beadId: beadId, jiraKey: jiraKey)

            // Include child beads for epics
            var childContext = ""
            if selectedDetail?.isEpic == true {
                if let childJson = await runFactory(["list", "--epic", beadId, "--json"]),
                   let data = childJson.data(using: .utf8),
                   let children = try? JSONDecoder().decode([CLIBeadSummary].self, from: data) {
                    childContext = "\n\n## Child Beads\n" + children.map {
                        "- \($0.id.uppercased()) [\($0.status)] \($0.title)"
                    }.joined(separator: "\n")
                }
            }

            let promptFile = "/tmp/factory-\(formula)-\(beadId).md"
            try? (systemPrompt + childContext).write(toFile: promptFile, atomically: true, encoding: .utf8)

            let sessionName = "factory-\(beadId)"
            let kickoff = "\(formula.capitalized) \(jiraKey). Read your system prompt and begin."
                .replacingOccurrences(of: "'", with: "'\\''")

            let cmd = "(sleep 5 && cmux send --workspace $CMUX_WORKSPACE_ID '\(kickoff)\\n') & claude --dangerously-skip-permissions --system-prompt-file \(promptFile) --mcp-config ~/.factory/mcp-servers.json --name \(sessionName)"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cmuxCLI)
            process.arguments = ["new-workspace", "--name", "\(formula)-\(jiraKey)", "--command", cmd]
            try? process.run()
        }
    }

    // MARK: - Template Helper

    private func templateFormula(_ template: String, beadId: String, jiraKey: String) -> String {
        template
            .replacingOccurrences(of: "{{BEAD_ID}}", with: beadId)
            .replacingOccurrences(of: "{{BEAD_ID_UPPER}}", with: jiraKey)
            .replacingOccurrences(of: "{{BEAD_ID_LOWER}}", with: beadId.lowercased())
            .replacingOccurrences(of: "{{TITLE}}", with: selectedDetail?.title ?? "")
            .replacingOccurrences(of: "{{DESCRIPTION}}", with: selectedDetail?.description ?? "")
            .replacingOccurrences(of: "{{PARENT_ID}}", with: selectedDetail?.parent ?? "none")
            .replacingOccurrences(of: "{{PR_NUMBER}}", with: "")
            .replacingOccurrences(of: "{{PR_REF}}", with: "")
            .replacingOccurrences(of: "{{REPO}}", with: "")
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

// MARK: - CLI JSON Bridge (until MySQLNIO is added via Xcode UI)

private struct CLIBeadSummary: Decodable {
    let id: String; let title: String; let status: String
    let jira_status: String?; let priority: Int; let issue_type: String
    let assignee: String?; let labels: [String]?; let parent: String?
    let pr: String?; let pr_state: String?; let ci: String?
    let review: String?; let attention: [String]?

    func toBeadSummary() -> BeadSummary {
        BeadSummary(id: id, title: title, status: status,
            jiraStatus: jira_status, priority: priority, issueType: issue_type,
            assignee: assignee, labels: labels ?? [], parent: parent,
            pr: pr, prState: pr_state, ci: ci, review: review,
            attention: attention ?? [])
    }
}

private struct CLIBeadDetail: Decodable {
    let id: String; let title: String; let description: String?
    let status: String; let priority: Int; let issue_type: String?
    let assignee: String?; let external_ref: String?; let parent: String?
    let labels: [String]?; let created_at: String?; let updated_at: String?

    func toBeadDetail() -> BeadDetail {
        BeadDetail(id: id, title: title, description: description ?? "",
            status: status, jiraStatus: nil, priority: priority,
            issueType: issue_type, assignee: assignee,
            externalRef: external_ref, parent: parent,
            labels: labels ?? [], createdAt: created_at, updatedAt: updated_at)
    }
}
