import Foundation

// MARK: - On-disk shape written by the Claude Code session-log hooks

struct SessionSummaryEntry: Codable {
    let at: String
    let bullets: [String]
}

struct SessionRecord: Codable {
    let session_id: String
    let session_name: String?
    let cwd: String
    let started_at: String
    let session_summary: [SessionSummaryEntry]
}

// MARK: - In-memory index

struct IndexEntry {
    let sessionId: String
    let sessionName: String
    let cwd: String
    let startedAt: String
    /// Lowercased session name + every summary bullet, flattened for keyword scoring.
    let text: String
}

struct ScoredEntry {
    let entry: IndexEntry
    let score: Int
}

// MARK: - What the panel renders, one per visible row

struct SearchResultRow {
    let sessionName: String
    /// Folder name only (e.g. "Modulaa"), shown as the dimmed subtitle.
    let projectName: String
    /// Short snippet of matching summary text, shown under the title.
    let snippet: String
    let command: String  // claude --resume "<sessionName>"
    /// Full path of the folder the session ran in; Enter cd's here before resuming.
    let cwd: String
}

// MARK: - Logging records

struct SearchOutcome {
    let query: String
    let sessionName: String
    /// "instant_keyword" | "qwen_rerank" | "no_match"
    let source: String
    let durationMs: Double
    /// 0-based row position the user actually chose, nil if never chosen.
    let selectedRank: Int?
}
