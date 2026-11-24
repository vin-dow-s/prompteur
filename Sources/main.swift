// Prompteur: a teleprompter band that floats above every window, a
// full-screen browser included, and never takes the keyboard from it.
// It reads a script (Markdown or JSON) and shows one sentence at a time.
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

struct Line: Decodable {
    let say: String
    let show: String
    let highlight: Bool

    init(say: String, show: String, highlight: Bool) {
        self.say = say
        self.show = show
        self.highlight = highlight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        say = try c.decode(String.self, forKey: .say)
        show = try c.decodeIfPresent(String.self, forKey: .show) ?? ""
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? false
    }

    enum CodingKeys: String, CodingKey { case say, show, highlight }
}

struct Section: Decodable {
    let title: String
    let subtitle: String
    var lines: [Line] = []

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        lines = try c.decode([Line].self, forKey: .lines)
    }

    enum CodingKeys: String, CodingKey { case title, subtitle, lines }
}

// What went wrong, for the white line of the band, and what to do about it,
// for the blue one under it.
struct ScriptError: LocalizedError {
    static let fixIt = "Fix the file and save it: the band reads it again"
    static let chooseOne = "Menu bar icon → Script → Create ~/Prompteur/script.md, or Choose a File…"
    let errorDescription: String?
    let hint: String
    init(_ message: String, hint: String = ScriptError.fixIt) {
        errorDescription = message
        self.hint = hint
    }
}

enum Script {
    // Far more than a script needs, and little enough that a file picked by
    // mistake, a log of gigabytes say, cannot freeze the band while it is read.
    static let maxBytes = 1_000_000

    static func load(_ url: URL) throws -> [Section] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScriptError("\(url.lastPathComponent) was not found", hint: ScriptError.chooseOne)
        }
        let file = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if let size = file?.fileSize, size > maxBytes {
            throw ScriptError("\(url.lastPathComponent) is too big to be a script",
                              hint: "A script is a text file of 1 MB at most")
        }
        guard file?.isRegularFile == true, let data = try? Data(contentsOf: url) else {
            throw ScriptError("\(url.lastPathComponent) could not be opened")
        }
        let sections: [Section]
        if url.pathExtension.lowercased() == "json" {
            do {
                sections = try JSONDecoder().decode([Section].self, from: data)
            } catch let error as DecodingError {
                throw ScriptError("\(url.lastPathComponent) is not a Prompteur script: \(describe(error))")
            }
        } else {
            sections = markdown(String(decoding: data, as: UTF8.self))
        }
        let kept = sections.filter { !$0.lines.isEmpty }
        if kept.isEmpty {
            throw ScriptError("\(url.lastPathComponent) has no sentence yet",
                              hint: "Write each sentence as a table row: | what you say | what you show |")
        }
        return kept
    }

    // JSONDecoder's own message ("isn't in the correct format") names
    // neither the field nor the place, which is all anybody needs to fix it.
    static func describe(_ error: DecodingError) -> String {
        // [0, "lines", 2] reads "in section 1, line 3".
        func place(_ path: [CodingKey]) -> String {
            var words: [String] = []
            for (i, key) in path.enumerated() {
                guard let n = key.intValue else { continue }
                words.append(i > 0 && path[i - 1].stringValue == "lines" ? "line \(n + 1)" : "section \(n + 1)")
            }
            return words.isEmpty ? "" : " in " + words.joined(separator: ", ")
        }
        switch error {
        case .keyNotFound(let key, let c): return "\"\(key.stringValue)\" is missing\(place(c.codingPath))"
        case .typeMismatch(_, let c) where c.codingPath.isEmpty:
            return "it should be a list of sections, [ { \"title\": …, \"lines\": [ … ] } ]"
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return "wrong value\(place(c.codingPath))"
        case .dataCorrupted(let c): return c.codingPath.isEmpty ? "invalid JSON" : "invalid value\(place(c.codingPath))"
        @unknown default: return "invalid JSON"
        }
    }

    // A heading opens a section ("Title · subtitle"), and every row of a
    // table under it is a sentence: what to say, then what to show. Anything
    // else in the file is left alone, so a script can carry its own notes.
    static func markdown(_ text: String) -> [Section] {
        var sections: [Section] = []
        // Windows line endings and a byte order mark are what a script saved
        // by another editor brings; either would hide a heading or a header.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let rows = normalized.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, row) in rows.enumerated() {
            if let heading = heading(row) {
                let parts = heading.components(separatedBy: " · ")
                sections.append(Section(title: parts[0], subtitle: parts.dropFirst().joined(separator: " · ")))
                continue
            }
            guard row.hasPrefix("|"), !isRule(row) else { continue }
            // The row right above a |---| rule is the table's header.
            if i + 1 < rows.count, isRule(rows[i + 1]) { continue }
            let cells = self.cells(row)
            var say = cells.first ?? ""
            let show = cells.count > 1 ? cells[1] : ""
            var highlight = false
            if say.hasPrefix("!") {
                highlight = true
                say = String(say.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if say.isEmpty { continue }
            if sections.isEmpty { sections.append(Section(title: "", subtitle: "")) }
            sections[sections.count - 1].lines.append(Line(say: say, show: show, highlight: highlight))
        }
        return sections
    }

    // "## Title", one to six hashes and a space, as Markdown has it: "#tag"
    // at the start of a note is not a heading.
    static func heading(_ row: String) -> String? {
        let hashes = row.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = row.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
    }

    static func cells(_ row: String) -> [String] {
        // "\|" is a pipe inside a cell, not a column.
        let pipe = "\u{E000}"
        var inner = Substring(row.replacingOccurrences(of: "\\|", with: pipe))
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.components(separatedBy: "|").map { plain($0.replacingOccurrences(of: pipe, with: "|")) }
    }

    // Markdown inside a cell is shown as the text it stands for: bold and
    // code marks dropped, a link reduced to its words.
    static func plain(_ cell: String) -> String {
        var s = cell.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "<br>", with: " ")
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func isRule(_ row: String) -> Bool {
        guard row.hasPrefix("|"), row.contains("-") else { return false }
        return row.allSatisfy { "|-: ".contains($0) }
    }
}

// A window that never becomes the active one: a click on it does not pull the
// browser out of full screen or take its scrolling away.
final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class StripView: NSView {
    var onMenu: ((NSEvent) -> Void)?

    // The whole band is one handle to drag it by: the labels do not take the
    // click, only the close button does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = super.hitTest(point), hit is NSButton { return hit }
        return frame.contains(point) ? self : nil
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A click does nothing but move the band: with a click that also stepped
    // through the script, putting the band in place cost a sentence.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
}

final class CloseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A menu row with a switch. A ticked menu item shows nothing while it is
// off, so nothing says it is a setting; a switch shows both states, and
// flipping it leaves the menu open.
final class SwitchRow: NSView {
    let toggle = NSSwitch()
    let onChange: (Bool) -> Void

    init(title: String, shortcut: String, isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        let keys = NSTextField(labelWithString: shortcut)
        keys.textColor = .tertiaryLabelColor
        toggle.controlSize = .mini
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel(title)
        for view in [label, keys, toggle] {
            (view as? NSTextField)?.font = .menuFont(ofSize: 0)
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        // Where a menu starts its own titles, and how tall its rows are, so
        // that this row lines up with the ones around it. macOS 26 made its
        // menus roomier.
        var inset: CGFloat = 14
        var height: CGFloat = 22
        if #available(macOS 26, *) {
            inset = 16
            height = 24
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            keys.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 40),
            toggle.leadingAnchor.constraint(equalTo: keys.trailingAnchor, constant: 8),
            trailingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: inset + 2),
        ])
        // The menu is as wide as this row needs, and stretches it if another
        // item needs more.
        setFrameSize(fittingSize)
        autoresizingMask = .width
    }

    required init?(coder: NSCoder) { nil }

    @objc func changed() { onChange(toggle.state == .on) }

    // A click anywhere on the row flips the switch, not only one on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSSwitch ? hit : (hit == nil ? nil : self)
    }
    override func mouseUp(with event: NSEvent) { toggle.performClick(nil) }
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var sections: [Section] = []
    var sectionIndex = 0
    var lineIndex = 0
    var source: URL?
    var problem: String?
    var problemHint = ""
    var panel: Panel!
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let meta = NSTextField(labelWithString: "")
    let say = NSTextField(wrappingLabelWithString: "")
    let show = NSTextField(labelWithString: "")
    let defaults = UserDefaults.standard

    var capturable = false
    var notice: String?
    var noticeAlert = false
    var noticeTimer: Timer?
    weak var captureSwitch: NSSwitch?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hidden from screenshots and recordings unless asked: the band is
        // there for the person reading it, not for the people watching.
        capturable = defaults.bool(forKey: "visibleInCaptures")
        build()
        buildStatusItem()
        registerHotKeys()
        watchOption()

        load(initialScript())
        watchScripts()
        if sections.indices.contains(defaults.integer(forKey: "section")) {
            sectionIndex = defaults.integer(forKey: "section")
        }
        render()
    }

    // MARK: - Scripts

    func bundledScript() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        return ["script.json", "script.md"].map { res.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // ~/Prompteur/script.md (or .json): a place anybody, an AI agent
    // included, can write a script to without knowing where the app is. Not
    // ~/Documents, which macOS guards behind a permission prompt.
    static let inboxFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Prompteur")

    func inboxScript() -> URL? {
        ["script.md", "script.json"].map { App.inboxFolder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { (modified($0) ?? .distantPast) < (modified($1) ?? .distantPast) }
    }

    // Of the file a link points to: the link's own date never changes.
    func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    // --script FILE on the command line, for this launch. Otherwise what the
    // user chose last wins: a file opened from the menu, or the built-in
    // script ("builtin"). Then the inbox, then the built-in one.
    func initialScript() -> URL? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--script"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]) }
        let saved = defaults.string(forKey: "scriptPath")
        if saved == "builtin", let bundled = bundledScript() { return bundled }
        if let saved, saved != "builtin", FileManager.default.fileExists(atPath: saved) {
            return URL(fileURLWithPath: saved)
        }
        return inboxScript() ?? bundledScript()
    }

    func load(_ url: URL?) {
        source = url
        sourceSeen = url.flatMap(modified)
        guard let url else {
            sections = []
            problem = "No script yet"
            problemHint = ScriptError.chooseOne
            return
        }
        do {
            sections = try Script.load(url)
            problem = nil
        } catch {
            sections = []
            problem = error.localizedDescription
            problemHint = (error as? ScriptError)?.hint ?? ScriptError.fixIt
        }
        sectionIndex = min(sectionIndex, max(sections.count - 1, 0))
        lineIndex = sections.isEmpty ? 0 : min(lineIndex, sections[sectionIndex].lines.count - 1)
    }

    // Reads the script again after an edit. The place is kept by section
    // title, so a section added above the current one does not move it; and
    // a file caught half written keeps the old script on screen rather than
    // an error, since the next save will be read in turn.
    func refresh(_ url: URL, keepPlace: Bool, announce: String) {
        sourceSeen = modified(url)
        do {
            let fresh = try Script.load(url)
            let title = sections.indices.contains(sectionIndex) ? sections[sectionIndex].title : nil
            sections = fresh
            source = url
            problem = nil
            if keepPlace {
                if let title, let i = fresh.firstIndex(where: { $0.title == title }) { sectionIndex = i }
                sectionIndex = min(sectionIndex, fresh.count - 1)
                lineIndex = min(lineIndex, fresh[sectionIndex].lines.count - 1)
            } else {
                sectionIndex = 0
                lineIndex = 0
            }
            flash(announce)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                if !sections.isEmpty { flash("\(url.lastPathComponent) was deleted: the band keeps its last version", alert: true) }
                return
            }
            if sections.isEmpty {
                source = url
                problem = error.localizedDescription
                problemHint = (error as? ScriptError)?.hint ?? ScriptError.fixIt
                render()
            } else {
                flash(error.localizedDescription, alert: true)
            }
        }
    }

    // Once a second, the modification dates of the script on screen and of
    // the inbox. A timer rather than a file watcher: editors and agents save
    // by writing a new file and renaming it over the old one, which a watcher
    // on the old file never sees.
    var sourceSeen: Date?
    var inboxSeen: Date?

    func watchScripts() {
        inboxSeen = inboxScript().flatMap(modified)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkScripts() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func checkScripts() {
        if let inbox = inboxScript(), let date = modified(inbox), date != inboxSeen {
            inboxSeen = date
            if inbox == source {
                refresh(inbox, keepPlace: true, announce: "Script updated")
            } else {
                // A new script in the inbox is somebody asking for it to be read.
                defaults.removeObject(forKey: "scriptPath")
                refresh(inbox, keepPlace: false, announce: "Script loaded from ~/Prompteur")
            }
            return
        }
        if let source, modified(source) != sourceSeen {
            refresh(source, keepPlace: true, announce: "Script updated")
        }
    }

    var openDialog: NSOpenPanel?

    // Modeless, not runModal: a modal dialog froze the band (no drag, no
    // cross) for as long as it was open, and when it opened behind a
    // full-screen app nobody could see it to close it.
    @objc func openScript() {
        if let openDialog {
            NSApp.activate(ignoringOtherApps: true)
            openDialog.makeKeyAndOrderFront(nil)
            return
        }
        let previous = NSWorkspace.shared.frontmostApplication
        let dialog = NSOpenPanel()
        dialog.message = "Choose a script (Markdown or JSON)"
        dialog.prompt = "Open Script"
        dialog.allowedContentTypes = [.json, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        if let source, source != bundledScript() { dialog.directoryURL = source.deletingLastPathComponent() }
        // Above the band, on the Space in use, a full-screen app's included.
        dialog.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        dialog.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        openDialog = dialog
        NSApp.activate(ignoringOtherApps: true)
        dialog.begin { [weak self] response in
            guard let self else { return }
            self.openDialog = nil
            if response == .OK, let url = dialog.url {
                self.defaults.set(url.path, forKey: "scriptPath")
                self.start(url)
            }
            // The keyboard goes back to the app being shown, as it was.
            if let previous, previous != NSRunningApplication.current {
                previous.activate()
            }
        }
    }

    // Puts a script on the band, from its first sentence.
    func start(_ url: URL?) {
        sectionIndex = 0
        lineIndex = 0
        load(url)
        render()
    }

    @objc func useBundledScript() {
        defaults.set("builtin", forKey: "scriptPath")
        start(bundledScript())
    }

    // With no script chosen from the menu, the inbox is what a launch opens.
    @objc func useInbox() {
        guard let inbox = inboxScript() else { return }
        defaults.removeObject(forKey: "scriptPath")
        inboxSeen = modified(inbox)
        start(inbox)
    }

    static let starter = """
    # My script

    Each heading is a part of the video, and each row of a table under it is
    one sentence: what you say on the left, what you show on the right. Save
    this file and the band shows it. Anything outside the tables, like this
    paragraph, is ignored.

    ## Intro · home page

    | Say | Show |
    |---|---|
    | Hi, I'm going to show you something I built. | Open the home page |
    | It takes one minute. | Point at the main button |
    | ! A sentence starting with an exclamation mark is shown in yellow. | |

    """

    // The inbox made for somebody who has never seen the format: a starter
    // script written there, put on the band and opened in their editor.
    @objc func createInbox() {
        let file = App.inboxFolder.appendingPathComponent("script.md")
        if !FileManager.default.fileExists(atPath: file.path) {
            do {
                try FileManager.default.createDirectory(at: App.inboxFolder, withIntermediateDirectories: true)
                try App.starter.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                flash("Could not create \(file.path): \(error.localizedDescription)", alert: true)
                return
            }
        }
        useInbox()
        editScript()
    }

    @objc func editScript() {
        guard let source else { return }
        NSWorkspace.shared.open([source], withApplicationAt: editor(for: source), configuration: NSWorkspace.OpenConfiguration())
    }

    // The app set to open Markdown, unless it is Xcode: installing Xcode
    // makes it the owner of .md on any Mac where nothing else claimed it, and
    // a whole IDE is a strange place to write four sentences. Then, as with
    // none at all, the default text editor (TextEdit, or whatever replaced it).
    func editor(for file: URL) -> URL {
        let workspace = NSWorkspace.shared
        if let app = workspace.urlForApplication(toOpen: file), app.lastPathComponent != "Xcode.app" { return app }
        return workspace.urlForApplication(toOpen: .plainText) ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    }

    @objc func revealScript() {
        guard let source else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }

    // MARK: - The band

    // Centred under the camera. Below the notch: the pixels beside it do not
    // exist for a full-screen app, and the text there would be half hidden.
    func homeRect() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        let top = f.maxY - screen.safeAreaInsets.top
        let w = min(f.width - 240, 1120)
        let h: CGFloat = 118
        return NSRect(x: f.midX - w / 2, y: top - h - 2, width: w, height: h)
    }

    func build() {
        var rect = homeRect()
        let h = rect.height
        if let saved = defaults.string(forKey: "bandOrigin") {
            let moved = NSRect(origin: NSPointFromString(saved), size: rect.size)
            // Only where a screen still is: a band saved on a display that has
            // since been unplugged would be out of reach.
            if NSScreen.screens.contains(where: { $0.frame.intersects(moved) }) { rect = moved }
        }

        panel = Panel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        applyCapture()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.defaults.set(NSStringFromPoint(self.panel.frame.origin), forKey: "bandOrigin")
        }

        let view = StripView(frame: NSRect(origin: .zero, size: rect.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0, alpha: 0.94).cgColor
        view.layer?.cornerRadius = 14
        view.onMenu = { [weak self] event in
            guard let self else { return }
            self.menuNeedsUpdate(self.menu)
            NSMenu.popUpContextMenu(self.menu, with: event, for: view)
        }

        meta.font = .systemFont(ofSize: 12, weight: .medium)
        meta.alignment = .center
        meta.lineBreakMode = .byTruncatingTail

        say.font = .systemFont(ofSize: 27, weight: .semibold)
        say.alignment = .center
        say.maximumNumberOfLines = 0
        say.lineBreakMode = .byWordWrapping
        say.cell?.truncatesLastVisibleLine = true
        say.allowsDefaultTighteningForTruncation = true

        show.font = .systemFont(ofSize: 15, weight: .semibold)
        show.textColor = NSColor(red: 0.39, green: 0.82, blue: 1, alpha: 1)
        show.alignment = .center
        show.lineBreakMode = .byTruncatingTail

        let pad: CGFloat = 22
        let inner = rect.width - pad * 2
        meta.frame = NSRect(x: pad + 24, y: h - 23, width: inner - 48, height: 16)
        say.frame = NSRect(x: pad, y: 28, width: inner, height: 66)
        show.frame = NSRect(x: pad, y: 6, width: inner, height: 20)
        for label in [meta, say, show] { view.addSubview(label) }

        let close = CloseButton(frame: NSRect(x: rect.width - 32, y: h - 28, width: 22, height: 22))
        close.isBordered = false
        close.imagePosition = .imageOnly
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit Prompteur")
        close.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        close.contentTintColor = NSColor(white: 0.5, alpha: 1)
        close.toolTip = "Quit Prompteur (⌥Q)"
        close.target = NSApp
        close.action = #selector(NSApplication.terminate(_:))
        view.addSubview(close)

        panel.contentView = view
        panel.orderFrontRegardless()
    }

    func render() {
        let text: String
        var color = NSColor.white
        if sections.isEmpty {
            meta.stringValue = "Prompteur"
            text = problem ?? ""
            show.stringValue = problemHint
        } else {
            let section = sections[sectionIndex]
            let line = section.lines[lineIndex]
            // A script with no heading has one untitled section: no number to give.
            let title = section.title.isEmpty ? (sections.count > 1 ? "\(sectionIndex + 1)." : "") : "\(sectionIndex + 1). \(section.title)"
            let head = [title, section.subtitle, "\(lineIndex + 1)/\(section.lines.count)"].filter { !$0.isEmpty }
            meta.stringValue = head.joined(separator: " · ") + "   ⌥ next  ⌥← back  ⌥↓ ⌥↑ section  ⌥Q quit"
            text = line.say
            if line.highlight { color = NSColor(red: 1, green: 0.84, blue: 0.04, alpha: 1) }
            show.stringValue = line.show
            defaults.set(sectionIndex, forKey: "section")
        }
        meta.textColor = NSColor(white: 0.55, alpha: 1)
        if let notice {
            meta.stringValue = notice
            meta.textColor = noticeAlert ? NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1) : NSColor(white: 0.85, alpha: 1)
        }
        say.stringValue = text
        say.textColor = color
        // A long sentence shrinks, to three lines at most, rather than being
        // cut; only past the smallest size is it ended with an ellipsis.
        // Measured by the label itself, with no cap on its lines: capped, as it
        // once was at two, it always answered that the text fitted.
        // With nothing to show under it, the sentence has the blue line's
        // room too, and sits in the middle of the band rather than above a gap.
        let box: CGFloat = show.stringValue.isEmpty ? 78 : 66
        let bottom: CGFloat = show.stringValue.isEmpty ? 10 : 28
        func needed(_ size: CGFloat) -> CGFloat {
            say.font = .systemFont(ofSize: size, weight: .semibold)
            return ceil(say.sizeThatFits(NSSize(width: say.frame.width, height: 10_000)).height)
        }
        var size: CGFloat = 27
        while size > 15 && needed(size) > box { size -= 1 }
        let fit = min(needed(size), box)
        say.frame = NSRect(x: say.frame.minX, y: bottom + (box - fit) / 2, width: say.frame.width, height: fit)
    }

    // Moving on makes any notice on the band old news: "End of the script"
    // over a sentence from the middle of it would be wrong.
    func clearNotice() {
        notice = nil
        noticeTimer?.invalidate()
    }

    func step(_ d: Int) {
        guard !sections.isEmpty else { return }
        clearNotice()
        let n = sections[sectionIndex].lines.count
        if lineIndex + d >= n {
            // Past the last sentence, moving on opens the next section.
            if sectionIndex < sections.count - 1 { sectionIndex += 1; lineIndex = 0 } else { flash("End of the script"); return }
        } else if lineIndex + d < 0 {
            // And back from the first one returns to the end of the one before.
            if sectionIndex > 0 { sectionIndex -= 1; lineIndex = sections[sectionIndex].lines.count - 1 } else { return }
        } else {
            lineIndex += d
        }
        render()
    }

    func stepSection(_ d: Int) {
        guard !sections.isEmpty else { return }
        clearNotice()
        sectionIndex = min(sections.count - 1, max(0, sectionIndex + d))
        lineIndex = 0
        render()
    }

    @objc func goToSection(_ item: NSMenuItem) {
        guard item.tag < sections.count else { return }
        clearNotice()
        sectionIndex = item.tag
        lineIndex = 0
        render()
    }

    @objc func resetPosition() {
        panel.setFrame(homeRect(), display: true)
        defaults.removeObject(forKey: "bandOrigin")
    }

    // MARK: - Visible in screenshots and recordings

    func applyCapture() {
        // .none keeps the band out of screenshots and screen recordings,
        // wherever the capture tool honours it; .readOnly lets it be captured
        // like any other window, for a demo of the tool itself.
        panel.sharingType = capturable ? .readOnly : .none
        let symbol = capturable ? "text.bubble.fill" : "text.bubble"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prompteur")
        image?.isTemplate = true
        statusItem?.button?.image = image
        // ⌥V with the menu open: its switch follows.
        captureSwitch?.state = capturable ? .on : .off
    }

    // Set by the switch in the menu, or by ⌥V.
    func setCapture(_ visible: Bool) {
        capturable = visible
        defaults.set(visible, forKey: "visibleInCaptures")
        applyCapture()
        flash(visible ? "● Visible in screenshots and recordings" : "Hidden from screenshots and recordings", alert: visible)
    }

    func flash(_ text: String, alert: Bool = false) {
        notice = text
        noticeAlert = alert
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            self?.notice = nil
            self?.render()
        }
        render()
    }

    // MARK: - Menu bar

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        applyCapture()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [],
                  on: Bool = false, submenu: NSMenu? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.state = on ? .on : .off
            item.submenu = submenu
            return item
        }

        // The scripts the band can show, the one it shows ticked, then what
        // can be done with that one.
        let inbox = inboxScript()
        let bundled = bundledScript()
        let name = source.map { $0 == bundled ? "Built-in" : shortPath($0) } ?? "None"
        let scripts = NSMenu()
        scripts.autoenablesItems = false
        if let inbox {
            scripts.addItem(item("~/Prompteur/\(inbox.lastPathComponent)", #selector(useInbox), on: source == inbox))
        } else {
            scripts.addItem(item("Create ~/Prompteur/script.md", #selector(createInbox)))
        }
        if bundled != nil {
            scripts.addItem(item("Built-in Script", #selector(useBundledScript), on: source == bundled))
        }
        if let source, source != inbox, source != bundled { scripts.addItem(item(name, nil, on: true)) }
        scripts.addItem(item("Choose a File…", #selector(openScript), key: "o", mods: .command))
        scripts.addItem(.separator())
        // The built-in script is part of the app: not a file to edit.
        for action in [item("Edit Script", #selector(editScript)), item("Show in Finder", #selector(revealScript))] {
            action.isEnabled = source != nil && source != bundled
            scripts.addItem(action)
        }
        menu.addItem(item("Script: \(name)", nil, submenu: scripts))

        if !sections.isEmpty {
            let list = NSMenu()
            for (i, section) in sections.enumerated() {
                let title = section.title.isEmpty ? "Section \(i + 1)" : "\(i + 1). \(section.title)"
                let entry = item(title, #selector(goToSection(_:)), on: i == sectionIndex)
                entry.tag = i
                list.addItem(entry)
            }
            menu.addItem(item("Go to Section", nil, submenu: list))
        }
        menu.addItem(.separator())

        let capture = SwitchRow(title: "Visible in Screenshots and Recordings", shortcut: "⌥V", isOn: capturable) { [weak self] in
            self?.setCapture($0)
        }
        captureSwitch = capture.toggle
        let row = NSMenuItem()
        row.view = capture
        menu.addItem(row)
        menu.addItem(item("Move Band Back Under the Camera", #selector(resetPosition)))
        menu.addItem(.separator())

        let quit = item("Quit Prompteur", #selector(NSApplication.terminate(_:)), key: "q", mods: .option)
        quit.target = NSApp
        menu.addItem(quit)
    }

    // A deep path would stretch the whole menu: its last two parts say enough.
    func shortPath(_ url: URL) -> String {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return path.count > 48 ? "…/" + url.pathComponents.suffix(2).joined(separator: "/") : path
    }

    // MARK: - Keyboard

    // Option alone, pressed then released, moves to the next sentence. Carbon
    // cannot register a shortcut with no key, and listening to the keyboard
    // would need the Accessibility permission, so the modifier state is read
    // sixty times a second instead, which macOS allows any app to do.
    var optionDownAt: Date?
    var optionSpoiled = false

    func watchOption() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.pollOption() }
        RunLoop.main.add(timer, forMode: .common)
    }

    func pollOption() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let option = flags.contains(.maskAlternate)
        let others = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskShift)
        if option {
            if optionDownAt == nil { optionDownAt = Date(); optionSpoiled = false }
            if others { optionSpoiled = true }
            return
        }
        guard let down = optionDownAt else { return }
        optionDownAt = nil
        let held = Date().timeIntervalSince(down)
        // A key or a click while Option was held: that was ⌥←, a character
        // typed with Option or an ⌥-click, not a request to move on.
        let sinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        let sinceClick = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        if optionSpoiled || held > 0.8 || sinceKey <= held + 0.03 || sinceClick <= held + 0.03 { return }
        step(1)
    }

    func hotKey(_ id: UInt32) {
        optionSpoiled = true
        switch id {
        case 1: step(1)
        case 2: step(-1)
        case 3: stepSection(1)
        case 4: stepSection(-1)
        case 5: NSApp.terminate(nil)
        case 6: setCapture(!capturable)
        default: break
        }
    }

    // The key that types a letter on the keyboard in use, read once at launch.
    // A hot key is registered by the place of its key, and Q is not in the
    // same place on an AZERTY keyboard as on a QWERTY one.
    func keyCode(typing letter: String, else fallback: Int) -> Int {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            return (0..<128).first { code in
                var deadKeys: UInt32 = 0
                var length = 0
                var typed = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, typed.count, &length, &typed)
                return String(utf16CodeUnits: typed, count: length) == letter
            } ?? fallback
        }
    }

    // Global shortcuts (Carbon): they arrive here whichever app is in front,
    // without asking for the Accessibility permission.
    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let n = id.id
            DispatchQueue.main.async { (NSApp.delegate as? App)?.hotKey(n) }
            return noErr
        }, 1, &spec, nil, nil)
        let keys: [(id: UInt32, name: String, code: Int)] = [
            (1, "⌥→", kVK_RightArrow), (2, "⌥←", kVK_LeftArrow), (3, "⌥↓", kVK_DownArrow), (4, "⌥↑", kVK_UpArrow),
            (5, "⌥Q", keyCode(typing: "q", else: kVK_ANSI_Q)), (6, "⌥V", keyCode(typing: "v", else: kVK_ANSI_V))]
        var refused: [String] = []
        for key in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key.code), UInt32(optionKey),
                                             EventHotKeyID(signature: OSType(0x50524D54), id: key.id),  // "PRMT"
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr { refused.append(key.name) }
        }
        // Another app holding one of these is otherwise a key that silently
        // does nothing here.
        if !refused.isEmpty {
            let list = refused.joined(separator: " ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.flash("\(list) already used by another app: use the menu bar icon instead", alert: true)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
