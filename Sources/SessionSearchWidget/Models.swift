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
    /// Claude's own auto-title, else the hook-written name, else the first thing you typed.
    let sessionName: String
    let cwd: String
    let startedAt: String
    /// Lowercased title + everything you typed in that session + any hook summary bullets.
    let text: String
}

/// One transcript's parsed contents, kept on disk so the 222 MB of transcripts are only
/// read once. A file is re-parsed only when its size or modification date changes.
struct CachedTranscript: Codable {
    let sessionId: String
    let path: String
    let modifiedAt: Double
    let byteSize: Int
    let title: String
    let cwd: String
    let startedAt: String
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
