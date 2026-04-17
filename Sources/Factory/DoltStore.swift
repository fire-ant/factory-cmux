import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import Logging

/// Connects to the Dolt SQL server and provides beads CRUD operations.
/// Direct in-process database access — no CLI subprocess needed.
@MainActor
final class DoltStore: ObservableObject {
    private var connection: MySQLConnection?
    private let eventLoopGroup: EventLoopGroup
    private let logger: Logger

    let host: String
    let port: Int
    let database: String

    @Published var isConnected = false
    @Published var lastError: String?

    init(host: String = "127.0.0.1", port: Int = 59300, database: String = "vis") {
        self.host = host
        self.port = port
        self.database = database
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.logger = Logger(label: "factory.dolt")
    }

    // MARK: - Connection

    func connect() async {
        do {
            let addr = try SocketAddress.makeAddressResolvingHost(host, port: port)
            let conn = try await MySQLConnection.connect(
                to: addr,
                username: "root",
                database: database,
                password: "",
                tlsConfiguration: nil,
                on: eventLoopGroup.next(),
                logger: logger
            ).get()
            self.connection = conn
            self.isConnected = true
            self.lastError = nil
        } catch {
            self.lastError = "Dolt connect: \(error.localizedDescription)"
            self.isConnected = false
        }
    }

    func disconnect() {
        try? connection?.close().wait()
        connection = nil
        isConnected = false
    }

    // MARK: - Queries

    func listBeads(status: String? = nil) async -> [BeadSummary] {
        guard let conn = connection else { return [] }

        let sql: String
        if let status = status {
            sql = "SELECT id, title, status, priority, issue_type, assignee FROM issues WHERE status = '\(status)' ORDER BY priority, title"
        } else {
            sql = "SELECT id, title, status, priority, issue_type, assignee FROM issues ORDER BY status, priority, title"
        }

        do {
            let rows = try await conn.query(sql, []).get()
            var beads: [BeadSummary] = []

            for row in rows {
                let id = row.column("id")?.string ?? ""
                let labels = await getLabels(for: id)

                let jiraStatus = labels.first { $0.hasPrefix("jira-status:") }
                    .map { String($0.dropFirst("jira-status:".count)) }
                let pr = labels.first { $0.hasPrefix("pr:") }
                    .map { String($0.dropFirst("pr:".count)) }
                let prState = labels.first { $0.hasPrefix("pr-state:") }
                    .map { String($0.dropFirst("pr-state:".count)) }
                let ci = labels.first { $0.hasPrefix("ci:") }
                    .map { String($0.dropFirst("ci:".count)) }
                let review = labels.first { $0.hasPrefix("review:") }
                    .map { String($0.dropFirst("review:".count)) }
                let attention = labels.filter { $0.hasPrefix("needs-attention:") }
                    .map { String($0.dropFirst("needs-attention:".count)) }
                let displayLabels = labels.filter {
                    !$0.hasPrefix("jira-status:") && !$0.hasPrefix("pr:") &&
                    !$0.hasPrefix("pr-state:") && !$0.hasPrefix("ci:") &&
                    !$0.hasPrefix("review:") && !$0.hasPrefix("needs-attention:") &&
                    !$0.hasPrefix("sync:")
                }
                let parent = await getParentEpic(for: id)

                beads.append(BeadSummary(
                    id: id,
                    title: row.column("title")?.string ?? "",
                    status: row.column("status")?.string ?? "open",
                    jiraStatus: jiraStatus,
                    priority: row.column("priority")?.int ?? 2,
                    issueType: row.column("issue_type")?.string ?? "task",
                    assignee: row.column("assignee")?.string,
                    labels: displayLabels,
                    parent: parent,
                    pr: pr, prState: prState, ci: ci, review: review,
                    attention: attention
                ))
            }
            return beads
        } catch {
            lastError = "list: \(error.localizedDescription)"
            return []
        }
    }

    func showBead(id: String) async -> BeadDetail? {
        guard let conn = connection else { return nil }

        do {
            let rows = try await conn.query(
                "SELECT id, title, description, status, priority, issue_type, assignee, external_ref, created_at, updated_at FROM issues WHERE id = ?",
                [.init(string: id)]
            ).get()

            guard let row = rows.first else { return nil }
            let labels = await getLabels(for: id)
            let jiraStatus = labels.first { $0.hasPrefix("jira-status:") }
                .map { String($0.dropFirst("jira-status:".count)) }
            let parent = await getParentEpic(for: id)

            return BeadDetail(
                id: row.column("id")?.string ?? id,
                title: row.column("title")?.string ?? "",
                description: row.column("description")?.string ?? "",
                status: row.column("status")?.string ?? "open",
                jiraStatus: jiraStatus,
                priority: row.column("priority")?.int ?? 2,
                issueType: row.column("issue_type")?.string,
                assignee: row.column("assignee")?.string,
                externalRef: row.column("external_ref")?.string,
                parent: parent,
                labels: labels.filter { !$0.hasPrefix("jira-status:") && !$0.hasPrefix("needs-attention:") },
                createdAt: row.column("created_at")?.string,
                updatedAt: row.column("updated_at")?.string
            )
        } catch {
            lastError = "show: \(error.localizedDescription)"
            return nil
        }
    }

    func listEpics() async -> [EpicInfo] {
        guard let conn = connection else { return [] }

        do {
            let rows = try await conn.query(
                "SELECT id, title, status FROM issues WHERE issue_type = 'epic' ORDER BY priority, title", []
            ).get()

            var epics: [EpicInfo] = []
            for row in rows {
                let id = row.column("id")?.string ?? ""
                let countRows = try await conn.query(
                    "SELECT COUNT(*) as cnt FROM dependencies WHERE depends_on_id = ?",
                    [.init(string: id)]
                ).get()
                let count = countRows.first?.column("cnt")?.int ?? 0
                epics.append(EpicInfo(id: id, title: row.column("title")?.string ?? "", childCount: count))
            }
            return epics
        } catch {
            lastError = "epics: \(error.localizedDescription)"
            return []
        }
    }

    func listChildren(epicId: String) async -> [BeadSummary] {
        guard let conn = connection else { return [] }

        do {
            let rows = try await conn.query(
                "SELECT i.id, i.title, i.status, i.priority, i.issue_type, i.assignee FROM issues i JOIN dependencies d ON d.issue_id = i.id WHERE d.depends_on_id = ? ORDER BY i.priority, i.title",
                [.init(string: epicId)]
            ).get()

            return rows.map { row in
                BeadSummary(
                    id: row.column("id")?.string ?? "",
                    title: row.column("title")?.string ?? "",
                    status: row.column("status")?.string ?? "open",
                    jiraStatus: nil, priority: row.column("priority")?.int ?? 2,
                    issueType: row.column("issue_type")?.string ?? "task",
                    assignee: row.column("assignee")?.string,
                    labels: [], parent: epicId,
                    pr: nil, prState: nil, ci: nil, review: nil, attention: []
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - Private

    private func getLabels(for issueId: String) async -> [String] {
        guard let conn = connection else { return [] }
        do {
            let rows = try await conn.query("SELECT label FROM labels WHERE issue_id = ?", [.init(string: issueId)]).get()
            return rows.compactMap { $0.column("label")?.string }
        } catch { return [] }
    }

    private func getParentEpic(for issueId: String) async -> String? {
        guard let conn = connection else { return nil }
        do {
            let rows = try await conn.query(
                "SELECT d.depends_on_id FROM dependencies d JOIN issues i ON d.depends_on_id = i.id WHERE d.issue_id = ? AND i.issue_type = 'epic' LIMIT 1",
                [.init(string: issueId)]
            ).get()
            return rows.first?.column("depends_on_id")?.string
        } catch { return nil }
    }

    deinit {
        try? eventLoopGroup.syncShutdownGracefully()
    }
}
