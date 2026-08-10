import AppKit
import QuartzCore

// MARK: - Layout constants

private let panelWidth: CGFloat = 680
private let searchRowHeight: CGFloat = 64
private let sectionHeaderHeight: CGFloat = 26
private let hairlineThickness: CGFloat = 0.5
private let tableRowHeight: CGFloat = 52
private let footerHeight: CGFloat = 34
/// Breathing room above the first row and below the last, so rows never sit flush
/// against the section header or the footer.
private let listVerticalPadding: CGFloat = 8
private let maxVisibleRows = 8
private let resizeAnimationDuration: TimeInterval = 0.12

// MARK: - Color helpers

private extension NSColor {
    /// Parses a "#rrggbb" string. Used only for the fixed design-token colors below,
    /// so no validation beyond what Scanner gives us for free.
    static func hex(_ string: String) -> NSColor {
        var hexString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((value & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(value & 0x0000FF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }
}

/// Stable per-project dot colors. Index is derived from a deterministic hash of the
/// project name so the same project always renders with the same color.
private let projectColorPalette: [NSColor] = [
    .hex("#f59e0b"), .hex("#8b5cf6"), .hex("#10b981"), .hex("#3b82f6"),
    .hex("#ef4444"), .hex("#ec4899"), .hex("#14b8a6"), .hex("#f97316")
]

private func projectDotColor(for projectName: String) -> NSColor {
    let sum = projectName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    let index = sum % projectColorPalette.count
    return projectColorPalette[index]
}

// MARK: - Delegate

@MainActor
protocol SpotlightPanelDelegate: AnyObject {
    func spotlightQueryChanged(_ query: String)
    func spotlightSubmitted(row: SearchResultRow, rank: Int)
    func spotlightDismissed()
    func spotlightFeedback(correct: Bool, row: SearchResultRow, rank: Int)
    /// You pressed Tab, which swaps between matching words on this machine and asking
    /// Claude Haiku what you meant.
    func spotlightModeToggled(to mode: SearchMode)
}

/// Which of the two searches the panel is currently running.
enum SearchMode {
    /// Matches the words you typed against the text of every session. Runs on this
    /// machine, costs nothing, returns in under a tenth of a second.
    case local
    /// Sends the shortlist to Claude Haiku to be reordered by meaning. Bills your
    /// Claude subscription and takes several seconds.
    case semantic

    var label: String {
        switch self {
        case .local: return "Local"
        case .semantic: return "Semantic"
        }
    }

    var toggled: SearchMode {
        switch self {
        case .local: return .semantic
        case .semantic: return .local
        }
    }
}

// MARK: - Panel

final class SpotlightPanel: NSPanel {
    // Borderless/non-activating panels refuse key status by default, which means a
    // borderless search field would never receive keystrokes. Overriding these two
    // is what makes typing actually reach the text field.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Small flipped-coordinate helpers (top-down layout is far easier to reason about here)

private class TopDownView: NSView {
    override var isFlipped: Bool { true }
}

private final class TopDownVisualEffectView: NSVisualEffectView {
    override var isFlipped: Bool { true }
}

// MARK: - Result row pill background

/// Custom row-selection painter. The table view disables its own selection highlight
/// (selectionHighlightStyle = .none) so this can draw an inset rounded "pill" instead of
/// AppKit's default full-width blue/grey bar.
private final class PillRowView: NSTableRowView {
    // With selectionHighlightStyle = .none, AppKit never invalidates the row when the
    // selection moves, so the pill has to ask for its own redraw.
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // Intentionally empty: painting happens in draw(_:) below regardless of what
        // selectionHighlightStyle would normally trigger.
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isSelected else { return }
        // dy inset keeps neighbouring selected pills from touching edge to edge.
        let insetRect = bounds.insetBy(dx: 6, dy: 3)
        let path = NSBezierPath(roundedRect: insetRect, xRadius: 7, yRadius: 7)
        NSColor.white.withAlphaComponent(0.10).setFill()
        path.fill()
    }
}

// MARK: - Result row cell

private final class RowCellView: TopDownView {
    private let dotView = NSView()
    private let titleLabel = RowCellView.makeLabel(
        font: .systemFont(ofSize: 13, weight: .regular),
        color: NSColor(white: 0.949, alpha: 1)
    )
    private let projectLabel = RowCellView.makeLabel(
        font: .systemFont(ofSize: 11.5, weight: .regular),
        color: NSColor(white: 0.486, alpha: 1),
        alignment: .right
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5
        addSubview(dotView)
        addSubview(titleLabel)
        addSubview(projectLabel)
        layoutParts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var frame: NSRect {
        didSet { layoutParts() }
    }

    private func layoutParts() {
        let leftPad: CGFloat = 16
        let rightPad: CGFloat = 16
        let dotSize: CGFloat = 7
        let dotGap: CGFloat = 10
        let projectWidth: CGFloat = 160
        let width = bounds.width
        let height = bounds.height

        dotView.frame = NSRect(x: leftPad, y: (height - dotSize) / 2, width: dotSize, height: dotSize)

        let projectHeight: CGFloat = 14
        projectLabel.frame = NSRect(
            x: width - rightPad - projectWidth,
            y: (height - projectHeight) / 2,
            width: projectWidth,
            height: projectHeight
        )

        let titleX = leftPad + dotSize + dotGap
        let titleHeight: CGFloat = 16
        let titleWidth = max(0, projectLabel.frame.minX - 8 - titleX)
        titleLabel.frame = NSRect(x: titleX, y: (height - titleHeight) / 2, width: titleWidth, height: titleHeight)
    }

    func configure(with row: SearchResultRow) {
        titleLabel.stringValue = row.sessionName
        projectLabel.stringValue = row.projectName
        dotView.layer?.backgroundColor = projectDotColor(for: row.projectName).cgColor
    }

    private static func makeLabel(font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = font
        field.textColor = color
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.cell?.truncatesLastVisibleLine = true
        return field
    }
}

// MARK: - Controller

@MainActor
final class SpotlightController: NSObject {

    weak var delegate: SpotlightPanelDelegate?

    private let panel: SpotlightPanel
    private let backgroundView = TopDownVisualEffectView()
    private let tintOverlayView = TopDownView()
    private let searchRow = TopDownView()
    private let searchIcon = NSImageView()
    private let modeChip = NSTextField(labelWithString: "")
    /// Local matching is the default because most of the time you know which session you want.
    private(set) var mode: SearchMode = .local
    private let textField = NSTextField()
    private let progressIndicator = NSProgressIndicator()
    private let divider = TopDownView()
    private let sectionHeaderView = TopDownView()
    private let sectionHeaderLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let footerView = TopDownView()
    private let footerHairline = TopDownView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let rightButton = NSButton(title: "", target: nil, action: nil)
    private let wrongButton = NSButton(title: "", target: nil, action: nil)

    private let cellIdentifier = NSUserInterfaceItemIdentifier("SpotlightRowCell")
    private let rowViewIdentifier = NSUserInterfaceItemIdentifier("SpotlightRowView")

    private var rows: [SearchResultRow] = []
    /// Set while we're the ones calling panel.orderOut(), so the resulting
    /// didResignKeyNotification doesn't trigger a second, redundant dismiss.
    private var suppressResignHandling = false

    var isVisible: Bool { panel.isVisible }

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: panelWidth, height: searchRowHeight)
        panel = SpotlightPanel(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildSearchRow()
        buildDivider()
        buildSectionHeader()
        buildResultsList()
        buildFooter()
        assembleHierarchy()
        layoutContent()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Public API

    func show() {
        positionPanel()
        layoutContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textField)
        textField.currentEditor()?.selectAll(nil)
    }

    func hide() {
        suppressResignHandling = true
        panel.orderOut(nil)
        textField.stringValue = ""
        rows = []
        tableView.reloadData()
        layoutContent()
        suppressResignHandling = false
    }

    func setRows(_ rows: [SearchResultRow]) {
        self.rows = rows
        tableView.reloadData()

        // The table view keeps a stale extra 20pt of height (its initial frame) on top of
        // the real content, so the document ends up taller than the clip view and the last
        // row renders pushed against the footer. Pin it to exactly rows * rowHeight.
        let visibleRowCount = min(rows.count, maxVisibleRows)
        tableView.frame = NSRect(
            x: 0, y: 0,
            width: panelWidth,
            height: CGFloat(visibleRowCount) * tableRowHeight
        )

        layoutContent()
        resizeWindow(animated: true)

        // Scrolling must happen AFTER layoutContent/resizeWindow: doing it first leaves
        // the clip view holding an offset measured against the previous list height, which
        // renders the first row pushed down and clipped until the user scrolls manually.
        guard !rows.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tableView.scrollRowToVisible(0)
        // Row views created by reloadData can miss the selection change; repaint them.
        tableView.enumerateAvailableRowViews { rowView, _ in rowView.needsDisplay = true }
    }

    func setSearching(_ searching: Bool) {
        if searching {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    // MARK: Construction

    private func configurePanel() {
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        // Force dark rendering regardless of the user's system appearance so vibrancy
        // and label colors always resolve to the dark variants used below.
        panel.appearance = NSAppearance(named: .darkAqua)

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 12
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.5
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        panel.contentView = backgroundView

        // Thin tint layer over the vibrancy material to hit the target rgba(28,28,32,0.86).
        tintOverlayView.wantsLayer = true
        tintOverlayView.layer?.backgroundColor = NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.125, alpha: 0.78).cgColor
        tintOverlayView.autoresizingMask = [.width, .height]
    }

    private func buildSearchRow() {
        let iconSize: CGFloat = 17
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = NSColor.white.withAlphaComponent(0.5)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        searchIcon.imageScaling = .scaleProportionallyUpOrDown
        searchIcon.frame = NSRect(x: 16, y: (searchRowHeight - iconSize) / 2, width: iconSize, height: iconSize)

        let progressSize: CGFloat = 16
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.frame = NSRect(
            x: panelWidth - 16 - progressSize,
            y: (searchRowHeight - progressSize) / 2,
            width: progressSize,
            height: progressSize
        )

        // The chip tells you which search Tab has you in, so you never spend money by accident.
        modeChip.font = .systemFont(ofSize: 10, weight: .semibold)
        modeChip.alignment = .center
        modeChip.wantsLayer = true
        modeChip.layer?.cornerRadius = 4
        modeChip.isBezeled = false
        modeChip.isEditable = false
        modeChip.drawsBackground = false
        applyModeChipStyle()

        let textFieldX = 16 + iconSize + 11
        let textFieldHeight: CGFloat = 22
        let textFieldWidth = modeChip.frame.minX - 10 - textFieldX
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 17, weight: .regular)
        textField.textColor = NSColor(white: 0.949, alpha: 1)
        textField.frame = NSRect(
            x: textFieldX,
            y: (searchRowHeight - textFieldHeight) / 2,
            width: textFieldWidth,
            height: textFieldHeight
        )
        let placeholderAttrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 0.43, alpha: 1),
            .font: NSFont.systemFont(ofSize: 17, weight: .regular)
        ]
        textField.placeholderAttributedString = NSAttributedString(string: "Search sessions", attributes: placeholderAttrs)
        textField.delegate = self
        (textField.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        searchRow.frame = NSRect(x: 0, y: 0, width: panelWidth, height: searchRowHeight)
        searchRow.addSubview(searchIcon)
        searchRow.addSubview(textField)
        searchRow.addSubview(modeChip)
        searchRow.addSubview(progressIndicator)
    }

    /// Paints the chip grey for the local search and amber for the paid semantic one.
    private func applyModeChipStyle() {
        let chipWidth: CGFloat = 74
        let chipHeight: CGFloat = 18
        modeChip.frame = NSRect(
            x: progressIndicator.frame.minX - 10 - chipWidth,
            y: (searchRowHeight - chipHeight) / 2,
            width: chipWidth,
            height: chipHeight
        )
        modeChip.stringValue = "⇥ " + mode.label
        switch mode {
        case .local:
            modeChip.textColor = NSColor(white: 0.6, alpha: 1)
            modeChip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        case .semantic:
            modeChip.textColor = NSColor(red: 1.0, green: 0.72, blue: 0.35, alpha: 1)
            modeChip.layer?.backgroundColor = NSColor(red: 1.0, green: 0.62, blue: 0.2, alpha: 0.16).cgColor
        }
    }

    /// Flips between the two searches and tells the app to re-run the current query.
    func toggleMode() {
        mode = mode.toggled
        applyModeChipStyle()
        delegate?.spotlightModeToggled(to: mode)
    }

    private func buildDivider() {
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        divider.frame = NSRect(x: 0, y: searchRowHeight, width: panelWidth, height: hairlineThickness)
    }

    private func buildSectionHeader() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor(white: 0.43, alpha: 1),
            .kern: 0.5
        ]
        sectionHeaderLabel.attributedStringValue = NSAttributedString(string: "SESSIONS", attributes: attrs)
        sectionHeaderLabel.frame = NSRect(x: 16, y: 8, width: panelWidth - 32, height: 12)
        sectionHeaderView.addSubview(sectionHeaderLabel)
    }

    private func buildResultsList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = panelWidth
        column.resizingMask = .autoresizingMask

        tableView.headerView = nil
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.rowHeight = tableRowHeight
        tableView.backgroundColor = .clear
        // Rows paint their own inset "pill" selection background (see PillRowView),
        // so AppKit's own blue/grey highlight must be suppressed here.
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.gridStyleMask = []
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowClicked)

        scrollView.documentView = tableView
        // No visible scroller at all: it was drawing a permanent sliver down the right
        // edge that read as the list being clipped. Arrow-key navigation calls
        // scrollRowToVisible, so the list still scrolls past the 8 visible rows.
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.frame = NSRect(x: 0, y: searchRowHeight + hairlineThickness, width: panelWidth, height: 0)
    }

    private func buildFooter() {
        footerHairline.wantsLayer = true
        footerHairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor(white: 0.486, alpha: 1)
        statusLabel.lineBreakMode = .byTruncatingTail

        styleFeedbackButton(rightButton, title: "\u{2713}")
        rightButton.target = self
        rightButton.action = #selector(rightButtonClicked(_:))

        styleFeedbackButton(wrongButton, title: "\u{2717}")
        wrongButton.target = self
        wrongButton.action = #selector(wrongButtonClicked(_:))

        let arrowsChip = makeHintChip("\u{2191}\u{2193}")
        let moveWord = makeHintWord("move")
        let enterChip = makeHintChip("\u{21B5}")
        let openWord = makeHintWord("open")
        let escChip = makeHintChip("esc")
        let closeWord = makeHintWord("close")

        footerView.frame = NSRect(x: 0, y: searchRowHeight + hairlineThickness, width: panelWidth, height: footerHeight)
        footerView.addSubview(footerHairline)
        footerView.addSubview(statusLabel)
        footerView.addSubview(rightButton)
        footerView.addSubview(wrongButton)
        [arrowsChip, moveWord, enterChip, openWord, escChip, closeWord].forEach { footerView.addSubview($0) }

        layoutFooterContent(
            arrowsChip: arrowsChip, moveWord: moveWord,
            enterChip: enterChip, openWord: openWord,
            escChip: escChip, closeWord: closeWord
        )
    }

    /// Lays out the footer's right-aligned hint-chip cluster and feedback buttons, packing
    /// right to left, then gives the status label whatever space remains on the left.
    private func layoutFooterContent(
        arrowsChip: NSView, moveWord: NSView,
        enterChip: NSView, openWord: NSView,
        escChip: NSView, closeWord: NSView
    ) {
        footerHairline.frame = NSRect(x: 0, y: 0, width: panelWidth, height: hairlineThickness)
        let centerY = footerHeight / 2
        var cursorX = panelWidth - 16

        func place(_ view: NSView, gapAfter: CGFloat) {
            let size = view.frame.size
            view.frame = NSRect(x: cursorX - size.width, y: centerY - size.height / 2, width: size.width, height: size.height)
            cursorX -= size.width + gapAfter
        }

        place(closeWord, gapAfter: 4)
        place(escChip, gapAfter: 8)
        place(openWord, gapAfter: 4)
        place(enterChip, gapAfter: 8)
        place(moveWord, gapAfter: 4)
        place(arrowsChip, gapAfter: 12)

        place(wrongButton, gapAfter: 6)
        place(rightButton, gapAfter: 12)

        statusLabel.frame = NSRect(x: 16, y: centerY - 7, width: max(0, cursorX - 16), height: 14)
    }

    private func makeHintWord(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.486, alpha: 1)
        label.sizeToFit()
        return label
    }

    private func makeHintChip(_ text: String) -> NSView {
        let container = TopDownView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
        container.layer?.cornerRadius = 4

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10)
        label.textColor = NSColor(white: 0.73, alpha: 1)
        label.sizeToFit()

        let hPad: CGFloat = 3
        let height: CGFloat = 16
        container.frame = NSRect(x: 0, y: 0, width: label.frame.width + hPad * 2, height: height)
        label.frame = NSRect(x: hPad, y: (height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        container.addSubview(label)
        return container
    }

    private func styleFeedbackButton(_ button: NSButton, title: String) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.11).cgColor
        button.layer?.cornerRadius = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor(white: 0.73, alpha: 1)
        ]
        button.attributedTitle = NSAttributedString(string: title, attributes: attributes)
        button.sizeToFit()
        var resized = button.frame
        resized.size.width += 8
        resized.size.height = 16
        button.frame = resized
    }

    private func assembleHierarchy() {
        tintOverlayView.frame = backgroundView.bounds
        backgroundView.addSubview(tintOverlayView)
        backgroundView.addSubview(searchRow)
        backgroundView.addSubview(divider)
        backgroundView.addSubview(sectionHeaderView)
        backgroundView.addSubview(scrollView)
        backgroundView.addSubview(footerView)
    }

    // MARK: Layout

    private func computeHeight() -> CGFloat {
        guard !rows.isEmpty else { return searchRowHeight }
        let visibleRowCount = min(rows.count, maxVisibleRows)
        return searchRowHeight + hairlineThickness + sectionHeaderHeight
            + listVerticalPadding + CGFloat(visibleRowCount) * tableRowHeight + listVerticalPadding
            + footerHeight
    }

    private func layoutContent() {
        let hasRows = !rows.isEmpty
        divider.isHidden = !hasRows
        sectionHeaderView.isHidden = !hasRows
        footerView.isHidden = !hasRows

        let visibleRowCount = min(rows.count, maxVisibleRows)
        let tableAreaHeight = hasRows ? CGFloat(visibleRowCount) * tableRowHeight : 0

        var y = searchRowHeight
        divider.frame = NSRect(x: 0, y: y, width: panelWidth, height: hairlineThickness)
        if hasRows { y += hairlineThickness }

        sectionHeaderView.frame = NSRect(x: 0, y: y, width: panelWidth, height: hasRows ? sectionHeaderHeight : 0)
        if hasRows { y += sectionHeaderHeight + listVerticalPadding }

        scrollView.frame = NSRect(x: 0, y: y, width: panelWidth, height: tableAreaHeight)
        y += tableAreaHeight
        if hasRows { y += listVerticalPadding }

        footerView.frame = NSRect(x: 0, y: y, width: panelWidth, height: hasRows ? footerHeight : 0)

        if ProcessInfo.processInfo.environment["SSW_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("""
            [layout] rows=\(rows.count) panelH=\(panel.frame.height) computed=\(computeHeight()) \
            scrollY=\(scrollView.frame.origin.y) scrollH=\(scrollView.frame.height) \
            tableH=\(tableView.frame.height) clipOriginY=\(scrollView.contentView.bounds.origin.y) \
            footerY=\(footerView.frame.origin.y)

            """.utf8))
        }
    }

    private func positionPanel() {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = computeHeight()
        let x = screenFrame.origin.x + (screenFrame.width - panelWidth) / 2
        // AppKit screen coordinates are bottom-left origin, so "20% down from the top"
        // has to be computed from the screen's maxY, not its origin.
        let topEdgeY = screenFrame.origin.y + screenFrame.height - (screenFrame.height * 0.20)
        let y = topEdgeY - height
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: height), display: true)
    }

    private func resizeWindow(animated: Bool) {
        let targetHeight = computeHeight()
        let current = panel.frame
        guard abs(current.height - targetHeight) > 0.5 else { return }
        // Keep the top edge anchored in place; only the bottom edge grows/shrinks,
        // matching Spotlight's own resize behavior.
        let topY = current.origin.y + current.height
        let newFrame = NSRect(x: current.origin.x, y: topY - targetHeight, width: panelWidth, height: targetHeight)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resizeAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }

    // MARK: Actions

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard !suppressResignHandling else { return }
        hide()
        delegate?.spotlightDismissed()
    }

    @objc private func rowClicked() {
        let index = tableView.clickedRow
        guard index >= 0, index < rows.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        delegate?.spotlightSubmitted(row: rows[index], rank: index)
    }

    @objc private func rightButtonClicked(_ sender: NSButton) {
        fireFeedback(correct: true)
    }

    @objc private func wrongButtonClicked(_ sender: NSButton) {
        fireFeedback(correct: false)
    }

    private func fireFeedback(correct: Bool) {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        delegate?.spotlightFeedback(correct: correct, row: rows[index], rank: index)
    }
}

// MARK: - NSTextFieldDelegate / NSControlTextEditingDelegate

@MainActor
extension SpotlightController: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        delegate?.spotlightQueryChanged(textField.stringValue)
    }

    // NOTE: Swift 6 renamed doCommandBySelector: to doCommandBy: — the old selector
    // name is obsoleted and silently fails to be picked up as an override if used.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            guard !rows.isEmpty else { return true }
            let next = min(max(tableView.selectedRow, -1) + 1, rows.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            return true

        case #selector(NSResponder.moveUp(_:)):
            guard !rows.isEmpty else { return true }
            let previous = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false)
            tableView.scrollRowToVisible(previous)
            return true

        case #selector(NSResponder.insertNewline(_:)):
            let index = tableView.selectedRow
            guard index >= 0, index < rows.count else { return true }
            delegate?.spotlightSubmitted(row: rows[index], rank: index)
            return true

        // Tab would otherwise move focus out of the search field, so it has to be
        // swallowed here and turned into the mode switch.
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            toggleMode()
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            delegate?.spotlightDismissed()
            return true

        default:
            return false
        }
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

@MainActor
extension SpotlightController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        tableRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let cell: RowCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? RowCellView {
            cell = reused
        } else {
            cell = RowCellView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: tableRowHeight))
            cell.identifier = cellIdentifier
        }
        cell.configure(with: rows[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: rowViewIdentifier, owner: self) as? PillRowView {
            return reused
        }
        let rowView = PillRowView()
        rowView.identifier = rowViewIdentifier
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        false
    }
}
