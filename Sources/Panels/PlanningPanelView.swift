import SwiftUI

/// SwiftUI view for the Factory PlanningPanel.
/// Shows beads sidebar on the left, plan/detail on the right.
struct PlanningPanelView: View {
    @ObservedObject var panel: PlanningPanel

    var body: some View {
        HSplitView {
            // Left: Beads list
            beadsSidebar
                .frame(minWidth: 260, maxWidth: 380)

            // Right: Detail / Plan
            detailView
                .frame(minWidth: 400)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            await panel.refresh()
        }
    }

    // MARK: - Sidebar

    private var beadsSidebar: some View {
        VStack(spacing: 0) {
            // Filters
            VStack(spacing: 8) {
                // Assignment filter
                HStack(spacing: 4) {
                    ForEach(AssignmentFilter.allCases, id: \.self) { filter in
                        Button(filter.rawValue) {
                            panel.assignmentFilter = filter
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            panel.assignmentFilter == filter
                                ? Color.accentColor.opacity(0.2)
                                : Color.clear
                        )
                        .cornerRadius(6)
                        .font(.caption)
                    }
                    Spacer()
                    Button {
                        Task { await panel.refresh() }
                    } label: {
                        Image(systemName: panel.isLoading ? "arrow.clockwise" : "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .disabled(panel.isLoading)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            Divider()

            // Beads list grouped by status
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let grouped = Dictionary(grouping: panel.beads, by: \.status)
                    let statusOrder = ["In Progress", "In Review", "In Staging",
                                       "Selected for Development", "Blocked", "Backlog", "open"]

                    ForEach(statusOrder, id: \.self) { status in
                        if let beads = grouped[status], !beads.isEmpty {
                            statusSection(status: status, beads: beads)
                        }
                    }
                }
            }

            Divider()

            // Status bar
            HStack {
                Text("VIS · \(panel.beads.count) beads")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let sync = panel.lastSync {
                    Text(sync, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func statusSection(status: String, beads: [BeadSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
                Text(status.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(statusColor(status))
                Text("\(beads.count)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            ForEach(beads) { bead in
                beadRow(bead)
            }
        }
    }

    private func beadRow(_ bead: BeadSummary) -> some View {
        Button {
            panel.selectedBeadId = bead.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if bead.isEpic {
                        Text("◆")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                    Text(bead.jiraKey)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                    Spacer()
                    Text("P\(bead.priority)")
                        .font(.caption2)
                        .foregroundColor(priorityColor(bead.priority))
                }
                Text(bead.title)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if !bead.attention.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(bead.attention, id: \.self) { flag in
                            Text(attentionLabel(flag))
                                .font(.system(size: 9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .cornerRadius(3)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                panel.selectedBeadId == bead.id
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        if let beadId = panel.selectedBeadId,
           let bead = panel.beads.first(where: { $0.id == beadId }) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(bead.jiraKey)
                            .font(.headline)
                            .foregroundColor(.blue)
                        if bead.isEpic {
                            Text("EPIC")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                        Text(bead.status)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(statusColor(bead.status).opacity(0.2))
                            .foregroundColor(statusColor(bead.status))
                            .cornerRadius(4)
                        Spacer()
                    }
                    Text(bead.title)
                        .font(.title3)
                        .fontWeight(.medium)
                }
                .padding(16)

                Divider()

                // Actions
                HStack(spacing: 8) {
                    Button {
                        panel.investigate(beadId: beadId)
                    } label: {
                        Label("Investigate", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        panel.delegate(beadId: beadId)
                    } label: {
                        Label("Delegate", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        // TODO: open plan
                    } label: {
                        Label("Plan", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                // Placeholder for plan content / description
                ScrollView {
                    Text("Select a bead to view its plan and details.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(16)
                }
            }
        } else {
            VStack {
                Spacer()
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.3))
                Text("Select a bead to view details")
                    .font(.body)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    // MARK: - Helpers

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "In Progress": return .blue
        case "In Review": return .purple
        case "In Staging": return .green
        case "Selected for Development": return .orange
        case "Blocked": return .red
        case "Backlog", "open": return .gray
        default: return .secondary
        }
    }

    private func priorityColor(_ priority: Int) -> Color {
        switch priority {
        case 0: return .red
        case 1: return .orange
        case 2: return .yellow
        case 3: return .green
        default: return .gray
        }
    }

    private func attentionLabel(_ flag: String) -> String {
        switch flag {
        case "ci-failing": return "🔴 CI"
        case "review-feedback": return "💬 Review"
        case "missing-pr": return "⚠ No PR"
        case "status-divergence": return "↕ Sync"
        default: return flag
        }
    }
}
