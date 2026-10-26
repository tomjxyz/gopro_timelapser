import AppKit
import TimelapserCore

/// Table of clips: drop files or folders from Finder, drag rows to reorder, buttons to move/remove.
final class ClipListView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var clips: [Clip] = []
    var onChange: (() -> Void)?
    var isLocked = false { didSet { updateButtons() } }

    private static let rowType = NSPasteboard.PasteboardType("com.goprotimelapser.clip-row")
    private let table = ClipTableView()
    private let scroll = NSScrollView()
    private let placeholder = label("Drag GoPro clips (or a folder) from Finder here", secondary: true)
    private let summary = label("", secondary: true, small: true)
    private var buttons: [String: NSButton] = [:]
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd  HH:mm:ss"
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let columns: [(String, String, CGFloat, NSTextAlignment)] = [
            ("num", "#", 34, .right),
            ("name", "File name", 200, .left),
            ("recorded", "Recorded", 160, .left),
            ("duration", "Duration", 70, .right),
            ("folder", "Folder", 200, .left),
        ]
        for (id, title, width, align) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = 30
            col.headerCell.alignment = align
            let cell = NSTextFieldCell()
            cell.alignment = align
            cell.lineBreakMode = .byTruncatingMiddle
            col.dataCell = cell
            table.addTableColumn(col)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onDelete = { [weak self] in self?.removeSelected() }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        let actions: [(String, String, Selector)] = [
            ("add", "Add Clips…", #selector(addClicked)),
            ("up", "Move Up", #selector(upClicked)),
            ("down", "Move Down", #selector(downClicked)),
            ("top", "Move to Top", #selector(topClicked)),
            ("bottom", "Move to Bottom", #selector(bottomClicked)),
            ("sort", "Sort by Time", #selector(sortClicked)),
            ("remove", "Remove", #selector(removeClicked)),
            ("clear", "Clear All", #selector(clearClicked)),
        ]
        var buttonViews: [NSView] = []
        for (key, title, action) in actions {
            let b = button(title, self, action)
            buttons[key] = b
            buttonViews.append(b)
        }
        let buttonStack = vstack(buttonViews, spacing: 4)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        for v in buttonViews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: buttonStack.widthAnchor).isActive = true
        }

        summary.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(placeholder)
        addSubview(buttonStack)
        addSubview(summary)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.trailingAnchor.constraint(equalTo: buttonStack.leadingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: summary.topAnchor, constant: -4),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            buttonStack.topAnchor.constraint(equalTo: topAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonStack.widthAnchor.constraint(equalToConstant: 130),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: summary.topAnchor, constant: -4),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            summary.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: 10),
        ])
        setContentHuggingPriority(.defaultLow, for: .vertical)
        reload(selecting: [])
    }

    // MARK: - Public

    var totalDuration: Double { clips.reduce(0) { $0 + ($1.duration ?? 0) } }

    func add(_ urls: [URL]) {
        guard !isLocked else { return }
        let existing = Set(clips.map { $0.url.standardizedFileURL.path })
        var seen = existing
        var added: [Clip] = []
        for url in Clip.videoFiles(in: urls) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            added.append(Clip.load(url.standardizedFileURL))
        }
        guard !added.isEmpty else { return }
        // New clips go on the end in recording order; the user can reorder afterwards.
        added.sort(by: Clip.recordingOrder)
        let first = clips.count
        clips += added
        reload(selecting: IndexSet(first..<clips.count))
    }

    // MARK: - Actions

    @objc private func addClicked() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Add GoPro clips"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedFileTypes = Array(Clip.videoExtensions) + Clip.videoExtensions.map { $0.uppercased() }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.add(panel.urls) }
        }
    }

    @objc private func upClicked() { moveSelected(by: -1) }
    @objc private func downClicked() { moveSelected(by: 1) }
    @objc private func topClicked() { move(rows: Array(table.selectedRowIndexes), to: 0) }
    @objc private func bottomClicked() { move(rows: Array(table.selectedRowIndexes), to: clips.count) }
    @objc private func removeClicked() { removeSelected() }

    @objc private func sortClicked() {
        let selected = Set(table.selectedRowIndexes.map { clips[$0].url })
        clips.sort(by: Clip.recordingOrder)
        reload(selecting: IndexSet(clips.indices.filter { selected.contains(clips[$0].url) }))
    }

    @objc private func clearClicked() {
        clips.removeAll()
        reload(selecting: [])
    }

    private func moveSelected(by delta: Int) {
        let rows = table.selectedRowIndexes.sorted()
        guard let first = rows.first, let last = rows.last else { return }
        if delta < 0 && first == 0 { return }
        if delta > 0 && last == clips.count - 1 { return }
        for i in (delta < 0 ? rows : rows.reversed()) {
            clips.swapAt(i, i + delta)
        }
        reload(selecting: IndexSet(rows.map { $0 + delta }))
    }

    private func move(rows: [Int], to target: Int) {
        guard !rows.isEmpty else { return }
        let sorted = rows.sorted()
        let moving = sorted.map { clips[$0] }
        let before = sorted.filter { $0 < target }.count
        for i in sorted.reversed() { clips.remove(at: i) }
        let insertAt = max(0, min(clips.count, target - before))
        clips.insert(contentsOf: moving, at: insertAt)
        reload(selecting: IndexSet(insertAt..<(insertAt + moving.count)))
    }

    private func removeSelected() {
        guard !isLocked else { return }
        let rows = table.selectedRowIndexes
        guard let first = rows.first else { return }
        for i in rows.reversed() { clips.remove(at: i) }
        let next = min(first, clips.count - 1)
        reload(selecting: next >= 0 ? IndexSet(integer: next) : [])
    }

    private func reload(selecting rows: IndexSet) {
        table.reloadData()
        table.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { table.scrollRowToVisible(first) }
        placeholder.isHidden = !clips.isEmpty
        if clips.isEmpty {
            summary.stringValue = " "
        } else {
            let unknown = clips.filter { $0.duration == nil }.count
            summary.stringValue = "\(clips.count) clip\(clips.count == 1 ? "" : "s"), total \(Format.duration(totalDuration))"
                + (unknown > 0 ? "  (\(unknown) of unknown length)" : "")
                + "     Drag rows to reorder · ⌫ removes"
        }
        updateButtons()
        onChange?()
    }

    private func updateButtons() {
        let hasSelection = table.selectedRow >= 0
        for (key, b) in buttons {
            switch key {
            case "add": b.isEnabled = !isLocked
            case "sort", "clear": b.isEnabled = !isLocked && !clips.isEmpty
            default: b.isEnabled = !isLocked && hasSelection
            }
        }
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let c = clips[row]
        switch tableColumn?.identifier.rawValue {
        case "num": return "\(row + 1)"
        case "name": return c.name
        case "recorded": return c.recorded.map { dateFormatter.string(from: $0) } ?? "unknown"
        case "duration": return c.duration.map { Format.duration($0) } ?? "?"
        case "folder": return c.url.deletingLastPathComponent().path
        default: return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: - Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !isLocked else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !isLocked else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return (info.draggingSource as? NSTableView) === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard !isLocked else { return false }
        if (info.draggingSource as? NSTableView) === tableView {
            let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
            move(rows: rows, to: row)
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        add(urls)
        return !urls.isEmpty
    }
}

/// Table that turns Delete/Backspace into "remove selected".
final class ClipTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}
