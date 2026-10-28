import AppKit
import UniformTypeIdentifiers

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
        if ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] == nil {
            listener = SingleInstance.Listener { [weak self] req in self?.handle(req) }
        }
        for url in cliFiles { open(url) }
        if let stdinText { show(.text(stdinText, title: "stdin")) }
        // Finder/`open` delivers URLs via application(_:open:) around launch; wait one tick.
        DispatchQueue.main.async { [self] in
            if !openedAny { showOpenPanel() }
        }
        NSApp.activate(ignoringOtherApps: true)

        if let path = ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] {
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

    /// Arguments forwarded by a second `viw` process (see SingleInstance).
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
        appMenu.addItem(withTitle: "About viw", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide viw", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit viw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "viw"))

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
        view.addItem(withTitle: "Detail Pane: Right / Bottom", action: #selector(ViewerWindowController.togglePanePosition(_:)), keyEquivalent: "D")
        view.addItem(withTitle: "PDF: Page / Scroll View", action: #selector(ViewerWindowController.togglePageMode(_:)), keyEquivalent: "P")
        view.addItem(withTitle: "PDF: Page Overview", action: #selector(ViewerWindowController.toggleThumbnails(_:)), keyEquivalent: "T")
        view.addItem(NSMenuItem.separator())
        view.addItem(withTitle: "Next Sheet", action: #selector(ViewerWindowController.selectNextSheet(_:)), keyEquivalent: "]")
        view.addItem(withTitle: "Previous Sheet", action: #selector(ViewerWindowController.selectPreviousSheet(_:)), keyEquivalent: "[")
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

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Keyboard Shortcuts", action: #selector(ViewerWindowController.toggleHelp(_:)), keyEquivalent: "/")
        main.addItem(submenu(help, title: "Help"))
        NSApp.helpMenu = help

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
    viw — vim-keyed viewer (markdown, code, JSON, CSV, xlsx, PDF, images)

    usage: viw [FILE ...]        open files (markdown, source code, .json, .csv / .tsv, .xlsx, .pdf, images)
           cat FILE | viw        read markdown from stdin
           viw --set-default     make viw the default app for its file types (or: --set-default md csv)

    keys (`?` in the app shows the ones for the current view):

    """)
    print(KeyHelp.plainText(KeyHelp.common + [KeyHelp.text, KeyHelp.table, KeyHelp.sheets, KeyHelp.pdf, KeyHelp.image]))
    print("    A second `viw` hands its files to the running instance (they open as tabs).")
    exit(0)
}

// Debug: `viw --unzip archive.zip` lists the entries, `viw --unzip archive.zip name` writes one to stdout.
if args.first == "--unzip", args.count >= 2 {
    do {
        let zip = try ZipArchive(url: URL(fileURLWithPath: args[1]))
        if args.count == 2 {
            for n in zip.names { print("\(zip.entries[n]!.uncompressedSize)\t\(zip.entries[n]!.method == 8 ? "deflate" : "stored")\t\(n)") }
        } else {
            FileHandle.standardOutput.write(try zip.data(for: args[2]))
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("viw: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Debug: `viw --xlsx book.xlsx` lists the sheets, `viw --xlsx book.xlsx N` (or a sheet name) writes that sheet as TSV.
if args.first == "--xlsx", args.count >= 2 {
    do {
        let t0 = CFAbsoluteTimeGetCurrent()
        let wb = try Workbook(url: URL(fileURLWithPath: args[1]))
        if args.count == 2 {
            for (i, s) in wb.sheets.enumerated() { print("\(i + 1)\t\(s.name)\(s.hidden ? "\t(hidden)" : "")") }
        } else {
            guard let i = Int(args[2]).map({ $0 - 1 }) ?? wb.sheets.firstIndex(where: { $0.name == args[2] }), wb.sheets.indices.contains(i) else {
                FileHandle.standardError.write("viw: no sheet \(args[2])\n".data(using: .utf8)!)
                exit(1)
            }
            let t = try wb.table(forSheet: i)
            var out = t.header.joined(separator: "\t") + "\n"
            for r in t.rows { out += r.joined(separator: "\t") + "\n" }
            FileHandle.standardOutput.write(out.data(using: .utf8)!)
            if ProcessInfo.processInfo.environment["VIW_TIMING"] != nil {
                FileHandle.standardError.write("xlsx: \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms (\(t.rows.count) rows × \(t.columnCount) cols)\n".data(using: .utf8)!)
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("viw: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// `viw --set-default [ext ...]`: make viw the default app for its document types (every
// extension in Info.plist when none is given). Needs the installed app bundle; the CLI symlink
// in ~/.local/bin resolves to it.
if args.first == "--set-default" {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let bundleURL = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard bundleURL.pathExtension == "app", let bundle = Bundle(url: bundleURL), let bundleID = bundle.bundleIdentifier,
          let types = bundle.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else {
        FileHandle.standardError.write("viw: --set-default needs the installed app (mise r install, then viw --set-default)\n".data(using: .utf8)!)
        exit(1)
    }
    var exts = args.dropFirst().map { $0.hasPrefix(".") ? String($0.dropFirst()).lowercased() : $0.lowercased() }
    // Web pages stay with the browser unless asked for by name.
    let browserTypes: Set<String> = ["html", "htm"]
    if exts.isEmpty { exts = types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }.filter { !browserTypes.contains($0) } }
    let lock = NSLock()
    var errors: [String: String] = [:]
    let group = DispatchGroup()
    var wanted: [(String, UTType)] = []
    for ext in exts {
        guard let type = UTType(filenameExtension: ext) else { errors[ext] = "no type for the extension"; continue }
        wanted.append((ext, type))
        group.enter()
        NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type) { error in
            if let error { lock.lock(); errors[ext] = error.localizedDescription; lock.unlock() }
            group.leave()
        }
    }
    // Completions may arrive on the main queue: pump it while waiting.
    while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    var failed = 0
    for (ext, type) in wanted {
        let now = LSCopyDefaultRoleHandlerForContentType(type.identifier as CFString, .all)?.takeRetainedValue() as String? ?? "?"
        let ok = errors[ext] == nil && now == bundleID
        if !ok { failed += 1 }
        print(".\(ext)".padding(toLength: 10, withPad: " ", startingAt: 0) + type.identifier.padding(toLength: 56, withPad: " ", startingAt: 0)
              + (ok ? "viw" : "FAILED: \(errors[ext] ?? "still \(now)")"))
    }
    for (ext, e) in errors where !wanted.contains(where: { $0.0 == ext }) { print(".\(ext): \(e)"); failed += 1 }
    exit(failed == 0 ? 0 : 1)
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
if files.isEmpty, stdinText == nil, isatty(STDIN_FILENO) == 0, ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] == nil {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if !data.isEmpty { stdinText = String(decoding: data, as: UTF8.self) }
}

if ProcessInfo.processInfo.environment["VIW_SNAPSHOT"] == nil,
   SingleInstance.forward(.init(files: files.map(\.standardizedFileURL.path), stdin: stdinText)) {
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if ProcessInfo.processInfo.environment["VIW_DARK"] != nil { app.appearance = NSAppearance(named: .darkAqua) }
let delegate = AppDelegate(cliFiles: files, stdinText: stdinText)
app.delegate = delegate
app.run()
