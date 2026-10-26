import AppKit
import TimelapserCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let tabView = NSTabView()
    private let timelapse = TimelapseTab()
    private let join = JoinTab()
    private var launched = false
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let timelapseItem = NSTabViewItem(identifier: "timelapse")
        timelapseItem.label = "Timelapse"
        timelapseItem.view = timelapse.view
        let joinItem = NSTabViewItem(identifier: "join")
        joinItem.label = "Join Clips"
        joinItem.view = join.view
        tabView.addTabViewItem(timelapseItem)
        tabView.addTabViewItem(joinItem)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "GoPro Timelapser"
        window.minSize = NSSize(width: 780, height: 720)
        window.delegate = self
        let content = NSView()
        content.addSubview(tabView)
        tabView.pinEdges(to: content, insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        window.contentView = content
        window.setFrameAutosaveName("MainWindow")
        if window.frame.origin == .zero { window.center() }

        // Clips passed on the command line (used for screenshots/tests) go into both tabs.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !args.isEmpty {
            let urls = args.map { URL(fileURLWithPath: $0) }
            timelapse.clips.add(urls)
            join.clips.add(urls)
        }
        if ProcessInfo.processInfo.environment["GPT_TAB"] == "join" { tabView.selectTabViewItem(at: 1) }
        launched = true
        if !pendingFiles.isEmpty { addToVisibleTab(pendingFiles) }
        pendingFiles = []

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files dropped on the Dock icon go into the visible tab. macOS can deliver these before
    /// applicationDidFinishLaunching (e.g. when the drop also launches the app), so hold them until then.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if launched {
            addToVisibleTab(urls)
        } else {
            pendingFiles += urls
        }
        sender.reply(toOpenOrPrint: .success)
    }

    private func addToVisibleTab(_ urls: [URL]) {
        let joinVisible = tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) == 1 } ?? false
        if joinVisible { join.clips.add(urls) } else { timelapse.clips.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard timelapse.isRunning || join.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A video is still being created."
        alert.informativeText = "Quit anyway? The unfinished file will be deleted."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GoPro Timelapser", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GoPro Timelapser", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit GoPro Timelapser", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
