import Foundation

// MARK: - Index building

enum SessionIndex {
    /// Everything you typed in one session, capped so a very long transcript cannot
    /// dominate memory. 20k characters is roughly 3-4k words, plenty to match on.
    private static let maxTextPerSession = 20_000

    /// Text that Claude Code or my own hooks injected into the transcript rather than
    /// text you actually typed. Indexing it would match every session on the same words.
    private static let injectedPrefixes = [
        "<local-command",
        "<system-reminder",
        "<user-prompt-submit-hook",
        "caveat: the messages below",
        "summarize this excerpt of a claude code session transcript",
        "this session is being continued from a previous conversation",
        "[request interrupted",
        "api error",
        // One Claude session talking to another. It reads like something you typed but is
        // not, and 249 of these were being indexed as if they were your words.
        "another claude session sent a message",
        "<teammate-message",
    ]

    /// When you run a slash command, Claude Code stores the message as
    /// `<command-name>/goal</command-name> … <command-args>what you actually typed</command-args>`.
    /// The whole message used to be discarded for starting with a tag, which threw away 87
    /// real instructions — including the one that said "simplify localwispr". This keeps the
    /// command name and your arguments and drops the surrounding tags.
    private static func unwrapSlashCommand(_ text: String) -> String? {
        guard text.hasPrefix("<command-name>") else { return nil }

        func value(between open: String, and close: String) -> String? {
            guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else {
                return nil
            }
            let inner = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            return inner.isEmpty ? nil : inner
        }

        let name = value(between: "<command-name>", and: "</command-name>") ?? ""
        let args = value(between: "<command-args>", and: "</command-args>") ?? ""
        let combined = (name + " " + args).trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    /// Builds the searchable list from every real Claude Code transcript on this machine,
    /// then folds in the 3-bullet summaries the hooks write into each project's sessions.json.
    static func build() -> [IndexEntry] {
        let transcripts = mergeForks(loadTranscripts())
        let summaries = loadHookSummaries(folders: Set(transcripts.map { $0.cwd }))

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
    /// Maps every file's session id to the id of the conversation it belongs to. Ask mode
    /// can name any of a conversation's fork ids, and this turns it into the one indexed id.
    nonisolated(unsafe) private(set) static var forkAliases: [String: String] = [:]

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

        var aliases: [String: String] = [:]
        defer { forkAliases = aliases }

        return groups.values.map { group in
            guard group.count > 1 else {
                aliases[group[0].sessionId] = group[0].sessionId
                return group[0]
            }

            // Resume the file that was written to most recently: that is the live one.
            let newest = group.max { $0.modifiedAt < $1.modifiedAt }!
            for member in group { aliases[member.sessionId] = newest.sessionId }

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
            let raw = userText(from: message["content"])
            guard !raw.isEmpty else { continue }

            // A slash command keeps the words you typed as its arguments; anything else
            // starting with an injected tag is Claude Code's text, not yours.
            let text = unwrapSlashCommand(raw) ?? raw
            guard !isInjected(text) else { continue }

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

    /// Reads the names and 3-bullet summaries your hooks wrote, keyed by session id.
    /// Nothing here is written to; the hooks stay exactly as they are.
    ///
    /// The hook writes `sessions.json` into the folder the session ran in, so instead of
    /// crawling your home folder — which would walk Library and every node_modules — this
    /// looks in exactly the folders your sessions ran in, plus your home folder itself.
    /// That covers home and everywhere below it, at one file check per folder.
    private static func loadHookSummaries(folders: Set<String>) -> [String: SessionRecord] {
        let fileManager = FileManager.default
        var candidates = folders
        candidates.insert(fileManager.homeDirectoryForCurrentUser.path)

        // A test run can point the whole lookup somewhere else.
        if let overridePath = ProcessInfo.processInfo.environment["SSW_INDEX_ROOT"], !overridePath.isEmpty {
            candidates = [overridePath]
        }

        var summaries: [String: SessionRecord] = [:]

        for folder in candidates {
            let fileURL = URL(fileURLWithPath: folder, isDirectory: true)
                .appendingPathComponent("sessions.json")
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

        // Which sessions each query word appears in. A word found in nearly every session
        // ("the", "code", "fix") says almost nothing about which one you want; a word found
        // in one or two ("localwispr") is nearly the whole answer, so it is weighted higher.
        var matchesPerToken: [[Bool]] = []
        for token in tokens {
            matchesPerToken.append(index.map { matches(token: token, in: $0.text) })
        }

        var weights: [Double] = []
        for hits in matchesPerToken {
            let count = hits.filter { $0 }.count
            // No match anywhere means the word cannot separate anything, so it scores zero.
            weights.append(count == 0 ? 0 : log(Double(index.count + 1) / Double(count)))
        }

        var scored: [ScoredEntry] = []
        scored.reserveCapacity(index.count)

        for (position, entry) in index.enumerated() {
            var total = 0.0
            for (tokenIndex, hits) in matchesPerToken.enumerated() where hits[position] {
                total += weights[tokenIndex]
            }
            if total > 0 {
                scored.append(ScoredEntry(entry: entry, score: total))
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

    /// True when the session text contains this word. Endings are ignored, so searching
    /// "simplify" finds a session that says "simplification" — the exact case that made
    /// "simplify localwispr" return nothing.
    private static func matches(token: String, in text: String) -> Bool {
        if text.contains(token) { return true }
        guard token.count >= 6 else { return false }
        let stem = String(token.prefix(token.count - 2))
        return text.contains(stem)
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

// MARK: - Ask mode: a headless Claude that searches every session and answers

/// What Ask mode gives back: a sentence answering the question, plus the sessions it used.
struct AskResult {
    let answer: String
    /// Session ids the agent named, in the order it ranked them.
    let sessionIds: [String]
}

/// The mode you reach by pressing Tab. Local search can only rank sessions whose text
/// already contains your words; this hands the question to Claude Haiku with the
/// `session-search` skill, which greps every transcript on the machine and writes an answer.
/// It bills your Claude subscription, so nothing here runs unless you press Tab.
enum AskAgent {
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

    /// A throwaway folder the agent runs inside. Your SessionStart hook writes a
    /// `sessions.json` row into whatever folder `claude` is launched from, so launching it
    /// from here keeps those rows out of your real project folders and out of this index.
    private static let scratchDirectory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("session-search-widget-ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// How long to wait before giving up. Measured on this machine: 29 seconds to list every
    /// session that used a slash command, 46 seconds to answer a question about what was
    /// discussed, so the ceiling has to be generous.
    static var timeoutSeconds: TimeInterval {
        if let override = ProcessInfo.processInfo.environment["SSW_ASK_TIMEOUT"], let value = TimeInterval(override) {
            return value
        }
        return 150
    }

    /// Asks the question and returns the answer plus the sessions the agent named.
    static func ask(question: String) async -> AskResult? {
        guard let executablePath, !question.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        let prompt = """
        \(question)

        Use the session-search skill. Search every session on this machine, not just the \
        current folder. Reply with ONLY a JSON object, no other text:
        {"answer":"one or two plain sentences; quote the line that proves it","sessions":[{"id":"<session-id>"}]}
        List at most 8 sessions, best match first. If nothing matches, say so in "answer" and \
        return an empty "sessions" list.
        """

        let arguments = [
            "-p", prompt,
            "--model", "haiku",
            "--output-format", "json",
            // Read-only tools only. The agent greps and reads transcripts; it never edits.
            "--allowedTools", "Bash Read Glob Grep",
            "--no-session-persistence",
            "--no-chrome",
        ]

        guard let raw = await runCommand(executablePath: executablePath, arguments: arguments) else {
            return nil
        }
        return parse(raw)
    }

    /// Pulls the answer out of Claude Code's JSON envelope, then out of the JSON the agent
    /// wrote inside it — which it usually wraps in a ```json fence.
    private static func parse(_ raw: String) -> AskResult? {
        guard let envelopeData = raw.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let resultText = envelope["result"] as? String else {
            return nil
        }

        guard let start = resultText.firstIndex(of: "{"),
              let end = resultText.lastIndex(of: "}"), start < end else {
            // The agent answered in prose instead of JSON; still worth showing.
            let cleaned = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : AskResult(answer: cleaned, sessionIds: [])
        }

        let jsonText = String(resultText[start...end])
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AskResult(answer: resultText.trimmingCharacters(in: .whitespacesAndNewlines), sessionIds: [])
        }

        let answer = (object["answer"] as? String) ?? ""
        var ids: [String] = []
        if let sessions = object["sessions"] as? [[String: Any]] {
            for session in sessions {
                if let id = session["id"] as? String, !id.isEmpty { ids.append(id) }
            }
        }
        guard !answer.isEmpty || !ids.isEmpty else { return nil }
        return AskResult(answer: answer, sessionIds: ids)
    }

    /// Runs the agent off the main thread and gives up after the timeout so a hung call can
    /// never freeze the panel.
    private static func runCommand(executablePath: String, arguments: [String]) async -> String? {
        let limit = timeoutSeconds
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.currentDirectoryURL = scratchDirectory
                process.standardError = FileHandle.nullDevice

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
                DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: deadline)

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
