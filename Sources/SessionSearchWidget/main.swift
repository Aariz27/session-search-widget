import AppKit
import Foundation

/// Wires the pieces together: Cmd+K summons the panel, keystrokes run the instant keyword
/// search, and a pause in typing may run the local model to reorder ambiguous results.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: SpotlightController!
    private var hotKey: HotKeyManager!
    private var outsideClick: OutsideClickMonitor!

    private var index: [IndexEntry] = []
    private var currentQuery = ""
    private var currentScored: [ScoredEntry] = []
    private var currentRows: [SearchResultRow] = []
    private var lastSource = "local"
    private var lastDurationMs: Double = 0
    /// Bumped whenever the query or the mode changes, so a slow Haiku reply that arrives
    /// after you have typed something else is thrown away instead of shown.
    private var semanticGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        index = SessionIndex.build()
        PickMemory.load()

        controller = SpotlightController()
        controller.delegate = self

        hotKey = HotKeyManager { [weak self] in self?.togglePanel() }
        hotKey.register()

        outsideClick = OutsideClickMonitor { [weak self] in
            guard let self, self.controller.isVisible else { return }
            self.controller.hide()
        }

        setupMenu()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "SS"
        let menu = NSMenu()
        let reload = NSMenuItem(title: "Reload index (\(index.count) sessions)", action: #selector(reloadIndex), keyEquivalent: "r")
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(reload)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quit)
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func reloadIndex() {
        index = SessionIndex.build()
        statusItem.menu?.items.first?.title = "Reload index (\(index.count) sessions)"
    }

    @objc private func quitApp() {
        hotKey.unregister()
        outsideClick.stop()
        NSApplication.shared.terminate(nil)
    }

    private func togglePanel() {
        if controller.isVisible {
            controller.hide()
            outsideClick.stop()
        } else {
            // Pick up sessions logged since launch without needing a manual reload.
            index = SessionIndex.build()
            controller.setStatus("\(index.count) sessions indexed")
            controller.show()
            outsideClick.start()
        }
    }

    /// Hands your question to Claude Haiku, which greps every transcript on the machine and
    /// writes an answer. Only ever called when you press Tab, because this bills your
    /// Claude subscription and takes 30-60 seconds.
    private func runAsk(question: String) {
        semanticGeneration += 1
        let generation = semanticGeneration

        // You have answered this question before and picked a session. Show that instead of
        // spending 15 seconds and about 3 cents asking Claude the same thing again.
        let remembered = PickMemory.exactMatches(for: question)
        if !remembered.isEmpty {
            var byId: [String: IndexEntry] = [:]
            for entry in index { byId[entry.sessionId] = entry }
            let entries = remembered.compactMap { byId[SessionIndex.forkAliases[$0] ?? $0] }
            if !entries.isEmpty {
                let rows = SessionSearch.rows(from: entries.map { ScoredEntry(entry: $0, score: 1) }, query: question)
                currentRows = rows
                lastSource = "remembered"
                lastDurationMs = 0
                controller.setSearching(false)
                controller.setAnswer("You picked this before for the same question.")
                controller.setRows(rows)
                controller.setStatus("\(rows.count) from memory · 0ms · $0 — change a word to ask Claude fresh")
                return
            }
        }

        guard AskAgent.isAvailable else {
            controller.setStatus("the claude command was not found on this machine")
            return
        }

        controller.setSearching(true)
        controller.setAnswer(nil)
        controller.setStatus("Claude Haiku is searching every session — this takes 30-60s")
        let start = Date()

        Task { @MainActor in
            let result = await AskAgent.ask(question: question)
            guard generation == self.semanticGeneration, self.controller.isVisible else { return }
            self.controller.setSearching(false)

            let elapsedMs = Date().timeIntervalSince(start) * 1000
            self.lastDurationMs = elapsedMs

            guard let result else {
                self.lastSource = "ask_failed"
                self.controller.setStatus("Claude Haiku did not answer · showing local matches")
                return
            }

            self.lastSource = "ask_haiku"
            self.controller.setAnswer(result.answer.isEmpty ? nil : result.answer)

            // Turn the ids the agent named into rows, so Enter still opens the session in
            // Terminal. Anything it named that is not in the local index is skipped.
            var byId: [String: IndexEntry] = [:]
            for entry in self.index { byId[entry.sessionId] = entry }
            // An id the agent names may be one of a conversation's resume forks, so it is
            // translated to the id this index actually holds.
            // Two forks of one conversation resolve to the same session, so it must not be
            // listed twice.
            var seenIds = Set<String>()
            let chosen = result.sessionIds.compactMap { id -> IndexEntry? in
                let resolved = SessionIndex.forkAliases[id] ?? id
                guard seenIds.insert(resolved).inserted else { return nil }
                return byId[resolved]
            }
            let rows = SessionSearch.rows(from: chosen.map { ScoredEntry(entry: $0, score: 1) }, query: question)

            self.currentRows = rows
            self.controller.setRows(rows)
            self.controller.setStatus(rows.isEmpty
                ? "answered in \(Int(elapsedMs / 1000))s · no session to open"
                : "\(rows.count) sessions · \(Int(elapsedMs / 1000))s · Claude Haiku")
        }
    }

    private func outcome(for row: SearchResultRow, rank: Int?) -> SearchOutcome {
        SearchOutcome(
            query: currentQuery,
            sessionId: row.sessionId,
            sessionName: row.sessionName,
            source: lastSource,
            durationMs: lastDurationMs,
            selectedRank: rank
        )
    }
}

// MARK: - Panel delegate

extension AppDelegate: SpotlightPanelDelegate {
    func spotlightQueryChanged(_ query: String) {
        currentQuery = query
        // Any in-flight Haiku answer is now stale, whatever the new query is.
        semanticGeneration += 1
        controller.setAnswer(nil)

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            currentScored = []
            currentRows = []
            controller.setRows([])
            controller.setStatus("\(index.count) sessions indexed")
            return
        }

        runLocalSearch(query)

        // Typing in Ask mode does not call Claude on every keystroke. You press Tab again
        // when you want the paid search to run.
        if controller.mode == .semantic {
            controller.setStatus("press Tab to ask Claude Haiku about every session")
        }
    }

    /// The default search: match the words you typed against the indexed session text.
    /// Runs entirely on this machine and costs nothing.
    private func runLocalSearch(_ query: String) {
        let start = Date()
        currentScored = SessionSearch.rank(query: query, index: index)
        var rows = SessionSearch.rows(from: currentScored, query: query)

        // A session you already chose for this question goes to the top, ahead of scoring.
        let remembered = PickMemory.exactMatches(for: query) + PickMemory.similarMatches(for: query)
        let rememberedCount = promote(&rows, ids: remembered)

        currentRows = rows
        lastDurationMs = Date().timeIntervalSince(start) * 1000
        lastSource = rows.isEmpty ? "no_match" : "local"

        controller.setRows(rows)
        controller.setStatus(rows.isEmpty
            ? "no matches"
            : "\(rows.count) results · \(String(format: "%.1f", lastDurationMs))ms · local"
              + (rememberedCount > 0 ? " · \(rememberedCount) you picked before" : ""))
    }

    /// Moves the given sessions to the front of the list, keeping their given order.
    /// Returns how many were actually found and moved.
    @discardableResult
    private func promote(_ rows: inout [SearchResultRow], ids: [String]) -> Int {
        guard !ids.isEmpty, !rows.isEmpty else { return 0 }
        var moved: [SearchResultRow] = []
        for id in ids {
            let resolved = SessionIndex.forkAliases[id] ?? id
            if let position = rows.firstIndex(where: { $0.sessionId == resolved }) {
                moved.append(rows.remove(at: position))
            }
        }
        rows = moved + rows
        return moved.count
    }

    func spotlightModeToggled(to mode: SearchMode) {
        switch mode {
        case .local:
            // Drop any Haiku answer still on its way and go back to the word matches.
            semanticGeneration += 1
            controller.setSearching(false)
            controller.setAnswer(nil)
            guard !currentQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
                controller.setStatus("\(index.count) sessions indexed")
                return
            }
            runLocalSearch(currentQuery)

        case .semantic:
            guard !currentQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
                controller.setStatus("type a question, then press Tab to ask Claude Haiku")
                return
            }
            runAsk(question: currentQuery)
        }
    }

    func spotlightSubmitted(row: SearchResultRow, rank: Int) {
        // Clipboard first, so the command survives even if Terminal fails to open.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(row.command, forType: .string)
        SearchLog.logSelection(outcome(for: row, rank: rank))
        PickMemory.remember(query: currentQuery, sessionId: row.sessionId)
        controller.hide()
        outsideClick.stop()
        openInTerminal(row: row)
    }

    /// Opens a new Terminal window, cd's into the session's folder and runs the resume
    /// command. `do script` both types and executes the line, so nothing else is needed.
    private func openInTerminal(row: SearchResultRow) {
        let shellCommand = "cd \(Self.shellQuote(row.cwd)) && \(row.command)"
        let script = """
        tell application "Terminal"
            activate
            do script "\(Self.appleScriptQuote(shellCommand))"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            NSSound.beep()
        }
    }

    /// Wraps a path in single quotes for /bin/sh, escaping any embedded single quote.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for embedding inside an AppleScript double-quoted literal.
    private static func appleScriptQuote(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func spotlightDismissed() {
        semanticGeneration += 1
        outsideClick.stop()
        if !currentQuery.isEmpty, let top = currentRows.first {
            SearchLog.logQuery(outcome(for: top, rank: nil))
        }
    }

    func spotlightFeedback(correct: Bool, row: SearchResultRow, rank: Int) {
        SearchLog.logFeedback(outcome(for: row, rank: rank), correct: correct)
    }
}

// MARK: - Headless verification path

/// `SessionSearchWidget --cli-test "query"` runs the local search with no GUI.
/// Add `--semantic` to also send the shortlist to Claude Haiku, exactly as pressing Tab does.
@MainActor
func runCLITest(query: String, semantic: Bool) async {
    let index = SessionIndex.build()
    PickMemory.load()
    print("index entries loaded: \(index.count)  remembered queries: \(PickMemory.byQuery.count)")

    let start = Date()
    let scored = SessionSearch.rank(query: query, index: index)
    print("candidates: \(scored.prefix(8).map { "\($0.entry.sessionName)=\($0.score)" })")
    var rows = SessionSearch.rows(from: scored, query: query)
    var source = rows.isEmpty ? "no_match" : "local"

    let remembered = PickMemory.exactMatches(for: query) + PickMemory.similarMatches(for: query)
    if !remembered.isEmpty {
        var moved: [SearchResultRow] = []
        for id in remembered {
            let resolved = SessionIndex.forkAliases[id] ?? id
            if let position = rows.firstIndex(where: { $0.sessionId == resolved }) {
                moved.append(rows.remove(at: position))
            }
        }
        rows = moved + rows
        if !moved.isEmpty { print("promoted \(moved.count) session(s) you picked before") }
    }

    if semantic {
        print("claude command: \(AskAgent.executablePath ?? "NOT FOUND")")
        if let result = await AskAgent.ask(question: query) {
            print("ANSWER: \(result.answer)")
            var byId: [String: IndexEntry] = [:]
            for entry in index { byId[entry.sessionId] = entry }
            // An id the agent names may be one of a conversation's resume forks, so it is
            // translated to the id this index actually holds.
            // Two forks of one conversation resolve to the same session, so it must not be
            // listed twice.
            var seenIds = Set<String>()
            let chosen = result.sessionIds.compactMap { id -> IndexEntry? in
                let resolved = SessionIndex.forkAliases[id] ?? id
                guard seenIds.insert(resolved).inserted else { return nil }
                return byId[resolved]
            }
            rows = SessionSearch.rows(from: chosen.map { ScoredEntry(entry: $0, score: 1) }, query: query)
            source = "ask_haiku"
        } else {
            source = "ask_failed"
        }
    }

    let durationMs = Date().timeIntervalSince(start) * 1000
    guard let top = rows.first else {
        print("RESULT: no match  [\(source), \(String(format: "%.0f", durationMs))ms]")
        return
    }
    let outcome = SearchOutcome(query: query, sessionId: top.sessionId, sessionName: top.sessionName, source: source, durationMs: durationMs, selectedRank: nil)
    SearchLog.logQuery(outcome)
    print("RESULT: \(top.command)  [\(source), \(String(format: "%.0f", durationMs))ms]")
    print("ranked: \(rows.map { $0.sessionName })")
    print("timings log: \(SearchLog.timingsURL.path)")
}

/// Runs several Ask-mode questions and prints the answer, the sessions named, and how long
/// each took, so Ask mode can be checked without driving the panel.
@MainActor
func runCLIBench(queries: [String]) async {
    let index = SessionIndex.build()
    print("index entries loaded: \(index.count)")
    print("claude command: \(AskAgent.executablePath ?? "NOT FOUND")")
    guard !queries.isEmpty else {
        print("pass at least one question")
        return
    }

    var byId: [String: IndexEntry] = [:]
    for entry in index { byId[entry.sessionId] = entry }

    for (position, query) in queries.enumerated() {
        let start = Date()
        let result = await AskAgent.ask(question: query)
        let seconds = Date().timeIntervalSince(start)
        print("\n\(position + 1). \"\(query)\"  [\(String(format: "%.0f", seconds))s]")
        guard let result else {
            print("   FAILED — no answer")
            continue
        }
        print("   answer: \(result.answer)")
        var seen = Set<String>()
        for id in result.sessionIds {
            let resolved = SessionIndex.forkAliases[id] ?? id
            guard seen.insert(resolved).inserted else { continue }
            if let entry = byId[resolved] {
                print("   -> \(entry.sessionName)  (\(entry.cwd))")
            } else {
                print("   -> \(resolved)  (not in local index)")
            }
        }
    }
}

@main
enum SessionSearchWidgetMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
        // `--cli-bench "query one" "query two" …` runs several semantic searches through the
        // one warm process and prints how long each took, which is the only way to see the
        // speed-up: a single search cannot show it, because the first one starts the process.
        if let flag = args.firstIndex(of: "--cli-bench") {
            let queries = Array(args[(flag + 1)...]).filter { !$0.hasPrefix("--") }
            await runCLIBench(queries: queries)
            return
        }
        if let flag = args.firstIndex(of: "--cli-test"), args.count > flag + 1 {
            await runCLITest(query: args[flag + 1], semantic: args.contains("--semantic"))
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
