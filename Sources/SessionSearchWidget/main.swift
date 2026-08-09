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
    private var lastSource = "instant_keyword"
    private var lastDurationMs: Double = 0
    private var rerankTimer: Timer?
    private var rerankGeneration = 0

    /// How long typing must pause before the local model is asked to reorder results.
    private let rerankDelay: TimeInterval = 0.6

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        index = SessionIndex.build()
        Ollama.prewarm()

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

    /// Runs the local model only when typing has paused and the keyword scores are ambiguous.
    private func scheduleRerank(for query: String) {
        rerankTimer?.invalidate()
        rerankGeneration += 1
        let generation = rerankGeneration
        guard currentScored.count > 1, !SessionSearch.isClearWinner(currentScored) else { return }

        rerankTimer = Timer.scheduledTimer(withTimeInterval: rerankDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.rerankGeneration, self.controller.isVisible else { return }
                let candidates = self.currentScored
                self.controller.setSearching(true)
                let start = Date()
                let order = await Ollama.rerank(query: query, candidates: candidates)
                guard generation == self.rerankGeneration else { return }
                self.controller.setSearching(false)
                guard let order, !order.isEmpty else { return }

                // Reorder existing rows to the model's preference; anything it omitted keeps its place at the end.
                var byName: [String: SearchResultRow] = [:]
                for row in self.currentRows { byName[row.sessionName] = row }
                var reordered: [SearchResultRow] = []
                for name in order { if let row = byName.removeValue(forKey: name) { reordered.append(row) } }
                for row in self.currentRows where byName[row.sessionName] != nil { reordered.append(row) }

                self.currentRows = reordered
                self.lastSource = "qwen_rerank"
                self.lastDurationMs = Date().timeIntervalSince(start) * 1000
                self.controller.setRows(reordered)
                self.controller.setStatus("\(reordered.count) results · \(Int(self.lastDurationMs))ms · model")
            }
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
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            currentScored = []
            currentRows = []
            controller.setRows([])
            controller.setStatus("\(index.count) sessions indexed")
            rerankTimer?.invalidate()
            rerankGeneration += 1
            return
        }

        let start = Date()
        currentScored = SessionSearch.rank(query: query, index: index)
        currentRows = SessionSearch.rows(from: currentScored, query: query)
        lastDurationMs = Date().timeIntervalSince(start) * 1000
        lastSource = currentRows.isEmpty ? "no_match" : "instant_keyword"

        controller.setRows(currentRows)
        controller.setStatus(currentRows.isEmpty
            ? "no matches"
            : "\(currentRows.count) results · \(String(format: "%.1f", lastDurationMs))ms · keyword")

        scheduleRerank(for: query)
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
        rerankTimer?.invalidate()
        rerankGeneration += 1
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

/// `SessionSearchWidget --cli-test "query"` exercises index → rank → rerank → log with no GUI,
/// so the search path can be tested without driving AppKit.
@MainActor
func runCLITest(query: String) async {
    let index = SessionIndex.build()
    print("index entries loaded: \(index.count)")

    let start = Date()
    let scored = SessionSearch.rank(query: query, index: index)
    print("candidates: \(scored.map { "\($0.entry.sessionName)=\($0.score)" })")
    var rows = SessionSearch.rows(from: scored, query: query)
    var source = rows.isEmpty ? "no_match" : "instant_keyword"

    if scored.count > 1, !SessionSearch.isClearWinner(scored) {
        if let order = await Ollama.rerank(query: query, candidates: scored), !order.isEmpty {
            var byName: [String: SearchResultRow] = [:]
            for row in rows { byName[row.sessionName] = row }
            var reordered: [SearchResultRow] = []
            for name in order { if let row = byName.removeValue(forKey: name) { reordered.append(row) } }
            for row in rows where byName[row.sessionName] != nil { reordered.append(row) }
            rows = reordered
            source = "qwen_rerank"
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
            await runCLITest(query: args[flag + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
