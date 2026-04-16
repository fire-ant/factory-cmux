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

    // Beads state
    @Published var beads: [BeadSummary] = []
    @Published var epics: [EpicInfo] = []
    @Published var selectedBeadId: String?
    @Published var selectedDetail: BeadDetail?
    @Published var epicFilter: String = "all"
    @Published var assignmentFilter: AssignmentFilter = .mine
    @Published var isLoading = false
    @Published var lastSync: Date?

    private var refreshTimer: Timer?
    private let doltHost: String
    private let doltPort: UInt16
    private let doltDatabase: String

    public init(
        id: UUID = UUID(),
        doltHost: String = "127.0.0.1",
        doltPort: UInt16 = 59300,
        doltDatabase: String = "vis"
    ) {
        self.id = id
        self.doltHost = doltHost
        self.doltPort = doltPort
        self.doltDatabase = doltDatabase
    }

    public func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    public func focus() {
        startRefreshTimer()
        Task { await refresh() }
    }

    public func unfocus() {
        // Keep timer running for background updates
    }

    public func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        // TODO: implement attention flash
    }

    // MARK: - Data Loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // TODO: Connect to Dolt via MySQL and fetch beads
        // For now, use the factory CLI as a bridge
        await loadBeadsViaCLI()
        lastSync = Date()
    }

    func sync() async {
        isLoading = true
        defer { isLoading = false }

        // Run factory sync command
        let result = await runFactoryCLI(["sync"])
        print("[planning] sync: \(result ?? "no output")")
        await refresh()
    }

    func investigate(beadId: String) {
        // Open a new terminal workspace with claude investigating this bead
        Task {
            let _ = await runFactoryCLI(["investigate", beadId])
        }
    }

    func delegate(beadId: String, formula: String = "implement") {
        Task {
            let _ = await runFactoryCLI(["delegate", beadId, "--formula", formula])
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

    private func loadBeadsViaCLI() async {
        // Use factory list --json (once we add JSON output)
        // For now, parse the text output
        guard let output = await runFactoryCLI(["list"]) else { return }

        var newBeads: [BeadSummary] = []
        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Parse: "VIS-2228   [Selected for Development] P2 Title..."
            let parts = trimmed.components(separatedBy: CharacterSet.whitespaces)
            guard parts.count >= 3 else { continue }

            let id = parts[0].lowercased()
            // Extract status from brackets
            var status = "open"
            if let startBracket = trimmed.firstIndex(of: "["),
               let endBracket = trimmed.firstIndex(of: "]") {
                status = String(trimmed[trimmed.index(after: startBracket)..<endBracket])
                    .trimmingCharacters(in: .whitespaces)
            }

            let bead = BeadSummary(
                id: id,
                title: String(trimmed.suffix(from: trimmed.index(after: trimmed.firstIndex(of: "]") ?? trimmed.startIndex)))
                    .trimmingCharacters(in: .whitespaces),
                status: status,
                priority: 2,
                issueType: "task",
                attention: []
            )
            newBeads.append(bead)
        }
        self.beads = newBeads
    }

    private func runFactoryCLI(_ args: [String]) async -> String? {
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
            print("[planning] CLI error: \(error)")
            return nil
        }
    }
}

// MARK: - Data Types

struct BeadSummary: Identifiable {
    let id: String
    let title: String
    let status: String
    let priority: Int
    let issueType: String
    let attention: [String]

    var isEpic: Bool { issueType == "epic" }
    var jiraKey: String { id.uppercased() }
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
    let externalRef: String?
    let parent: String?
    let labels: [String]
}

enum AssignmentFilter: String, CaseIterable {
    case mine = "Mine"
    case open = "Open"
    case all = "All"
}
