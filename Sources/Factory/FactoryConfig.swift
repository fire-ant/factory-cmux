import Foundation

/// Reads configuration and resources from ~/.factory/
/// All files are on disk — Claude and users can edit them without rebuilding.
struct FactoryConfig {
    static let baseDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".factory")

    static let formulasDir = baseDir.appendingPathComponent("formulas")
    static let promptsDir = baseDir.appendingPathComponent("prompts")
    static let agentsDir = baseDir.appendingPathComponent("agents")
    static let plansDir = baseDir.appendingPathComponent("plans")
    static let configFile = baseDir.appendingPathComponent("config.toml")

    // MARK: - Formulas

    /// List available formula names (without .md extension)
    static func availableFormulas() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: formulasDir, includingPropertiesForKeys: nil
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "plan-template.md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Read a formula template
    static func readFormula(_ name: String) -> String? {
        let path = formulasDir.appendingPathComponent("\(name).md")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Read the plan template
    static func readPlanTemplate() -> String? {
        let path = formulasDir.appendingPathComponent("plan-template.md")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - Prompts

    /// Read a system prompt
    static func readPrompt(_ name: String) -> String? {
        let path = promptsDir.appendingPathComponent("\(name).md")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    // MARK: - Plans

    /// Read a plan for a bead
    static func readPlan(beadId: String) -> String? {
        let path = plansDir.appendingPathComponent("\(beadId).md")
        return try? String(contentsOf: path, encoding: .utf8)
    }

    /// Check if a plan exists for a bead
    static func hasPlan(beadId: String) -> Bool {
        let path = plansDir.appendingPathComponent("\(beadId).md")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Write a plan for a bead
    static func writePlan(beadId: String, content: String) {
        let path = plansDir.appendingPathComponent("\(beadId).md")
        try? content.write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - Config Values

    /// Read a value from config.toml (simple key lookup)
    static func configValue(section: String, key: String) -> String? {
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else { return nil }

        var inSection = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[\(section)]") {
                inSection = true
                continue
            }
            if trimmed.hasPrefix("[") && inSection {
                break // Next section
            }
            if inSection && trimmed.hasPrefix("\(key)") {
                if let eqIdx = trimmed.firstIndex(of: "=") {
                    let value = trimmed[trimmed.index(after: eqIdx)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    return value
                }
            }
        }
        return nil
    }

    static var doltHost: String { configValue(section: "dolt", key: "host") ?? "127.0.0.1" }
    static var doltPort: Int { Int(configValue(section: "dolt", key: "port") ?? "59300") ?? 59300 }
    static var doltDatabase: String { configValue(section: "dolt", key: "database") ?? "vis" }
    static var githubUsername: String { configValue(section: "user", key: "github_username") ?? "fire-ant" }
    static var jiraEmail: String { configValue(section: "user", key: "jira_email") ?? "" }

    // MARK: - Setup

    /// Ensure ~/.factory/ exists with default structure
    static func ensureDefaults() {
        let dirs = [baseDir, formulasDir, promptsDir, agentsDir, plansDir]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
