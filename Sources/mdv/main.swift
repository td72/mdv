import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    private var controllers: [ViewerWindowController] = []
    private var openedAny = false
    private var listener: SingleInstance.Listener?
    private let cliFiles: [URL]
    private let stdinText: String?

    init(cliFiles: [URL], stdinText: String?) {
        self.cliFiles = cliFiles
        self.stdinText = stdinText
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if ProcessInfo.processInfo.environment["MDV_SNAPSHOT"] == nil {
            listener = SingleInstance.Listener { [weak self] req in self?.handle(req) }
        }
        for url in cliFiles { open(url) }
        if let stdinText { show(.text(stdinText, title: "stdin")) }
        // Finder/`open` delivers URLs via application(_:open:) around launch; wait one tick.
        DispatchQueue.main.async { [self] in
            if !openedAny { showOpenPanel() }
        }
        NSApp.activate(ignoringOtherApps: true)

        if let path = ProcessInfo.processInfo.environment["MDV_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                controllers.first?.snapshot(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showOpenPanel() }
        return true
    }

    func open(_ url: URL) { show(.file(url.standardizedFileURL)) }

    /// Arguments forwarded by a second `mdv` process (see SingleInstance).
    private func handle(_ req: SingleInstance.Request) {
        for path in req.files { open(URL(fileURLWithPath: path)) }
        if let text = req.stdin { show(.text(text, title: "stdin")) }
        NSApp.activate(ignoringOtherApps: true)
        if req.files.isEmpty, req.stdin == nil { showOpenPanel() }
    }

    /// The first document gets a window; later ones join it as tabs (the key window if
    /// there are several). Tabs live inside the window — see ViewerWindowController.
    private func show(_ source: Source) {
        openedAny = true
        if let host = tabHost() {
            host.addTab(source)
            host.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = ViewerWindowController(source: source)
        c.onClose = { [weak self] c in self?.controllers.removeAll { $0 === c } }
        controllers.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private func tabHost() -> ViewerWindowController? {
        let visible = controllers.filter { $0.window?.isVisible == true }
        return visible.first { $0.window?.isKeyWindow == true }
            ?? visible.first { $0.window?.isMainWindow == true }
            ?? visible.last
    }

    @objc func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.plainText, .text, .data]
        if panel.runModal() == .OK {
            for u in panel.urls { open(u) }
        } else if controllers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About mdv", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide mdv", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit mdv", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "mdv"))

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Tab…", action: #selector(showOpenPanel), keyEquivalent: "t")
        file.addItem(withTitle: "Open…", action: #selector(showOpenPanel), keyEquivalent: "o")
        file.addItem(withTitle: "Reload", action: #selector(ViewerWindowController.reloadDocument(_:)), keyEquivalent: "r")
        file.addItem(withTitle: "Reveal in Finder", action: #selector(ViewerWindowController.revealInFinder(_:)), keyEquivalent: "R")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        for (title, key, action) in [
            ("Find…", "f", NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .nextMatch),
            ("Find Previous", "G", .previousMatch),
            ("Use Selection for Find", "e", .setSearchString),
        ] {
            let item = edit.addItem(withTitle: title, action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: key)
            item.tag = action.rawValue
        }
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(ViewerWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(ViewerWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(ViewerWindowController.actualSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(ViewerWindowController.selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(ViewerWindowController.selectPreviousTab(_:)), keyEquivalent: "{")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("-h") || args.contains("--help") {
    print("""
    mdv — markdown viewer (vi/vim keys)

    usage: mdv [FILE ...]        open files (GFM)
           cat FILE | mdv        read markdown from stdin

    keys:  j/k ^e/^y  line      d/u ^d/^u  half page    f/b ^f/^b space  page
           gg / G    top/bottom  5G  go to 50%  (counts work: 5j, 3d, ...)
           /  find   n/N  next/prev    y  copy selection    r  reload
           o  open   q  close tab/window   + / -  zoom   =  reset zoom
           gt / gT  Tab / S-Tab  next / previous tab    3gt  third tab   ⌘1-9  nth / last tab

    A second `mdv` hands its files to the running instance (they open as tabs).
    """)
    exit(0)
}

var files: [URL] = []
var stdinText: String?
for a in args where !a.hasPrefix("-") || a == "-" {
    if a == "-" {
        stdinText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    } else {
        files.append(URL(fileURLWithPath: a, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
    }
}
if files.isEmpty, stdinText == nil, isatty(STDIN_FILENO) == 0, ProcessInfo.processInfo.environment["MDV_SNAPSHOT"] == nil {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if !data.isEmpty { stdinText = String(decoding: data, as: UTF8.self) }
}

if ProcessInfo.processInfo.environment["MDV_SNAPSHOT"] == nil,
   SingleInstance.forward(.init(files: files.map(\.standardizedFileURL.path), stdin: stdinText)) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if ProcessInfo.processInfo.environment["MDV_DARK"] != nil { app.appearance = NSAppearance(named: .darkAqua) }
let delegate = AppDelegate(cliFiles: files, stdinText: stdinText)
app.delegate = delegate
app.run()
