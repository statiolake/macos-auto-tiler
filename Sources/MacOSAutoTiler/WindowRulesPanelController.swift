import AppKit
import Foundation

final class WindowRulesPanelController: NSWindowController {
    private let registry: WindowTypeRegistry
    private let ruleStore: WindowRuleStore
    private let onRulesChanged: () -> Void

    private var records: [DiscoveredWindowType] = []
    private var refreshTimer: Timer?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let selectedLabel = NSTextField(labelWithString: "Select a discovered window type")
    private let appRuleCheckbox = NSButton(checkboxWithTitle: "Always float this app", target: nil, action: nil)
    private let typeRuleCheckbox = NSButton(checkboxWithTitle: "Always float this window type", target: nil, action: nil)

    init(
        registry: WindowTypeRegistry,
        ruleStore: WindowRuleStore,
        onRulesChanged: @escaping () -> Void
    ) {
        self.registry = registry
        self.ruleStore = ruleStore
        self.onRulesChanged = onRulesChanged

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 460),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Floating Rules"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)

        panel.delegate = self
        buildUI(in: panel)
        reloadRecords()
        updateSelectionUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        reloadRecords()
        updateSelectionUI()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshTimer()
    }

    private func buildUI(in panel: NSPanel) {
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = content

        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self

        addColumn(id: "app", title: "App", width: 190)
        addColumn(id: "role", title: "Role", width: 170)
        addColumn(id: "subrole", title: "Subrole", width: 170)
        addColumn(id: "seen", title: "Seen", width: 70)
        addColumn(id: "last", title: "Last Seen", width: 120)

        let leftPane = NSView()
        leftPane.translatesAutoresizingMaskIntoConstraints = false
        leftPane.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leftPane.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: leftPane.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: leftPane.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: leftPane.bottomAnchor),
            leftPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])

        let rightPane = NSStackView()
        rightPane.orientation = .vertical
        rightPane.alignment = .leading
        rightPane.spacing = 10
        rightPane.translatesAutoresizingMaskIntoConstraints = false

        selectedLabel.lineBreakMode = .byWordWrapping
        selectedLabel.maximumNumberOfLines = 4

        appRuleCheckbox.target = self
        appRuleCheckbox.action = #selector(toggleAppRule)

        typeRuleCheckbox.target = self
        typeRuleCheckbox.action = #selector(toggleTypeRule)

        let hintLabel = NSTextField(labelWithString: "Rules are applied immediately and persisted.")
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2

        rightPane.addArrangedSubview(selectedLabel)
        rightPane.addArrangedSubview(appRuleCheckbox)
        rightPane.addArrangedSubview(typeRuleCheckbox)
        rightPane.addArrangedSubview(hintLabel)

        container.addArrangedSubview(leftPane)
        container.addArrangedSubview(rightPane)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            container.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            rightPane.widthAnchor.constraint(equalToConstant: 240),
        ])
    }

    private func addColumn(id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func reloadRecords() {
        let previousID = selectedRecord?.id
        records = registry.snapshot(limit: 300)
        tableView.reloadData()

        if let previousID, let index = records.firstIndex(where: { $0.id == previousID }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private var selectedRecord: DiscoveredWindowType? {
        let row = tableView.selectedRow
        guard row >= 0, row < records.count else {
            return nil
        }
        return records[row]
    }

    private func updateSelectionUI() {
        guard let selectedRecord else {
            selectedLabel.stringValue = "Select a discovered window type"
            appRuleCheckbox.state = .off
            appRuleCheckbox.isEnabled = false
            typeRuleCheckbox.state = .off
            typeRuleCheckbox.isEnabled = false
            return
        }

        selectedLabel.stringValue = "App: \(selectedRecord.appName)\nType: \(selectedRecord.descriptor.role) / \(selectedRecord.descriptor.subrole)"

        appRuleCheckbox.isEnabled = true
        typeRuleCheckbox.isEnabled = true

        appRuleCheckbox.state = ruleStore.isAppForcedFloating(selectedRecord.appName) ? .on : .off
        typeRuleCheckbox.state = ruleStore.isTypeForcedFloating(selectedRecord.descriptor) ? .on : .off
    }

    @objc
    private func toggleAppRule() {
        guard let selectedRecord else { return }
        ruleStore.setAppForcedFloating(selectedRecord.appName, enabled: appRuleCheckbox.state == .on)
        onRulesChanged()
    }

    @objc
    private func toggleTypeRule() {
        guard let selectedRecord else { return }
        ruleStore.setTypeForcedFloating(selectedRecord.descriptor, enabled: typeRuleCheckbox.state == .on)
        onRulesChanged()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.reloadRecords()
            self.updateSelectionUI()
        }
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

extension WindowRulesPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionUI()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < records.count, let tableColumn else {
            return nil
        }

        let record = records[row]
        let identifier = NSUserInterfaceItemIdentifier("cell.\(tableColumn.identifier.rawValue)")

        let text: String
        switch tableColumn.identifier.rawValue {
        case "app":
            text = record.appName
        case "role":
            text = record.descriptor.role
        case "subrole":
            text = record.descriptor.subrole
        case "seen":
            text = String(record.seenCount)
        case "last":
            text = Self.relativeDateString(from: record.lastSeenAt)
        default:
            text = ""
        }

        if let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView,
           let textField = cell.textField
        {
            textField.stringValue = text
            return cell
        }

        let textField = NSTextField(labelWithString: text)
        textField.lineBreakMode = .byTruncatingTail

        let cell = NSTableCellView()
        cell.identifier = identifier
        cell.textField = textField
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private static func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension WindowRulesPanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopRefreshTimer()
    }
}
