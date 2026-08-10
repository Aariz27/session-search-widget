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

    /// Sends the current shortlist to Claude Haiku. Only ever called when you have put the
    /// panel in semantic mode by pressing Tab, because this bills your Claude subscription.
    private func runSemanticSearch(for query: String) {
        semanticGeneration += 1
        let generation = semanticGeneration

        guard !currentScored.isEmpty else { return }
        guard HaikuRerank.isAvailable else {
            controller.setStatus("the claude command was not found on this machine")
            return
        }

        let candidates = currentScored
        controller.setSearching(true)
        controller.setStatus("asking Claude Haiku…")
        let start = Date()

        Task { @MainActor in
            let order = await HaikuRerank.rank(query: query, candidates: candidates)
            guard generation == self.semanticGeneration, self.controller.isVisible else { return }
            self.controller.setSearching(false)

            let elapsedMs = Date().timeIntervalSince(start) * 1000
            guard let order, !order.isEmpty else {
                self.lastSource = "semantic_failed"
                self.lastDurationMs = elapsedMs
                self.controller.setStatus("Claude Haiku did not answer · showing local matches")
                return
            }

            // Put the sessions Haiku chose at the top; anything it left out keeps its place below.
            var byId: [String: SearchResultRow] = [:]
            for row in self.currentRows { byId[row.sessionId] = row }
            var reordered: [SearchResultRow] = []
            for sessionId in order {
                if let row = byId.removeValue(forKey: sessionId) { reordered.append(row) }
            }
            for row in self.currentRows where byId[row.sessionId] != nil { reordered.append(row) }

            self.currentRows = reordered
            self.lastSource = "semantic_haiku"
            self.lastDurationMs = elapsedMs
            self.controller.setRows(reordered)
            self.controller.setStatus("\(reordered.count) results · \(Int(elapsedMs))ms · Claude Haiku")
        }
    }

    private func outcome(for row: SearchResultRow, rank: Int?) -> SearchOutcome {
        SearchOutcome(
            query: currentQuery,
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

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            currentScored = []
            currentRows = []
            controller.setRows([])
            controller.setStatus("\(index.count) sessions indexed")
            return
        }

        runLocalSearch(query)

        // Typing in semantic mode does not call Claude on every keystroke. You press
        // Enter, or Tab again, when you want the paid search to run.
        if controller.mode == .semantic, !currentRows.isEmpty {
            controller.setStatus("\(currentRows.count) local matches · press Tab to rank with Claude Haiku")
        }
    }

    /// The default search: match the words you typed against the indexed session text.
    /// Runs entirely on this machine and costs nothing.
    private func runLocalSearch(_ query: String) {
        let start = Date()
        currentScored = SessionSearch.rank(query: query, index: index)
        currentRows = SessionSearch.rows(from: currentScored, query: query)
        lastDurationMs = Date().timeIntervalSince(start) * 1000
        lastSource = currentRows.isEmpty ? "no_match" : "local"

        controller.setRows(currentRows)
        controller.setStatus(currentRows.isEmpty
            ? "no matches"
            : "\(currentRows.count) results · \(String(format: "%.1f", lastDurationMs))ms · local")
    }

    func spotlightModeToggled(to mode: SearchMode) {
        switch mode {
        case .local:
            // Drop any Haiku answer still on its way and go back to the word matches.
            semanticGeneration += 1
            controller.setSearching(false)
            guard !currentQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
                controller.setStatus("\(index.count) sessions indexed")
                return
            }
            runLocalSearch(currentQuery)

        case .semantic:
            guard !currentQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
                controller.setStatus("type a query, then Tab ranks it with Claude Haiku")
                return
            }
            runSemanticSearch(for: currentQuery)
        }
    }

    func spotlightSubmitted(row: SearchResultRow, rank: Int) {
        // Clipboard first, so the command survives even if Terminal fails to open.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(row.command, forType: .string)
        SearchLog.logSelection(outcome(for: row, rank: rank))
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
    print("index entries loaded: \(index.count)")

    let start = Date()
    let scored = SessionSearch.rank(query: query, index: index)
    print("candidates: \(scored.prefix(8).map { "\($0.entry.sessionName)=\($0.score)" })")
    var rows = SessionSearch.rows(from: scored, query: query)
    var source = rows.isEmpty ? "no_match" : "local"

    if semantic, !scored.isEmpty {
        print("claude command: \(HaikuRerank.executablePath ?? "NOT FOUND")")
        if let order = await HaikuRerank.rank(query: query, candidates: scored), !order.isEmpty {
            var byId: [String: SearchResultRow] = [:]
            for row in rows { byId[row.sessionId] = row }
            var reordered: [SearchResultRow] = []
            for sessionId in order {
                if let row = byId.removeValue(forKey: sessionId) { reordered.append(row) }
            }
            for row in rows where byId[row.sessionId] != nil { reordered.append(row) }
            rows = reordered
            source = "semantic_haiku"
        } else {
            source = "semantic_failed"
        }
    }

    let durationMs = Date().timeIntervalSince(start) * 1000
    guard let top = rows.first else {
        print("RESULT: no match  [\(source), \(String(format: "%.0f", durationMs))ms]")
        return
    }
    let outcome = SearchOutcome(query: query, sessionName: top.sessionName, source: source, durationMs: durationMs, selectedRank: nil)
    SearchLog.logQuery(outcome)
    print("RESULT: \(top.command)  [\(source), \(String(format: "%.0f", durationMs))ms]")
    print("ranked: \(rows.map { $0.sessionName })")
    print("timings log: \(SearchLog.timingsURL.path)")
}

@main
enum SessionSearchWidgetMain {
    @MainActor
    static func main() async {
        let args = CommandLine.arguments
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
