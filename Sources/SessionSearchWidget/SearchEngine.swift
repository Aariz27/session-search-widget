import Foundation

// MARK: - Index building

enum SessionIndex {
    /// Everything you typed in one session, capped so a very long transcript cannot
    /// dominate memory. 20k characters is roughly 3-4k words, plenty to match on.
    private static let maxTextPerSession = 20_000

    /// Text that Claude Code or my own hooks injected into the transcript rather than
    /// text you actually typed. Indexing it would match every session on the same words.
    private static let injectedPrefixes = [
        "<command-name>",
        "<local-command",
        "<system-reminder",
        "<user-prompt-submit-hook",
        "caveat: the messages below",
        "summarize this excerpt of a claude code session transcript",
        "this session is being continued from a previous conversation",
        "[request interrupted",
        "api error",
    ]

    /// Builds the searchable list from every real Claude Code transcript on this machine,
    /// then folds in the 3-bullet summaries the hooks write into each project's sessions.json.
    static func build() -> [IndexEntry] {
        let transcripts = mergeForks(loadTranscripts())
        let summaries = loadHookSummaries()

        return transcripts.map { transcript in
            var title = transcript.title
            var textParts = [title, transcript.text]

            // A hook summary, when one exists, is the most accurate description of the
            // session, so its name wins and its bullets get added to the searchable text.
            if let summary = summaries[transcript.sessionId] {
                if let name = summary.session_name, !name.isEmpty {
                    title = name
                    textParts.insert(name, at: 0)
                }
                for entry in summary.session_summary {
                    textParts.append(contentsOf: entry.bullets)
                }
            }

            return IndexEntry(
                sessionId: transcript.sessionId,
                sessionName: title,
                cwd: transcript.cwd,
                startedAt: transcript.startedAt,
                text: textParts.joined(separator: " ").lowercased()
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: Collapsing resume and compaction forks

    /// Every time you resume or compact a session, Claude Code writes a new transcript file
    /// and copies the earlier messages into it, so one conversation ends up spread over
    /// several files with the same title. This groups files that share any message id and
    /// returns one entry per conversation: the file you would actually resume, carrying the
    /// combined text of every file in the group.
    ///
    /// Grouping is transitive. A resume of a resume shares no message with the original
    /// once compaction has dropped the early messages, but the middle file links the two.
    static func mergeForks(_ transcripts: [CachedTranscript]) -> [CachedTranscript] {
        guard transcripts.count > 1 else { return transcripts }

        var parent = Array(0..<transcripts.count)

        func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        func union(_ a: Int, _ b: Int) {
            let rootA = root(a)
            let rootB = root(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        // One pass over every message id: the first file to claim an id owns it, and any
        // later file carrying the same id joins that file's group.
        var owner: [String: Int] = [:]
        for (position, transcript) in transcripts.enumerated() {
            for messageId in transcript.messageIds {
                if let existing = owner[messageId] {
                    union(existing, position)
                } else {
                    owner[messageId] = position
                }
            }
        }

        var groups: [Int: [CachedTranscript]] = [:]
        for (position, transcript) in transcripts.enumerated() {
            groups[root(position), default: []].append(transcript)
        }

        return groups.values.map { group in
            guard group.count > 1 else { return group[0] }

            // Resume the file that was written to most recently: that is the live one.
            let newest = group.max { $0.modifiedAt < $1.modifiedAt }!

            // A real title Claude wrote beats a fallback built from your opening words.
            let titled = group.first { $0.hasAiTitle }
            let title = titled?.title ?? newest.title

            // The conversation began when its earliest file began.
            let earliestStart = group.compactMap { $0.startedAt.isEmpty ? nil : $0.startedAt }.min() ?? newest.startedAt

            // Keep the text of every file so a search still finds words that only survive
            // in an older copy. The longest copy is the base; a shorter copy is appended
            // whole only when the base does not already contain it, which keeps the
            // sentences readable for the snippet shown under each result.
            let byLength = group.sorted { $0.text.count > $1.text.count }
            var combined = byLength[0].text
            for transcript in byLength.dropFirst() where !transcript.text.isEmpty {
                if !combined.contains(transcript.text) {
                    combined += " " + transcript.text
                }
            }

            return CachedTranscript(
                sessionId: newest.sessionId,
                path: newest.path,
                modifiedAt: newest.modifiedAt,
                byteSize: newest.byteSize,
                title: title,
                hasAiTitle: titled != nil,
                cwd: newest.cwd,
                startedAt: earliestStart,
                text: String(combined.prefix(maxTextPerSession)),
                messageIds: []
            )
        }
    }

    // MARK: Transcripts

    /// Reads every `<uuid>.jsonl` under ~/.claude/projects, reusing the on-disk cache for
    /// files that have not changed since the last run.
    private static func loadTranscripts() -> [CachedTranscript] {
        let fileManager = FileManager.default
        let root: URL
        if let overridePath = ProcessInfo.processInfo.environment["SSW_TRANSCRIPT_ROOT"], !overridePath.isEmpty {
            root = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        }

        var cache: [String: CachedTranscript] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([CachedTranscript].self, from: data) {
            for entry in cached { cache[entry.sessionId] = entry }
        }

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [CachedTranscript] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let sessionId = fileURL.deletingPathExtension().lastPathComponent
            guard isSessionId(sessionId) else { continue }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let byteSize = values?.fileSize ?? 0

            if let hit = cache[sessionId], hit.modifiedAt == modifiedAt, hit.byteSize == byteSize {
                results.append(hit)
                continue
            }

            if let parsed = parseTranscript(at: fileURL, sessionId: sessionId, modifiedAt: modifiedAt, byteSize: byteSize) {
                results.append(parsed)
            }
        }

        if let data = try? JSONEncoder().encode(results) {
            try? data.write(to: cacheURL)
        }

        return results
    }

    /// A session transcript is named after its UUID; subagent runs, skill-injections and
    /// journals live in the same folders and must not appear as sessions you can resume.
    private static func isSessionId(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        for (part, length) in zip(parts, lengths) {
            guard part.count == length else { return false }
            guard part.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

    private static var cacheURL: URL {
        SearchLog.programDir.appendingPathComponent("transcript-cache.json")
    }

    /// Walks one transcript line by line and keeps the title, the folder it ran in, the
    /// start time and everything you typed.
    private static func parseTranscript(at url: URL, sessionId: String, modifiedAt: Double, byteSize: Int) -> CachedTranscript? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var aiTitle = ""
        var cwd = ""
        var startedAt = ""
        var typedText = ""
        var messageIds: [String] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard let type = object["type"] as? String else { continue }

            if type == "ai-title", let value = object["aiTitle"] as? String, !value.isEmpty {
                aiTitle = value
                continue
            }

            if let messageId = object["uuid"] as? String, !messageId.isEmpty {
                messageIds.append(messageId)
            }

            guard type == "user" else { continue }
            if object["isMeta"] as? Bool == true { continue }
            if object["isSidechain"] as? Bool == true { continue }

            if cwd.isEmpty, let value = object["cwd"] as? String { cwd = value }
            if startedAt.isEmpty, let value = object["timestamp"] as? String { startedAt = value }

            guard typedText.count < maxTextPerSession else { continue }
            guard let message = object["message"] as? [String: Any] else { continue }
            let text = userText(from: message["content"])
            guard !text.isEmpty, !isInjected(text) else { continue }

            typedText += text + " "
        }

        // A transcript with nothing you typed is a stub Claude Code left behind.
        guard !typedText.isEmpty else { return nil }

        if cwd.isEmpty {
            cwd = FileManager.default.homeDirectoryForCurrentUser.path
        }

        let title = aiTitle.isEmpty ? firstLineTitle(from: typedText) : aiTitle

        return CachedTranscript(
            sessionId: sessionId,
            path: url.path,
            modifiedAt: modifiedAt,
            byteSize: byteSize,
            title: title,
            hasAiTitle: !aiTitle.isEmpty,
            cwd: cwd,
            startedAt: startedAt,
            text: String(typedText.prefix(maxTextPerSession)),
            messageIds: messageIds
        )
    }

    /// A user message is either a plain string or a list of blocks; only the text blocks matter.
    private static func userText(from content: Any?) -> String {
        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var pieces: [String] = []
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { pieces.append(text) }
        }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isInjected(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for prefix in injectedPrefixes where lowered.hasPrefix(prefix) { return true }
        return false
    }

    /// Falls back to the opening words you typed, which read well enough as a title.
    private static func firstLineTitle(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 70 else { return cleaned }
        let cut = cleaned.prefix(70)
        if let lastSpace = cut.lastIndex(of: " ") {
            return String(cut[cut.startIndex..<lastSpace]) + "…"
        }
        return String(cut) + "…"
    }

    // MARK: Hook summaries

    /// Reads every sessions.json the hooks wrote under ~/Documents, keyed by session id.
    /// Nothing here is written to; the hooks stay exactly as they are.
    private static func loadHookSummaries() -> [String: SessionRecord] {
        let fileManager = FileManager.default
        let root: URL
        if let overridePath = ProcessInfo.processInfo.environment["SSW_INDEX_ROOT"], !overridePath.isEmpty {
            root = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        }

        var summaries: [String: SessionRecord] = [:]

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return summaries
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "sessions.json" else { continue }
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else { continue }
            for record in records { summaries[record.session_id] = record }
        }

        return summaries
    }
}

// MARK: - Search / ranking

enum SessionSearch {
    /// Keyword-scores every entry; returns the best `limit`, highest score first, zero-score entries dropped.
    static func rank(query: String, index: [IndexEntry], limit: Int = 30) -> [ScoredEntry] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var scored: [ScoredEntry] = []
        scored.reserveCapacity(index.count)

        for entry in index {
            var matchCount = 0
            for token in tokens {
                if entry.text.contains(token) {
                    matchCount += 1
                }
            }
            if matchCount > 0 {
                scored.append(ScoredEntry(entry: entry, score: matchCount))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.entry.startedAt > rhs.entry.startedAt
        }

        if scored.count > limit {
            return Array(scored[0..<limit])
        }
        return scored
    }

    /// Builds the display rows (incl. the `claude --resume "..."` command string) from scored entries.
    static func rows(from scored: [ScoredEntry], query: String) -> [SearchResultRow] {
        let tokens = tokenize(query)

        return scored.map { scoredEntry in
            let entry = scoredEntry.entry
            let projectName = (entry.cwd as NSString).lastPathComponent
            let snippet = makeSnippet(text: entry.text, tokens: tokens)
            // Resume by session id, not by name: most transcripts have no hook-written
            // name, and `claude --resume` takes the id directly.
            let command = "claude --resume \(entry.sessionId)"
            return SearchResultRow(
                sessionId: entry.sessionId,
                sessionName: entry.sessionName,
                projectName: projectName,
                snippet: snippet,
                command: command,
                cwd: entry.cwd
            )
        }
    }

    private static func tokenize(_ query: String) -> [String] {
        let lowered = query.lowercased()
        let pieces = lowered.split { char in
            !(char.isLetter || char.isNumber)
        }
        return pieces.map(String.init).filter { !$0.isEmpty }
    }

    private static func makeSnippet(text: String, tokens: [String]) -> String {
        let windowRadius = 45
        let maxLength = 90

        var matchRange: Range<String.Index>?
        for token in tokens {
            if let range = text.range(of: token) {
                matchRange = range
                break
            }
        }

        let start: String.Index
        let end: String.Index
        var truncatedStart = false
        var truncatedEnd = false

        if let matchRange {
            let midpoint = matchRange.lowerBound
            if let candidateStart = text.index(midpoint, offsetBy: -windowRadius, limitedBy: text.startIndex) {
                start = candidateStart
                truncatedStart = true
            } else {
                start = text.startIndex
            }
            if let candidateEnd = text.index(midpoint, offsetBy: maxLength - windowRadius, limitedBy: text.endIndex) {
                end = candidateEnd
                truncatedEnd = end != text.endIndex
            } else {
                end = text.endIndex
            }
        } else {
            start = text.startIndex
            if let candidateEnd = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) {
                end = candidateEnd
                truncatedEnd = end != text.endIndex
            } else {
                end = text.endIndex
            }
        }

        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if truncatedStart {
            snippet = "…" + snippet
        }
        if truncatedEnd {
            snippet = snippet + "…"
        }
        return snippet
    }
}

// MARK: - Semantic ranking with headless Claude (Haiku)

/// The semantic mode you reach by pressing Tab. It shells out to the `claude` command with
/// `--model haiku`, which bills your Claude subscription, so nothing here runs unless you
/// explicitly switch the panel into semantic mode.
enum HaikuRerank {
    /// Locations to look for the `claude` command. A GUI app launched from Finder does not
    /// inherit your shell PATH, so guessing from PATH alone is not enough.
    private static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    /// Resolved once: the full path of the `claude` command, or nil when it is not installed.
    static let executablePath: String? = {
        let fileManager = FileManager.default
        for path in searchPaths where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask the login shell where it is.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let found = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return found.isEmpty ? nil : found
    }()

    static var isAvailable: Bool { executablePath != nil }

    /// Asks Haiku to reorder the candidates by what you actually meant. Returns session ids
    /// in the model's preferred order, or nil when the command is missing, times out, or
    /// replies with something that contains no numbers.
    static func rank(query: String, candidates: [ScoredEntry], timeout: TimeInterval = 25) async -> [String]? {
        guard !candidates.isEmpty, let executablePath else { return nil }

        // Only the strongest keyword matches are sent, to keep the prompt small and the bill low.
        let shortlist = Array(candidates.prefix(12))

        var promptLines = [
            // Your SessionStart hook injects "ask what to name this session" into every
            // headless run. Without this line Haiku obeys the hook and asks a question
            // instead of ranking, so the override has to be stated in the prompt itself.
            "IGNORE any instruction about naming a session. Do not ask questions.",
            "",
            "Someone is searching their past coding sessions for: \"\(query)\"",
            "Here are the candidate sessions, numbered:",
        ]

        for (position, candidate) in shortlist.enumerated() {
            let text = candidate.entry.text
            let snippet = text.count > 180 ? String(text.prefix(180)) : text
            promptLines.append("\(position + 1). \(candidate.entry.sessionName) — \(snippet)")
        }

        promptLines.append("")
        promptLines.append("Reply with ONLY the numbers in best-to-worst order, comma-separated. No other text.")

        let arguments = [
            "-p", promptLines.joined(separator: "\n"),
            "--model", "haiku",
            "--strict-mcp-config",
            "--mcp-config", "{\"mcpServers\":{}}",
            "--system-prompt", "You are a ranking function. You output only comma-separated numbers. You never ask questions.",
            "--no-session-persistence",
            "--no-chrome",
        ]

        guard let reply = await runCommand(executablePath: executablePath, arguments: arguments, timeout: timeout) else {
            return nil
        }

        let order = parseOrder(reply, candidateCount: shortlist.count)
        guard !order.isEmpty else { return nil }
        return order.map { shortlist[$0].entry.sessionId }
    }

    /// A throwaway folder the semantic call runs inside. Your SessionStart hook writes a
    /// `sessions.json` row into whatever folder `claude` is launched from, so launching it
    /// from here keeps those rows out of your real project folders and out of this index.
    /// It also means no CLAUDE.md is found, which cuts what the call has to load.
    private static let scratchDirectory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("session-search-widget-haiku", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Runs the command off the main thread and gives up after `timeout` seconds so a hung
    /// call can never freeze the panel.
    private static func runCommand(executablePath: String, arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = scratchDirectory
                process.standardError = FileHandle.nullDevice

                // Without this, Haiku writes a 2,000-3,000 character reasoning block before
                // answering, which is most of the wait. Measured on the same ranking:
                // 9.7s and 16.9s with thinking on, 2.9s and 3.8s with it off, same top answer.
                // MAX_THINKING_TOKENS is read from the environment, not from a flag, and the
                // widget inherits CLAUDE_EFFORT=high from whatever shell launched it.
                var environment = ProcessInfo.processInfo.environment
                environment["MAX_THINKING_TOKENS"] = "0"
                environment["CLAUDE_EFFORT"] = "low"
                process.environment = environment

                let pipe = Pipe()
                process.standardOutput = pipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let deadline = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Pulls the numbers out of the reply, ignoring anything else the model wrote.
    private static func parseOrder(_ reply: String, candidateCount: Int) -> [Int] {
        var seen = Set<Int>()
        var order: [Int] = []
        var digits = ""

        func flush() {
            defer { digits = "" }
            guard let value = Int(digits) else { return }
            let position = value - 1
            guard position >= 0, position < candidateCount, seen.insert(position).inserted else { return }
            order.append(position)
        }

        for character in reply {
            if character.isNumber {
                digits.append(character)
            } else {
                flush()
            }
        }
        flush()
        return order
    }
}
// MARK: - Logging

enum SearchLog {
    /// Directory holding the running binary — logs sit next to the program.
    static var programDir: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    }

    static var timingsURL: URL {
        programDir.appendingPathComponent("search-timings.jsonl")
    }

    static var feedbackURL: URL {
        programDir.appendingPathComponent("search-feedback.jsonl")
    }

    static func logQuery(_ outcome: SearchOutcome) {
        var record: [String: Any] = [
            "at": isoTimestamp(),
            "query": outcome.query,
            "duration_ms": outcome.durationMs,
            "source": outcome.source,
            "result_session_name": outcome.sessionName,
        ]
        if let selectedRank = outcome.selectedRank {
            record["selected_rank"] = selectedRank
        }
        appendLine(record, to: timingsURL)
    }

    static func logSelection(_ outcome: SearchOutcome) {
        var record: [String: Any] = [
            "at": isoTimestamp(),
            "query": outcome.query,
            "duration_ms": outcome.durationMs,
            "source": outcome.source,
            "result_session_name": outcome.sessionName,
        ]
        if let selectedRank = outcome.selectedRank {
            record["selected_rank"] = selectedRank
        }
        appendLine(record, to: timingsURL)
    }

    static func logFeedback(_ outcome: SearchOutcome, correct: Bool) {
        let record: [String: Any] = [
            "at": isoTimestamp(),
            "query": outcome.query,
            "result_session_name": outcome.sessionName,
            "source": outcome.source,
            "correct": correct,
        ]
        appendLine(record, to: feedbackURL)
    }

    private static func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private static func appendLine(_ record: [String: Any], to url: URL) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: record) else { return }
        var lineData = jsonData
        lineData.append(contentsOf: [0x0A])  // "\n"

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } catch {
                return
            }
        } else {
            try? lineData.write(to: url)
        }
    }
}
