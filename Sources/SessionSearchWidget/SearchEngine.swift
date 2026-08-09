import Foundation

// MARK: - Index building

enum SessionIndex {
    /// Walks the index root and flattens every named session into one searchable entry.
    static func build() -> [IndexEntry] {
        let fileManager = FileManager.default

        let root: URL
        if let overridePath = ProcessInfo.processInfo.environment["SSW_INDEX_ROOT"], !overridePath.isEmpty {
            root = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        }

        var entries: [IndexEntry] = []

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return entries
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "sessions.json" else { continue }

            guard let data = try? Data(contentsOf: fileURL) else { continue }
            guard let records = try? JSONDecoder().decode([SessionRecord].self, from: data) else { continue }

            for record in records {
                guard let sessionName = record.session_name, !sessionName.isEmpty else { continue }

                var textParts: [String] = [sessionName]
                for summary in record.session_summary {
                    textParts.append(contentsOf: summary.bullets)
                }
                let text = textParts.joined(separator: " ").lowercased()

                entries.append(
                    IndexEntry(
                        sessionId: record.session_id,
                        sessionName: sessionName,
                        cwd: record.cwd,
                        startedAt: record.started_at,
                        text: text
                    )
                )
            }
        }

        return entries
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

    /// True when the top score beats the runner-up by >= 2, i.e. no model help needed.
    static func isClearWinner(_ scored: [ScoredEntry]) -> Bool {
        guard let top = scored.first else { return false }
        guard scored.count > 1 else { return true }
        let runnerUp = scored[1]
        return (top.score - runnerUp.score) >= 2
    }

    /// Builds the display rows (incl. the `claude --resume "..."` command string) from scored entries.
    static func rows(from scored: [ScoredEntry], query: String) -> [SearchResultRow] {
        let tokens = tokenize(query)

        return scored.map { scoredEntry in
            let entry = scoredEntry.entry
            let projectName = (entry.cwd as NSString).lastPathComponent
            let snippet = makeSnippet(text: entry.text, tokens: tokens)
            let command = "claude --resume \"\(entry.sessionName)\""
            return SearchResultRow(
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

// MARK: - Ollama reranking

enum Ollama {
    private static let baseURL = URL(string: "http://127.0.0.1:11434/api/generate")!
    private static let model = "qwen2.5:1.5b"

    /// Fire-and-forget tiny request at launch so the model is resident and later calls are ~300ms not ~2400ms.
    static func prewarm() {
        Task.detached {
            var request = URLRequest(url: baseURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 8

            let body: [String: Any] = [
                "model": model,
                "prompt": "hi",
                "stream": false,
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
            request.httpBody = jsonData

            _ = try? await URLSession.shared.data(for: request)
        }
    }

    /// Asks qwen2.5:1.5b to reorder ambiguous candidates. Returns session names in the model's preferred
    /// order, or nil on any failure/timeout. MUST NOT throw and MUST NOT hang the caller.
    static func rerank(query: String, candidates: [ScoredEntry]) async -> [String]? {
        guard !candidates.isEmpty else { return nil }

        var promptLines = [
            "The user is searching their coding session history for: \"\(query)\"",
            "Here are the candidate sessions, numbered:",
        ]

        for (index, candidate) in candidates.enumerated() {
            let text = candidate.entry.text
            let snippet: String
            if text.count > 150 {
                let end = text.index(text.startIndex, offsetBy: 150)
                snippet = String(text[text.startIndex..<end])
            } else {
                snippet = text
            }
            promptLines.append("\(index + 1). \(candidate.entry.sessionName) - \(snippet)")
        }

        promptLines.append("Reply with ONLY the numbers in best-to-worst match order, comma-separated, nothing else.")
        let prompt = promptLines.joined(separator: "\n")

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = jsonData

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            guard let responseText = json["response"] as? String else { return nil }

            var seen = Set<Int>()
            var orderedIndices: [Int] = []

            var currentNumber = ""
            func flush() {
                if let value = Int(currentNumber) {
                    let zeroBased = value - 1
                    if zeroBased >= 0 && zeroBased < candidates.count && !seen.contains(zeroBased) {
                        seen.insert(zeroBased)
                        orderedIndices.append(zeroBased)
                    }
                }
                currentNumber = ""
            }

            for char in responseText {
                if char.isNumber {
                    currentNumber.append(char)
                } else {
                    flush()
                }
            }
            flush()

            guard !orderedIndices.isEmpty else { return nil }
            return orderedIndices.map { candidates[$0].entry.sessionName }
        } catch {
            return nil
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
