// Prompteur: a teleprompter band that floats above every window, a
// full-screen browser included, and never takes the keyboard from it.
// It reads a script (Markdown or JSON) and shows one sentence at a time.
import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

struct Line: Decodable {
    var say: String
    var show: String = ""
    var highlight: Bool = false

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
    var title: String
    var subtitle: String = ""
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

struct ScriptError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum Script {
    static func load(_ url: URL) throws -> [Section] {
        let data = try Data(contentsOf: url)
        let sections: [Section]
        if url.pathExtension.lowercased() == "json" {
            sections = try JSONDecoder().decode([Section].self, from: data)
        } else {
            sections = markdown(String(decoding: data, as: UTF8.self))
        }
        let kept = sections.filter { !$0.lines.isEmpty }
        if kept.isEmpty { throw ScriptError("no sentence found in \(url.lastPathComponent)") }
        return kept
    }

    // A heading opens a section ("Title · subtitle"), and every row of a
    // table under it is a sentence: what to say, then what to show. Anything
    // else in the file is left alone, so a script can carry its own notes.
    static func markdown(_ text: String) -> [Section] {
        var sections: [Section] = []
        let rows = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (i, row) in rows.enumerated() {
            if row.hasPrefix("#") {
                let heading = String(row.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
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

    static func cells(_ row: String) -> [String] {
        var inner = Substring(row)
        if inner.hasPrefix("|") { inner = inner.dropFirst() }
        if inner.hasSuffix("|") { inner = inner.dropLast() }
        return inner.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
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

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var sections: [Section] = []
    var s = 0
    var l = 0
    var source: URL?
    var problem: String?
    var panel: Panel!
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var hotKeys: [EventHotKeyRef?] = []
    let meta = NSTextField(labelWithString: "")
    let say = NSTextField(wrappingLabelWithString: "")
    let show = NSTextField(labelWithString: "")
    let args = CommandLine.arguments
    let defaults = UserDefaults.standard

    var capturable = false
    var notice: String?
    var noticeAlert = false
    var noticeTimer: Timer?
    var lastToggle = Date.distantPast

    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hidden from screenshots and recordings unless asked: the band is
        // there for the person reading it, not for the people watching.
        capturable = args.contains("--visible") || defaults.bool(forKey: "visibleInCaptures")
        build()
        buildStatusItem()
        registerHotKeys()
        watchOption()

        load(initialScript())
        watchScripts()
        if let n = arg("--section").flatMap(Int.init), !sections.isEmpty {
            s = min(max(n - 1, 0), sections.count - 1)
        } else if defaults.integer(forKey: "section") < sections.count {
            s = defaults.integer(forKey: "section")
        }
        if let n = arg("--line").flatMap(Int.init), !sections.isEmpty {
            l = min(max(n - 1, 0), sections[s].lines.count - 1)
        }
        render()

        // --snapshot file.png: the band draws itself into an image and quits.
        // It checks the layout without needing a screen capture.
        if let path = arg("--snapshot"), let view = panel.contentView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                print("level \(self.panel.level.rawValue) frame \(self.panel.frame) sharing \(self.panel.sharingType.rawValue)")
                NSApp.terminate(nil)
            }
        }
    }

    // --- Scripts ---

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

    func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // What the user chose last wins: a file opened from the menu, or the
    // built-in script ("builtin"). Then the inbox, then the built-in one.
    func initialScript() -> URL? {
        if let path = arg("--script") { return URL(fileURLWithPath: path) }
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
            problem = "No script loaded. Open one from the menu bar icon, or write ~/Prompteur/script.md."
            return
        }
        do {
            sections = try Script.load(url)
            problem = nil
        } catch {
            sections = []
            problem = "Could not read the script: \(error.localizedDescription)"
        }
        s = min(s, max(sections.count - 1, 0))
        l = sections.isEmpty ? 0 : min(l, sections[s].lines.count - 1)
    }

    // Reads the script again after an edit. The place is kept by section
    // title, so a section added above the current one does not move it; and
    // a file caught half written keeps the old script on screen rather than
    // an error, since the next save will be read in turn.
    func refresh(_ url: URL, keepPlace: Bool, announce: String) {
        sourceSeen = modified(url)
        do {
            let fresh = try Script.load(url)
            let title = sections.indices.contains(s) ? sections[s].title : nil
            sections = fresh
            source = url
            problem = nil
            if keepPlace {
                if let title, let i = fresh.firstIndex(where: { $0.title == title }) { s = i }
                s = min(s, fresh.count - 1)
                l = min(l, fresh[s].lines.count - 1)
            } else {
                s = 0
                l = 0
            }
            flash(announce)
        } catch {
            if sections.isEmpty {
                source = url
                problem = "Could not read the script: \(error.localizedDescription)"
                render()
            } else {
                flash("Could not read \(url.lastPathComponent): \(error.localizedDescription)", alert: true)
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
        if let source, let date = modified(source), date != sourceSeen {
            refresh(source, keepPlace: true, announce: "Script updated")
        }
    }

    @objc func openScript() {
        NSApp.activate(ignoringOtherApps: true)
        let dialog = NSOpenPanel()
        dialog.message = "Choose a script (Markdown or JSON)"
        dialog.allowedContentTypes = [.json, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        guard dialog.runModal() == .OK, let url = dialog.url else { return }
        defaults.set(url.path, forKey: "scriptPath")
        s = 0
        l = 0
        load(url)
        render()
    }

    @objc func reloadScript() {
        guard let source else { return }
        refresh(source, keepPlace: true, announce: "Script reloaded")
    }

    @objc func useBundledScript() {
        defaults.set("builtin", forKey: "scriptPath")
        s = 0
        l = 0
        load(bundledScript())
        render()
    }

    @objc func revealScript() {
        guard let source else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }

    // --- The band ---

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
        panel.isMovableByWindowBackground = false
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
        say.maximumNumberOfLines = 2
        say.lineBreakMode = .byWordWrapping
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
            show.stringValue = "Menu bar icon → Open Script…"
        } else {
            let section = sections[s]
            let line = section.lines[l]
            let title = section.title.isEmpty ? "\(s + 1)." : "\(s + 1). \(section.title)"
            let head = [title, section.subtitle, "\(l + 1)/\(section.lines.count)"].filter { !$0.isEmpty }
            meta.stringValue = head.joined(separator: " · ") + "   ⌥ next  ⌥← back  ⌥↓ ⌥↑ section  ⌥Q quit"
            text = line.say
            if line.highlight { color = NSColor(red: 1, green: 0.84, blue: 0.04, alpha: 1) }
            show.stringValue = line.show
            defaults.set(s, forKey: "section")
            if args.contains("--log") { print("\(s + 1)|\(l + 1)|\(line.say)"); fflush(stdout) }
        }
        meta.textColor = NSColor(white: 0.55, alpha: 1)
        if let notice {
            meta.stringValue = notice
            meta.textColor = noticeAlert ? NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1) : NSColor(white: 0.85, alpha: 1)
        }
        say.stringValue = text
        say.textColor = color
        // Two lines at most: a long sentence shrinks rather than being cut.
        var size: CGFloat = 27
        while size > 17 {
            say.font = .systemFont(ofSize: size, weight: .semibold)
            let needed = say.sizeThatFits(NSSize(width: say.frame.width, height: 1000)).height
            let lineHeight = say.font!.ascender - say.font!.descender + say.font!.leading
            if needed <= lineHeight * 2 + 4 { break }
            size -= 1
        }
        let fit = say.sizeThatFits(NSSize(width: say.frame.width, height: 1000)).height
        say.frame = NSRect(x: say.frame.minX, y: 28 + max(0, (66 - fit) / 2), width: say.frame.width, height: min(fit, 66))
    }

    func step(_ d: Int) {
        guard !sections.isEmpty else { return }
        let n = sections[s].lines.count
        if l + d >= n {
            // Past the last sentence, moving on opens the next section.
            if s < sections.count - 1 { s += 1; l = 0 }
        } else {
            l = max(0, l + d)
        }
        render()
    }

    func section(_ d: Int) {
        guard !sections.isEmpty else { return }
        s = min(sections.count - 1, max(0, s + d))
        l = 0
        render()
    }

    @objc func goToSection(_ item: NSMenuItem) {
        guard item.tag < sections.count else { return }
        s = item.tag
        l = 0
        render()
    }

    @objc func resetPosition() {
        panel.setFrame(homeRect(), display: true)
        defaults.removeObject(forKey: "bandOrigin")
    }

    // --- Visible in screenshots and recordings ---

    func applyCapture() {
        // .none keeps the band out of screenshots and screen recordings,
        // wherever the capture tool honours it; .readOnly lets it be captured
        // like any other window, for a demo of the tool itself.
        panel.sharingType = capturable ? .readOnly : .none
        let symbol = capturable ? "text.bubble.fill" : "text.bubble"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prompteur")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc func toggleCapture() {
        // The menu's own ⌥V and the global hot key can both fire for one press.
        if Date().timeIntervalSince(lastToggle) < 0.3 { return }
        lastToggle = Date()
        capturable.toggle()
        defaults.set(capturable, forKey: "visibleInCaptures")
        applyCapture()
        flash(capturable ? "● Visible in screenshots and recordings" : "Hidden from screenshots and recordings", alert: capturable)
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

    // --- Menu bar ---

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        applyCapture()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
            return item
        }

        if !sections.isEmpty {
            let go = add("Go to Section", nil)
            let sub = NSMenu()
            for (i, section) in sections.enumerated() {
                let name = section.title.isEmpty ? "Section \(i + 1)" : section.title
                let item = NSMenuItem(title: "\(i + 1). \(name)", action: #selector(goToSection(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                item.state = i == s ? .on : .off
                sub.addItem(item)
            }
            go.submenu = sub
            menu.addItem(.separator())
        }

        add("Move Band Back Under the Camera", #selector(resetPosition))
        let visible = add("Visible in Screenshots and Recordings", #selector(toggleCapture), key: "v", mods: .option)
        visible.state = capturable ? .on : .off
        menu.addItem(.separator())

        add("Open Script…", #selector(openScript), key: "o", mods: .command)
        let reload = add("Reload Script", #selector(reloadScript), key: "r", mods: .command)
        reload.isEnabled = source != nil
        let bundled = bundledScript()
        if let bundled, source != bundled {
            add("Use Built-in Script", #selector(useBundledScript))
        }
        if let source {
            // The file on screen, shown where it can be found again.
            let name = source == bundled ? "built-in"
                : (source.path as NSString).abbreviatingWithTildeInPath
            let current = add("Script: \(name)", source == bundled ? nil : #selector(revealScript))
            current.toolTip = "Show in Finder"
        }
        menu.addItem(.separator())
        add("Quit Prompteur", #selector(NSApplication.terminate(_:)), key: "q", mods: .option).target = NSApp
    }

    // --- Keyboard ---

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
        case 3: section(1)
        case 4: section(-1)
        case 5: NSApp.terminate(nil)
        case 6: toggleCapture()
        default: break
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
        let keys: [(UInt32, Int)] = [(1, kVK_RightArrow), (2, kVK_LeftArrow), (3, kVK_DownArrow),
                                     (4, kVK_UpArrow), (5, kVK_ANSI_Q), (6, kVK_ANSI_V)]
        for (id, code) in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), UInt32(optionKey),
                                             EventHotKeyID(signature: OSType(0x50524D54), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status != noErr && args.contains("--log") { print("hotkey \(id) refused: \(status)") }
            hotKeys.append(ref)
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
