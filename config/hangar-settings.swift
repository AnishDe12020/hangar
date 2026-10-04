import AppKit
import QuartzCore
import UniformTypeIdentifiers

let settingsNavigation = Notification.Name("local.hangar.settings.navigate")
let settingsPages: Set<String> = ["general", "sessions", "shortcuts", "utilities", "maintenance"]

// Ground Control is a view over the CLI's validated settings and transactions.
// It does not edit application preferences or execute arbitrary shell strings.
class ActionButton: NSButton {
    var perform: (() -> Void)?
    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.perform = action; bezelStyle = .rounded
        target = self; self.action = #selector(invoke)
        if let symbol = symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = .imageLeading }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func invoke() { perform?() }
}

final class NavigationButton: ActionButton {
    private let caption: NSTextField
    init(_ title: String, symbol: String, tint: NSColor, action: @escaping () -> Void) {
        caption = label(title, size: 13)
        super.init("", action: action)
        setAccessibilityLabel(title)
        let tile = NSView(); tile.wantsLayer = true
        tile.layer?.cornerRadius = 5; tile.layer?.backgroundColor = tint.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .white; icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        for view in [tile, icon, caption] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(tile); tile.addSubview(icon); addSubview(caption)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9), tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 25), tile.heightAnchor.constraint(equalToConstant: 25),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17),
            caption.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 9), caption.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        caption.font = .systemFont(ofSize: 13, weight: state == .on ? .medium : .regular)
        super.draw(dirtyRect)
    }
}
final class SettingsBackground: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}
final class SettingsGroup: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        shape.fill()
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke(); shape.lineWidth = 0.5; shape.stroke()
    }
}
final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let view = NSTextField(wrappingLabelWithString: text)
    view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
}
func stack(_ items: [NSView], vertical: Bool = true, spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: items); view.orientation = vertical ? .vertical : .horizontal
    view.alignment = vertical ? .leading : .centerY; view.spacing = spacing
    return view
}
func separator() -> NSView { let b = NSBox(); b.boxType = .separator; return b }

final class GroundControl: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSearchFieldDelegate {
    let cli: String
    let preview: Bool
    let navigationName: Notification.Name
    var window: NSWindow!
    let sidebar = NSView()
    let sidebarContent = NSView()
    private(set) var sidebarMaterial: NSView?
    private var materialIsOpaque: Bool?
    private var accessibilityObserver: NSObjectProtocol?
    var reduceTransparency: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    var content = NSStackView()
    var status = label("Loading settings…", size: 12, color: .secondaryLabelColor)
    var spinner = NSProgressIndicator()
    var scope = NSPopUpButton()
    var snapshot: [String: Any] = [:]
    var draft: [String: Any] = [:]
    var catalog: [[String: Any]] = []
    var catalogList: NSStackView?
    var utilitySearch: NSSearchField?
    var utilityQuery = ""
    var fields: [String: NSTextField] = [:]
    var profile: NSPopUpButton?
    var profileDescription: NSTextField?
    var shelf: NSButton?
    var shelfStyle: NSPopUpButton?
    var holdStatus: NSTextField?
    var holdStop: NSButton?
    var holdStart: NSButton?
    var holdRevision = 0
    var holdRefresh: DispatchWorkItem?
    var holdRefreshAfterBusy = false
    var sessionState: [String: Any] = [:]
    var sessionRevision = 0
    var sessionRefresh: DispatchWorkItem?
    var sessionRefreshAfterBusy = false
    var focusStatus: NSTextField?
    var focusButtons: [String: NSButton] = [:]
    var reminderList: NSStackView?
    var selected = "general"
    var busy = false
    var pendingNavigation: String?
    var modalDepth = 0
    private var navigationObserver: NSObjectProtocol?
    var buttons: [NSButton] = []
    var configActions: [NSView] = []
    var navigation: [String: NSButton] = [:]
    var requestedTab: String
    var saveScope = 0
    var disabledControls: [ObjectIdentifier: (NSControl, Bool)] = [:]
    var diagnostics: [[String: Any]] = []
    let labels = ["general": "General", "sessions": "Sessions", "shortcuts": "Shortcuts", "utilities": "Quick Install", "maintenance": "Recovery"]

    init(cli: String, tab: String, preview: Bool = false, navigationName: Notification.Name = settingsNavigation) { self.cli = cli; self.requestedTab = tab; self.preview = preview; self.navigationName = navigationName }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        if preview { loadFixture(); return }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        load()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !busy }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let window = window, window.isVisible || busy else { return .terminateNow }
        return windowShouldClose(window) ? .terminateNow : .terminateCancel
    }
    func requestNavigation(_ page: String) {
        guard settingsPages.contains(page) else { return }
        pendingNavigation = page
        if !preview { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        applyPendingNavigation()
    }
    func applyPendingNavigation() {
        guard !busy, !snapshot.isEmpty, modalDepth == 0, window.attachedSheet == nil,
              NSApp.modalWindow == nil, let page = pendingNavigation else { return }
        pendingNavigation = nil
        if selected != page { window.makeFirstResponder(nil); select(page) }
    }
    func scheduleNavigation() {
        DispatchQueue.main.async { [weak self] in self?.applyPendingNavigation() }
    }
    @discardableResult func showAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        modalDepth += 1
        defer { modalDepth -= 1; scheduleNavigation() }
        return alert.runModal()
    }
    func windowDidEndSheet(_ notification: Notification) { scheduleNavigation() }
    func buildMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let application = NSMenu(); applicationItem.submenu = application
        application.addItem(withTitle: "Quit Ground Control", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if busy { status.stringValue = "Let the current operation finish before closing."; return false }
        window.makeFirstResponder(nil)
        collect()
        if !changes().isEmpty {
            let alert = NSAlert(); alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Your active configuration has not changed."
            alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Discard")
            return self.showAlert(alert) == .alertSecondButtonReturn
        }
        return true
    }

    func buildWindow() {
        navigationObserver = DistributedNotificationCenter.default().addObserver(forName: navigationName, object: nil, queue: .main) { [weak self] note in
            guard let page = note.userInfo?["tab"] as? String else { return }
            self?.requestNavigation(page)
        }
        if !preview { buildMenu() }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Hangar Settings"; window.minSize = NSSize(width: 800, height: 580)
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.delegate = self; window.center()
        let root: NSView = preview ? SettingsBackground() : NSView(); window.contentView = root
        sidebar.addSubview(sidebarContent)
        updateSidebarMaterial()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateSidebarMaterial() }
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(sidebar)
        let brand = label("Hangar", size: 16, weight: .semibold)
        brand.translatesAutoresizingMaskIntoConstraints = false; sidebarContent.addSubview(brand)
        let menu = stack([], spacing: 4); menu.translatesAutoresizingMaskIntoConstraints = false; sidebarContent.addSubview(menu)
        for (id, title, symbol, tint) in [("general", "General", "gearshape.fill", NSColor.systemGray), ("sessions", "Sessions", "clock", NSColor.systemTeal), ("shortcuts", "Shortcuts", "command", NSColor.systemPurple), ("utilities", "Quick Install", "square.and.arrow.down.fill", NSColor.systemBlue), ("maintenance", "Recovery", "arrow.counterclockwise", NSColor.systemOrange)] {
            let b = NavigationButton(title, symbol: symbol, tint: tint) { [weak self] in self?.select(id) }
            b.alignment = .left; b.isBordered = false; b.setButtonType(.toggle); b.heightAnchor.constraint(equalToConstant: 39).isActive = true
            menu.addArrangedSubview(b); b.widthAnchor.constraint(equalTo: menu.widthAnchor).isActive = true; navigation[id] = b
        }
        let bottom = label("Ground Control", size: 11, color: .tertiaryLabelColor)
        bottom.translatesAutoresizingMaskIntoConstraints = false; sidebarContent.addSubview(bottom)
        let area = SettingsBackground(); area.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(area)
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.translatesAutoresizingMaskIntoConstraints = false; area.addSubview(scroll)
        content = stack([], spacing: 20); content.translatesAutoresizingMaskIntoConstraints = false
        let document = SettingsDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document
        let footer = stack([], spacing: 10); footer.translatesAutoresizingMaskIntoConstraints = false; area.addSubview(footer)
        let rule = separator(); footer.addArrangedSubview(rule); rule.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        let feedback = stack([spinner, status], vertical: false, spacing: 6)
        footer.addArrangedSubview(feedback)
        let actions = stack([], vertical: false, spacing: 7); footer.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        scope.addItems(withTitles: ["This Mac", "Shared dotfiles"])
        scope.controlSize = .small; scope.font = .systemFont(ofSize: 11)
        scope.setAccessibilityLabel("Save settings to")
        scope.toolTip = "Choose where edited settings are saved. Applying affects only this Mac."
        let scopeLabel = label("Save to", size: 11, color: .secondaryLabelColor)
        actions.addArrangedSubview(scopeLabel); actions.addArrangedSubview(scope)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); actions.addArrangedSubview(spacer)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let reload = ActionButton("Reload") { [weak self] in self?.reloadRequested() }
        let review = ActionButton("Review") { [weak self] in _ = self?.reviewChanges() }
        let save = ActionButton("Save") { [weak self] in self?.save(apply: false) }
        let apply = ActionButton("Save & Apply") { [weak self] in self?.save(apply: true) }
        apply.keyEquivalent = "\r"
        buttons = [reload, review, save, apply]; buttons.forEach { $0.controlSize = .small; $0.font = .systemFont(ofSize: 12); actions.addArrangedSubview($0) }
        configActions = [scopeLabel, scope, review, save, apply]
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 190),
            sidebarContent.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor), sidebarContent.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor), sidebarContent.topAnchor.constraint(equalTo: sidebar.topAnchor), sidebarContent.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            brand.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 20), brand.topAnchor.constraint(equalTo: sidebarContent.topAnchor, constant: 60),
            menu.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 10), menu.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -10), menu.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 23),
            bottom.leadingAnchor.constraint(equalTo: brand.leadingAnchor), bottom.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor, constant: -22),
            area.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), area.trailingAnchor.constraint(equalTo: root.trailingAnchor), area.topAnchor.constraint(equalTo: root.topAnchor), area.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: area.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: area.trailingAnchor), scroll.topAnchor.constraint(equalTo: area.topAnchor, constant: 30), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 25), content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            footer.leadingAnchor.constraint(equalTo: area.leadingAnchor, constant: 28), footer.trailingAnchor.constraint(equalTo: area.trailingAnchor, constant: -28), footer.bottomAnchor.constraint(equalTo: area.bottomAnchor, constant: -18)
        ])
    }

    deinit {
        if let observer = navigationObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        if let observer = accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func updateSidebarMaterial() {
        let opaque = preview || reduceTransparency()
        guard materialIsOpaque != opaque else { return }
        materialIsOpaque = opaque
        window.isOpaque = opaque
        window.backgroundColor = opaque ? .windowBackgroundColor : .clear
        let material: NSView
        if opaque {
            material = SettingsBackground()
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 0
                glass.contentView = NSView(); material = glass
            } else {
                let effect = NSVisualEffectView(); effect.material = .sidebar
                effect.blendingMode = .behindWindow; effect.state = .followsWindowActiveState; material = effect
            }
            #else
            let effect = NSVisualEffectView(); effect.material = .sidebar
            effect.blendingMode = .behindWindow; effect.state = .followsWindowActiveState; material = effect
            #endif
        }
        // Keep controls in their original hierarchy so editing and keyboard focus survive.
        sidebarMaterial?.removeFromSuperview()
        material.frame = sidebar.bounds; material.autoresizingMask = [.width, .height]
        sidebar.addSubview(material, positioned: .below, relativeTo: sidebarContent)
        sidebarMaterial = material
    }

    func setBusy(_ value: Bool, _ text: String) {
        busy = value; status.stringValue = text
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // Retain each control's eligibility: an unavailable utility stays unavailable.
        func capture(_ view: NSView) {
            if let control = view as? NSControl {
                let id = ObjectIdentifier(control)
                if disabledControls[id] == nil { disabledControls[id] = (control, control.isEnabled) }
                control.isEnabled = false
            }
            view.subviews.forEach(capture)
        }
        if value { if let root = window?.contentView { capture(root) } }
        else {
            scheduleNavigation()
            disabledControls.values.forEach { $0.0.isEnabled = $0.1 }; disabledControls.removeAll()
            let refreshHold = holdRefreshAfterBusy, refreshSessions = sessionRefreshAfterBusy
            holdRefreshAfterBusy = false; sessionRefreshAfterBusy = false
            if selected == "sessions", refreshHold || refreshSessions {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.selected == "sessions" else { return }
                    if self.busy {
                        self.holdRefreshAfterBusy = self.holdRefreshAfterBusy || refreshHold
                        self.sessionRefreshAfterBusy = self.sessionRefreshAfterBusy || refreshSessions
                        return
                    }
                    if refreshHold { self.refreshHold() }; if refreshSessions { self.refreshSessions() }
                }
            }
        }
    }

    func run(_ args: [String], completion: @escaping (Int32, String, String) -> Void) {
        if preview { completion(1, "", "Preview does not execute commands"); return }
        let executable = cli
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = args
            let out = Pipe(), err = Pipe(); task.standardOutput = out; task.standardError = err; task.standardInput = FileHandle.nullDevice
            do { try task.run() } catch { DispatchQueue.main.async { completion(127, "", error.localizedDescription) }; return }
            let group = DispatchGroup(), lock = NSLock(); var stdout = Data(), stderr = Data()
            group.enter(); DispatchQueue.global().async { let data = out.fileHandleForReading.readDataToEndOfFile(); lock.lock(); stdout = data; lock.unlock(); group.leave() }
            group.enter(); DispatchQueue.global().async { let data = err.fileHandleForReading.readDataToEndOfFile(); lock.lock(); stderr = data; lock.unlock(); group.leave() }
            task.waitUntilExit(); group.wait()
            let code = task.terminationStatus, output = String(decoding: stdout, as: UTF8.self), error = String(decoding: stderr, as: UTF8.self)
            DispatchQueue.main.async { completion(code, output, error) }
        }
    }
    func object(_ text: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] }
    func fail(_ text: String) {
        setBusy(false, "Operation did not complete. Review the details below.")
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Hangar needs your attention"
        let detail = object(text)?["message"] as? String ?? object(text)?["error"] as? String ?? text
        alert.informativeText = detail.isEmpty ? "Hangar returned no details. Run diagnostics in Recovery, then try again." : String(detail.suffix(2400)); alert.addButton(withTitle: "OK"); self.showAlert(alert)
    }
    func load() {
        setBusy(true, "Reading your configuration…")
        run(["config", "schema", "--json"]) { code, out, err in
            guard code == 0, let data = self.object(out), let config = data["config"] as? [String: Any] else { self.fail(err.isEmpty ? out : err); return }
            self.snapshot = data; self.draft = config; self.setBusy(false, "Changes are checked before they are saved.")
            self.select(self.requestedTab, collect: false); self.requestedTab = self.selected
        }
    }
    func reloadRequested() {
        window.makeFirstResponder(nil)
        collect()
        if !changes().isEmpty {
            let a = NSAlert(); a.messageText = "Reload and discard unsaved changes?"; a.addButton(withTitle: "Keep editing"); a.addButton(withTitle: "Reload")
            if self.showAlert(a) != .alertSecondButtonReturn { return }
        }
        catalog = []; requestedTab = selected; load()
    }
    func add(_ view: NSView, full: Bool = true) { content.addArrangedSubview(view); if full { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true } }
    func heading(_ title: String, _ detail: String) {
        add(stack([label(title, size: 20, weight: .semibold), label(detail, size: 12, color: .secondaryLabelColor)], spacing: 7))
    }
    func group(_ title: String? = nil, rows: [NSView], detail: String? = nil, container: NSStackView? = nil) {
        let outer = stack([], spacing: 8)
        if let title = title { outer.addArrangedSubview(label(title, size: 12, weight: .semibold, color: .secondaryLabelColor)) }
        let body = SettingsGroup(); let items = stack([], spacing: 0)
        items.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(items)
        for (index, view) in rows.enumerated() {
            if index > 0 { let line = separator(); items.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: items.widthAnchor).isActive = true }
            items.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: items.widthAnchor).isActive = true
        }
        outer.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        NSLayoutConstraint.activate([items.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14), items.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14), items.topAnchor.constraint(equalTo: body.topAnchor, constant: 3), items.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -3)])
        if let detail = detail { let note = label(detail, size: 11, color: .secondaryLabelColor); outer.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true }
        if let container = container {
            container.addArrangedSubview(outer); outer.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        } else { add(outer) }
    }
    func row(_ title: String, _ control: NSView, detail: String? = nil) -> NSView {
        let caption = label(title)
        let left = stack(detail.map { [caption, label($0, size: 11, color: .secondaryLabelColor)] } ?? [caption], spacing: 3)
        control.setAccessibilityLabel(title)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let items = stack([left, spacer, control], vertical: false, spacing: 12)
        let row = NSView(); items.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(items)
        NSLayoutConstraint.activate([items.leadingAnchor.constraint(equalTo: row.leadingAnchor), items.trailingAnchor.constraint(equalTo: row.trailingAnchor), items.topAnchor.constraint(equalTo: row.topAnchor, constant: 11), items.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11), row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        return row
    }
    func field(_ group: String, _ key: String, _ title: String) -> NSView {
        let values = draft[group] as? [String: String] ?? [:]
        let entry = NSTextField(string: values[key] ?? "")
        entry.font = group == "hotkeys" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
        entry.bezelStyle = .roundedBezel; entry.widthAnchor.constraint(equalToConstant: group == "hotkeys" ? 180 : 220).isActive = true
        entry.placeholderString = title; fields[group + "." + key] = entry
        var controls: [NSView] = [entry]
        if group == "hotkeys", let defaults = (snapshot["defaults"] as? [String: Any])?["hotkeys"] as? [String: String], let value = defaults[key] {
            let reset = ActionButton("Reset") { entry.stringValue = value }
            reset.controlSize = .small; reset.toolTip = "Use the default: \(value)"
            reset.setAccessibilityLabel("Reset \(title) shortcut to default"); controls.append(reset)
        } else if group == "apps" {
            let choose = ActionButton("Choose…") { [weak self] in
                guard let self = self else { return }
                let panel = NSOpenPanel(); panel.title = "Choose \(title)"
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                panel.allowedContentTypes = [.applicationBundle]; panel.treatsFilePackagesAsDirectories = false
                panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                panel.beginSheetModal(for: self.window) { reply in
                    guard reply == .OK, let url = panel.url, url.pathExtension == "app", Bundle(url: url)?.executableURL != nil else { return }
                    entry.stringValue = url.deletingPathExtension().lastPathComponent
                }
            }
            choose.controlSize = .small; choose.setAccessibilityLabel("Choose \(title) application"); controls.append(choose)
        }
        return row(title, stack(controls, vertical: false, spacing: 6), detail: sourceLabel(group + "." + key))
    }
    func sourceLabel(_ path: String) -> String? {
        guard let source = (snapshot["provenance"] as? [String: String])?[path] else { return nil }
        return ["default":"Hangar default", "legacy":"Existing default", "shared":"Shared dotfiles", "local":"This Mac overrides shared settings"][source] ?? source
    }
    func select(_ page: String, collect shouldCollect: Bool = true) {
        guard !busy || !shouldCollect else { return }
        if shouldCollect { collect() }
        selected = labels[page] == nil ? "general" : page
        configActions.forEach { $0.isHidden = selected != "general" && selected != "shortcuts" }
        navigation.forEach { key, button in
            button.state = key == selected ? .on : .off
            button.contentTintColor = .labelColor
            button.needsDisplay = true
        }
        content.arrangedSubviews.forEach { content.removeArrangedSubview($0); $0.removeFromSuperview() }
        content.enclosingScrollView?.contentView.scroll(to: .zero)
        fields = [:]; profile = nil; profileDescription = nil; shelf = nil; shelfStyle = nil
        holdStatus = nil; holdStart = nil; holdStop = nil
        holdRefresh?.cancel(); holdRefresh = nil
        sessionRefresh?.cancel(); sessionRefresh = nil; focusStatus = nil; focusButtons = [:]; reminderList = nil
        catalogList = nil; utilitySearch = nil
        guard !snapshot.isEmpty else { return }
        switch selected {
        case "shortcuts":
            heading("Shortcuts", "Make Hangar’s commands fit your keyboard.")
            let names = ["overview":"Tower", "picker_search":"Departures search", "shelf":"Apron", "settings":"Ground Control", "palette":"Command palette"]
            let keys = (draft["hotkeys"] as? [String: String] ?? [:]).keys.sorted()
            let utilityKeys = ["overview", "picker_search", "shelf", "settings", "palette"].filter { keys.contains($0) }
            group("Hangar", rows: utilityKeys.map { field("hotkeys", $0, names[$0] ?? $0) }, detail: "Option+Tab switches windows. Its binding is reserved.")
            let otherKeys = keys.filter { !utilityKeys.contains($0) }
            if !otherKeys.isEmpty { group("Workspace & apps", rows: otherKeys.map { field("hotkeys", $0, $0.replacingOccurrences(of: "_", with: " ").capitalized) }) }
            add(label("Enter a chord such as ctrl-alt-cmd-w. Hangar checks for shortcut conflicts before saving.", size: 11, color: .secondaryLabelColor))
        case "utilities": buildUtilities()
        case "sessions": buildSessions()
        case "maintenance": buildMaintenance()
        default:
            heading("General", "Your workspace, default apps and built-in utilities.")
            let p = NSPopUpButton(); p.addItems(withTitles: snapshot["profiles"] as? [String] ?? ["default"]); p.selectItem(withTitle: draft["profile"] as? String ?? "default"); profile = p
            p.widthAnchor.constraint(equalToConstant: 220).isActive = true
            p.target = self; p.action = #selector(profileChanged)
            let description = label("", size: 11, color: .secondaryLabelColor); profileDescription = description
            group("Workspace", rows: [row("Profile", p, detail: sourceLabel("profile"))])
            add(description); profileChanged()
            group("Default apps", rows: [field("apps", "terminal", "Terminal"), field("apps", "browser", "Browser"), field("apps", "finder", "File browser")])
            let b = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
            b.state = (draft["modules"] as? [String: Bool] ?? [:])["shelf"] == false ? .off : .on; shelf = b
            let open = ActionButton("Open Apron") { [weak self] in self?.run(["shelf"]) { c, o, e in if c != 0 { self?.fail(e.isEmpty ? o : e) } } }
            open.controlSize = .small
            let actions = stack([b, open], vertical: false, spacing: 14)
            let style = NSPopUpButton(); style.addItems(withTitles: ["Compact", "Glass"])
            style.selectItem(at: draft["shelf_style"] as? String == "glass" ? 1 : 0)
            style.widthAnchor.constraint(equalToConstant: 220).isActive = true; shelfStyle = style
            group("Utilities", rows: [row("Apron", actions, detail: sourceLabel("modules.shelf")), row("Apron style", style, detail: sourceLabel("shelf_style"))], detail: "Shake while dragging to open the shelf. Removing an item leaves its original file in place.")
        }
    }
    @objc func profileChanged() {
        let name = profile?.titleOfSelectedItem ?? "default"
        let details = snapshot["profile_details"] as? [String: [String: String]] ?? [:]
        var text = details[name]?["description"] ?? "Uses the selected AeroSpace workspace template."
        if snapshot["override"] as? Bool == true {
            text += " " + (snapshot["override_description"] as? String ?? "Your aerospace.toml controls routing and layout; selecting a template keeps that override intact.")
        }
        profileDescription?.stringValue = text
    }
    func buildSessions() {
        heading("Sessions", "Small tools for the task in front of you.")
        buildFocus()
        buildReminders()
        let duration = NSPopUpButton()
        duration.addItems(withTitles: ["15 minutes", "30 minutes", "1 hour", "2 hours"])
        duration.selectItem(at: 1); duration.widthAnchor.constraint(equalToConstant: 160).isActive = true
        duration.setAccessibilityLabel("Keep awake duration")
        let display = NSButton(checkboxWithTitle: "Keep display awake too", target: nil, action: nil)
        display.controlSize = .small
        let start = ActionButton("Start", symbol: "play.fill") { [weak self] in
            let minutes = [15, 30, 60, 120][max(0, duration.indexOfSelectedItem)]
            self?.changeHold(["start", "--minutes", String(minutes)] + (display.state == .on ? ["--display"] : []))
        }
        let stop = ActionButton("Stop") { [weak self] in self?.changeHold(["stop"]) }
        start.controlSize = .small; stop.controlSize = .small; stop.isEnabled = false
        holdStart = start; holdStop = stop
        let state = label("Reading session…", size: 12, color: .secondaryLabelColor); holdStatus = state
        group("Holding Pattern", rows: [row("Duration", duration), row("Display", display), row("Keep awake", stack([start, stop], vertical: false, spacing: 8)), row("Status", state)], detail: "Keeps this Mac awake for a limited time. Your normal power settings stay in place. Sessions end when Hammerspoon quits or reloads; closing Settings leaves them running.")
        refreshHold()
        refreshSessions()
    }
    func buildFocus() {
        let focusLength = NSPopUpButton(); focusLength.addItems(withTitles: ["15 min", "25 min", "45 min", "60 min"]); focusLength.selectItem(at: 1)
        focusLength.setAccessibilityLabel("Focus duration")
        let breakLength = NSPopUpButton(); breakLength.addItems(withTitles: ["5 min", "10 min", "15 min"])
        breakLength.setAccessibilityLabel("Break duration")
        let lengths = stack([label("Focus", size: 12), focusLength, label("Break", size: 12), breakLength], vertical: false, spacing: 8)
        let state = label("Reading timer…", size: 12, color: .secondaryLabelColor); focusStatus = state
        let start = ActionButton("Start", symbol: "play.fill") { [weak self] in
            self?.changeSession(["focus", "start", "--minutes", String([15, 25, 45, 60][max(0, focusLength.indexOfSelectedItem)]), "--break-minutes", String([5, 10, 15][max(0, breakLength.indexOfSelectedItem)])])
        }
        let pause = ActionButton("Pause") { [weak self] in
            guard let self = self else { return }
            let focus = self.sessionState["focus"] as? [String: Any] ?? [:]
            self.changeSession(["focus", focus["state"] as? String == "paused" ? "resume" : "pause"])
        }
        let next = ActionButton("Start break") { [weak self] in self?.changeSession(["focus", "next"]) }
        let cancel = ActionButton("End session") { [weak self] in self?.changeSession(["focus", "cancel"]) }
        focusButtons = ["start": start, "pause": pause, "next": next, "cancel": cancel]
        focusButtons.values.forEach { $0.controlSize = .small; $0.isEnabled = false }
        group("Turnaround · Focus timer", rows: [row("Lengths", lengths), row("Timer", state), row("Session", stack([start, pause, next, cancel], vertical: false, spacing: 7))], detail: "A 15-minute long break follows four focus rounds. Start each next phase when you’re ready. Timers and reminders survive reloads; notifications follow your macOS settings.")
    }
    func buildReminders() {
        let text = NSTextField(string: ""); text.placeholderString = "What should I remind you about?"
        text.widthAnchor.constraint(equalToConstant: 290).isActive = true; text.setAccessibilityLabel("Reminder text")
        let delay = NSPopUpButton(); delay.addItems(withTitles: ["5 minutes", "15 minutes", "30 minutes", "1 hour", "2 hours"]); delay.selectItem(at: 1)
        delay.setAccessibilityLabel("Reminder delay")
        let addReminder = ActionButton("Add reminder", symbol: "plus") { [weak self] in
            let value = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { self?.window.makeFirstResponder(text); return }
            self?.changeSession(["remind", "add", value, "--minutes", String([5, 15, 30, 60, 120][max(0, delay.indexOfSelectedItem)])]) { text.stringValue = "" }
        }
        addReminder.controlSize = .small
        group("Boarding Calls · Reminders", rows: [row("Remind me", text), row("When", stack([delay, addReminder], vertical: false, spacing: 8))], detail: "Private to this Mac. If it sleeps past a reminder, Hangar delivers it after waking.")
        let pending = stack([], spacing: 8); reminderList = pending; add(pending)
    }
    func updateSessions(_ state: [String: Any]) {
        sessionState = state; sessionRefresh?.cancel(); sessionRefresh = nil
        let focus = state["focus"] as? [String: Any] ?? [:], phase = focus["phase"] as? String ?? "focus"
        let mode = focus["state"] as? String ?? "idle"
        let name = phase == "focus" ? "Focus" : phase == "long_break" ? "Long break" : "Break"
        let next = focus["nextPhase"] as? String ?? "focus"
        let nextName = next == "focus" ? "focus" : next == "long_break" ? "long break" : "break"
        let formatter = DateFormatter(); formatter.timeStyle = .short
        if let error = state["lastError"] as? String, !error.isEmpty { focusStatus?.stringValue = error }
        else if mode == "running", let end = focus["endsAt"] as? Double { focusStatus?.stringValue = "\(name) until \(formatter.string(from: Date(timeIntervalSince1970: end)))" }
        else if mode == "paused" { focusStatus?.stringValue = "\(name) paused · \(max(1, Int(ceil((focus["remainingSeconds"] as? Double ?? 0) / 60)))) min left" }
        else if mode == "awaiting_next" { focusStatus?.stringValue = "\(name) complete · ready for \(nextName)" }
        else { focusStatus?.stringValue = "Ready when you are" }
        focusButtons["start"]?.isEnabled = mode == "idle" && !busy
        focusButtons["pause"]?.isEnabled = (mode == "running" || mode == "paused") && !busy
        focusButtons["pause"]?.title = mode == "paused" ? "Resume" : "Pause"
        focusButtons["next"]?.isHidden = mode != "awaiting_next"
        focusButtons["next"]?.isEnabled = mode == "awaiting_next" && !busy
        focusButtons["next"]?.title = "Start \(nextName)"
        focusButtons["cancel"]?.isEnabled = mode != "idle" && !busy
        let reminders = state["reminders"] as? [[String: Any]] ?? []
        if let list = reminderList {
            list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
            if reminders.isEmpty { list.addArrangedSubview(label("No pending reminders", size: 11, color: .tertiaryLabelColor)) }
            for reminder in reminders {
                guard let id = reminder["id"] as? Int, let text = reminder["text"] as? String, let end = reminder["endsAt"] as? Double else { continue }
                let cancel = ActionButton("Cancel") { [weak self] in self?.changeSession(["remind", "cancel", String(id)]) }; cancel.controlSize = .small
                let line = row(text, cancel, detail: formatter.string(from: Date(timeIntervalSince1970: end)))
                list.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }
        var deadlines = reminders.compactMap { $0["endsAt"] as? Double }
        if mode == "running", let end = focus["endsAt"] as? Double { deadlines.append(end) }
        if !preview, (state["lastError"] as? String ?? "").isEmpty, let deadline = deadlines.min(), deadline > Date().timeIntervalSince1970 {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.selected == "sessions" else { return }
                if self.busy { self.sessionRefreshAfterBusy = true; return }; self.refreshSessions()
            }
            sessionRefresh = work; DispatchQueue.main.asyncAfter(deadline: .now() + max(1, deadline - Date().timeIntervalSince1970 + 0.3), execute: work)
        }
    }
    func refreshSessions() {
        if preview { updateSessions(["focus": ["state": "idle", "phase": "focus"], "reminders": []]); return }
        sessionRevision += 1; let revision = sessionRevision
        run(["focus", "status", "--json"]) { code, out, err in
            guard revision == self.sessionRevision else { return }
            if code == 0, let value = self.object(out) { self.updateSessions(value) }
            else { self.focusStatus?.stringValue = "Session unavailable. Reload Hangar and try again." }
        }
    }
    func changeSession(_ arguments: [String], completion: (() -> Void)? = nil) {
        sessionRevision += 1; setBusy(true, "Updating session…")
        run(arguments + ["--json"]) { code, out, err in
            self.setBusy(false, "Session updated.")
            if let value = self.object(out), let state = value["status"] as? [String: Any] { self.updateSessions(state) }
            if code != 0 { self.fail(self.object(out)?["error"] as? String ?? (err.isEmpty ? out : err)) }
            else { completion?() }
        }
    }
    func updateHold(_ value: [String: Any]) {
        holdRefresh?.cancel(); holdRefresh = nil
        let active = value["active"] as? Bool == true
        let stopping = value["stopping"] as? Bool == true
        holdStop?.isEnabled = active && !stopping && !busy
        holdStart?.title = active ? "Restart" : "Start"
        if let error = value["lastError"] as? String, !error.isEmpty { holdStatus?.stringValue = error }
        else if stopping { holdStatus?.stringValue = "Stopping…" }
        else if active, let end = value["endsAt"] as? Double {
            let date = Date(timeIntervalSince1970: end)
            let formatter = DateFormatter(); formatter.timeStyle = .short
            holdStatus?.stringValue = "Awake until \(formatter.string(from: date))" + (value["display"] as? Bool == true ? " · display on" : " · display can sleep")
        } else { holdStatus?.stringValue = "Off · normal sleep behavior" }
        if !preview, active, !stopping, (value["lastError"] as? String ?? "").isEmpty,
           let deadline = value["endsAt"] as? Double, deadline > Date().timeIntervalSince1970 {
            let delay = max(0.5, deadline - Date().timeIntervalSince1970 + 0.3)
            let refresh = DispatchWorkItem { [weak self] in
                guard let self = self, self.selected == "sessions" else { return }
                if self.busy { self.holdRefreshAfterBusy = true; return }
                self.refreshHold()
            }
            // One deadline refresh, with no timer while the utility is idle.
            holdRefresh = refresh; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: refresh)
        }
    }
    func refreshHold() {
        if preview { updateHold(["active": false]); return }
        holdRevision += 1; let revision = holdRevision
        run(["hold", "status", "--json"]) { code, out, err in
            guard revision == self.holdRevision else { return }
            if code == 0, let value = self.object(out) { self.updateHold(value) }
            else { self.holdStatus?.stringValue = "Session unavailable. Reload Hangar and try again." }
        }
    }
    func changeHold(_ arguments: [String]) {
        holdRevision += 1
        setBusy(true, "Updating Holding Pattern…")
        run(["hold"] + arguments + ["--json"]) { code, out, err in
            self.setBusy(false, "Session updated.")
            if let value = self.object(out) { self.updateHold(value) }
            if arguments.first == "stop" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self = self, self.selected == "sessions", !self.busy else { return }; self.refreshHold()
            } }
            if code != 0 { self.fail(self.object(out)?["lastError"] as? String ?? (err.isEmpty ? out : err)) }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        scheduleNavigation()
        if selected == "sessions" && !busy { refreshHold(); refreshSessions() }
    }
    func collect() {
        saveScope = max(0, scope.indexOfSelectedItem)
        for (path, entry) in fields { let parts = path.split(separator: ".").map(String.init); var group = draft[parts[0]] as? [String: String] ?? [:]; group[parts[1]] = entry.stringValue; draft[parts[0]] = group }
        if let p = profile { draft["profile"] = p.titleOfSelectedItem }
        if let style = shelfStyle { draft["shelf_style"] = style.indexOfSelectedItem == 1 ? "glass" : "compact" }
        if let b = shelf { var modules = draft["modules"] as? [String: Bool] ?? [:]; modules["shelf"] = b.state == .on; draft["modules"] = modules }
    }
    func changes() -> [String: Any] {
        let original = snapshot["config"] as? [String: Any] ?? [:]; var result: [String: Any] = [:]
        if let value = draft["profile"] as? String, value != original["profile"] as? String { result["profile"] = value }
        if let value = draft["shelf_style"] as? String, value != (original["shelf_style"] as? String ?? "compact") { result["shelf_style"] = value }
        for section in ["apps", "hotkeys", "modules"] {
            let old = original[section] as? [String: Any] ?? [:]; var changed: [String: Any] = [:]
            for (key, value) in draft[section] as? [String: Any] ?? [:] { if !NSDictionary(dictionary: ["v": value]).isEqual(to: ["v": old[key] ?? NSNull()]) { changed[key] = value } }
            if !changed.isEmpty { result[section] = changed }
        }
        return result
    }
    @discardableResult func reviewChanges(confirmApply: Bool = false) -> Bool {
        window.makeFirstResponder(nil); collect()
        let edits = changes(), original = snapshot["config"] as? [String: Any] ?? [:]
        let alert = NSAlert(); alert.messageText = edits.isEmpty ? "No unsaved changes" : "Review your changes"
        alert.informativeText = "Save to \(saveScope == 1 ? "shared dotfiles" : "this Mac’s overrides"). " + (confirmApply ? "Applying rebuilds helpers and reloads Hangar on this Mac." : "These are edits since you opened or last saved this form. Saved settings activate only when applied.")
        var lines: [String] = []
        func display(_ value: Any?) -> String {
            guard let value = value else { return "unset" }
            if let flag = value as? Bool, !(value is String) { return flag ? "enabled" : "disabled" }
            return String(describing: value)
        }
        for key in edits.keys.sorted() {
            if let values = edits[key] as? [String: Any] {
                let old = original[key] as? [String: Any] ?? [:]
                for name in values.keys.sorted() { lines.append("\(key).\(name)\n  \(display(old[name])) → \(display(values[name]))") }
            } else { lines.append("\(key)\n  \(display(original[key])) → \(display(edits[key]))") }
        }
        if !lines.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: min(280, CGFloat(lines.count * 48 + 20))))
            scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular); text.string = lines.joined(separator: "\n\n")
            text.textContainerInset = NSSize(width: 8, height: 8); text.isVerticallyResizable = true
            text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; alert.accessoryView = scroll
        }
        if confirmApply { alert.addButton(withTitle: "Keep editing"); alert.addButton(withTitle: "Save & Apply") }
        else { alert.addButton(withTitle: "Done") }
        return self.showAlert(alert) == .alertSecondButtonReturn
    }
    func save(apply: Bool) {
        guard !busy, !snapshot.isEmpty else { return }
        window.makeFirstResponder(nil)
        collect(); let edits = changes()
        if edits.isEmpty { if apply { activate() } else { status.stringValue = "Nothing to save." }; return }
        if apply && !reviewChanges(confirmApply: true) { return }
        let payload: [String: Any] = ["revision": snapshot["revision"] ?? "", "changes": edits, "scope": saveScope == 1 ? "shared" : "local"]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hangar-settings-\(UUID().uuidString).json")
        do { let data = try JSONSerialization.data(withJSONObject: payload); guard FileManager.default.createFile(atPath: path.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) } } catch { fail(error.localizedDescription); return }
        setBusy(true, "Validating your changes…")
        run(["config", "save", "--input", path.path, "--json"]) { code, out, err in
            try? FileManager.default.removeItem(at: path)
            guard code == 0, let reply = self.object(out), let data = reply["snapshot"] as? [String: Any], let config = data["config"] as? [String: Any] else { self.fail(err.isEmpty ? out : err); return }
            self.snapshot = data; self.draft = config; self.select(self.selected, collect: false)
            if apply { self.activate() } else { self.setBusy(false, "Saved. Apply when you’re ready.") }
        }
    }
    func activate() {
        setBusy(true, "Building and applying… this can take a minute.")
        run(["config", "apply"]) { code, out, err in
            if code != 0 { self.fail("Desired settings remain saved. Activation did not complete; review the recovery result below.\n\n" + out + err) }
            else { self.setBusy(false, "Applied. Your previous configuration is backed up.") }
        }
    }
    func buildUtilities() {
        heading("Quick Install", "Useful Mac utilities, installed only when you choose.")
        if catalog.isEmpty && !preview {
            add(label("Checking installed apps…", color: .secondaryLabelColor))
            setBusy(true, "Checking available utilities…")
            run(["utilities", "list", "--json"]) { code, out, err in
                self.setBusy(false, "Optional apps are installed only when you choose them.")
                guard code == 0, let entries = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [[String: Any]] else { self.fail(err.isEmpty ? out : err); return }
                self.catalog = entries
                if self.selected == "utilities" { self.select("utilities", collect: false) }
            }
            return
        }
        let search = NSSearchField(); search.placeholderString = "Find an app or tool"; search.stringValue = utilityQuery
        search.delegate = self; search.setAccessibilityLabel("Search optional utilities"); utilitySearch = search; add(search)
        let list = stack([], spacing: 20); catalogList = list; add(list)
        renderUtilities()
        add(label("Keep overlapping window shortcuts unassigned in other utilities.", size: 11, color: .secondaryLabelColor))
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let search = notification.object as? NSSearchField, search === utilitySearch else { return }
        utilityQuery = search.stringValue; renderUtilities()
    }
    func renderUtilities() {
        guard let list = catalogList else { return }
        list.arrangedSubviews.forEach { list.removeArrangedSubview($0); $0.removeFromSuperview() }
        let query = utilityQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = catalog.filter { entry in
            query.isEmpty || ["name", "summary", "category", "notes"].compactMap { entry[$0] as? String }.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
        if entries.isEmpty { list.addArrangedSubview(label("No utilities match. Clear the search to see all options.", size: 12, color: .secondaryLabelColor)) }
        for entry in entries {
            let id = entry["id"] as? String ?? "", name = entry["name"] as? String ?? id
            let installed = entry["installed"] as? Bool ?? false
            let available = entry["available"] as? Bool ?? false
            let symbol = ["tinycast":"command", "shottr":"camera.viewfinder", "thaw":"menubar.rectangle", "localsend":"arrow.up.arrow.down", "iina":"play.rectangle", "stats":"chart.xyaxis.line", "mole":"terminal"][id] ?? "app"
            let icon: NSImageView
            if installed, entry["type"] as? String != "cli", let path = entry["installed_path"] as? String {
                icon = NSImageView(image: NSWorkspace.shared.icon(forFile: path))
            } else {
                icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
                icon.contentTintColor = .secondaryLabelColor; icon.symbolConfiguration = .init(pointSize: 23, weight: .regular)
            }
            icon.widthAnchor.constraint(equalToConstant: 38).isActive = true; icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
            let text = stack([label(name, size: 14, weight: .semibold), label(entry["summary"] as? String ?? "", size: 12, color: .secondaryLabelColor)], spacing: 4)
            let terms = [entry["license"] as? String, entry["pricing"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !terms.isEmpty { text.addArrangedSubview(label(terms, size: 11, color: .tertiaryLabelColor)) }
            let launchLabel = entry["launch_label"] as? String ?? "Open"
            let install = ActionButton(installed ? launchLabel : "Install") {
                if installed {
                    self.setBusy(true, "Opening \(name)…")
                    self.run(["utilities", "open", id, "--json"]) { code, out, err in
                        if code == 0 { self.setBusy(false, "Launch requested.") }
                        else { self.fail(self.object(out)?["message"] as? String ?? (err.isEmpty ? out : err)) }
                    }
                    return
                }
                self.install(entry)
            }
            install.isEnabled = installed ? entry["launch_available"] as? Bool ?? true : available
            let website = ActionButton("About", symbol: "arrow.up.right") { if let s = entry["homepage"] as? String, let u = URL(string: s), u.scheme == "https" { NSWorkspace.shared.open(u) } }
            install.controlSize = .small; website.controlSize = .small
            install.setAccessibilityLabel(installed ? "Open \(name)" : "Install \(name)")
            let actions = stack([install, website], spacing: 6)
            let actionWidth: CGFloat = installed && entry["type"] as? String == "cli" ? 160 : 78
            actions.widthAnchor.constraint(equalToConstant: actionWidth).isActive = true
            let summary = stack([icon, text, actions], vertical: false, spacing: 12)
            text.setContentHuggingPriority(.defaultLow, for: .horizontal)
            text.widthAnchor.constraint(equalTo: summary.widthAnchor, constant: -(62 + actionWidth)).isActive = true
            let rows = stack([summary], spacing: 9)
            summary.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            for key in ["notes", "consent_message", "reason"] {
                if key == "consent_message" && entry["consent_required"] as? Bool != true { continue }
                if let note = entry[key] as? String, !note.isEmpty {
                    let detail = label(note, size: 11, color: .secondaryLabelColor)
                    rows.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                }
            }
            let padded = NSView(); rows.translatesAutoresizingMaskIntoConstraints = false; padded.addSubview(rows)
            NSLayoutConstraint.activate([rows.topAnchor.constraint(equalTo: padded.topAnchor, constant: 11), rows.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -11), rows.leadingAnchor.constraint(equalTo: padded.leadingAnchor), rows.trailingAnchor.constraint(equalTo: padded.trailingAnchor)])
            group(rows: [padded], container: list)
        }
    }
    func install(_ entry: [String: Any]) {
        guard !busy, entry["available"] as? Bool == true, let id = entry["id"] as? String else { return }
        var args = ["utilities", "install", id, "--json"]
        if entry["consent_required"] as? Bool == true {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Install \(entry["name"] as? String ?? id)?"
            alert.informativeText = entry["consent_message"] as? String ?? "This app uses a self-signed build. Its installer removes macOS quarantine. Continue only if you trust its publisher."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Trust & Install")
            if self.showAlert(alert) != .alertSecondButtonReturn { return }; args.append("--allow-unnotarized")
        }
        setBusy(true, "Installing \(entry["name"] as? String ?? id)…")
        run(args) { code, out, err in
            guard code == 0, let result = self.object(out), result["ok"] as? Bool == true else { self.fail(err.isEmpty ? out : err); return }
            self.catalog = []; self.setBusy(false, result["message"] as? String ?? "Installation finished."); self.select("utilities", collect: false)
        }
    }
    func buildMaintenance() {
        heading("Recovery", "Check Hangar or return to a previous installation.")
        let diagnose = ActionButton("Run checks") {
            self.setBusy(true, "Checking Hangar…")
            self.run(["doctor", "--json"]) { _, out, err in
                self.setBusy(false, "Diagnostics finished.")
                guard let report = self.object(out), let checks = report["checks"] as? [[String: Any]] else { self.fail(err.isEmpty ? out : err); return }
                self.diagnostics = checks; self.select("maintenance", collect: false)
            }
        }
        diagnose.controlSize = .small
        group(rows: [row("Diagnostics", diagnose, detail: "Permissions, shortcuts and installed helpers.")])
        let rebuild = ActionButton("Rebuild & Apply…") {
            self.collect()
            guard self.changes().isEmpty else { self.status.stringValue = "Save or discard your draft before rebuilding saved settings."; return }
            let alert = NSAlert(); alert.messageText = "Rebuild Hangar from saved settings?"
            alert.informativeText = "Compiles the installed source kit, rebuilds native helpers and reloads Hangar. The previous installation is backed up."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Rebuild & Apply")
            if self.showAlert(alert) == .alertSecondButtonReturn { self.activate() }
        }
        rebuild.controlSize = .small
        group(rows: [row("Installed helpers", rebuild, detail: "Hangar \(snapshot["version"] as? String ?? "unknown")")], detail: "Run checks to verify signatures and versions. Rebuild repairs missing or outdated helpers using saved configuration.")
        let export = ActionButton("Export…", symbol: "square.and.arrow.up") {
            let panel = NSSavePanel(); panel.nameFieldStringValue = "hangar-diagnostics.json"; panel.allowedContentTypes = [.json]
            panel.beginSheetModal(for: self.window) { reply in
                guard reply == .OK, let destination = panel.url else { return }
                self.setBusy(true, "Preparing portable diagnostics…")
                self.run(["doctor", "--portable"]) { code, out, err in
                    guard code <= 2, let report = self.object(out), report["kind"] as? String == "hangar-diagnostics" else { self.fail(err.isEmpty ? out : err); return }
                    do {
                        try Data(out.utf8).write(to: destination, options: .atomic)
                        self.setBusy(false, "Diagnostics exported. Review the file before sharing.")
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    } catch { self.fail(error.localizedDescription) }
                }
            }
        }
        export.controlSize = .small
        group(rows: [row("Portable report", export, detail: "Version and diagnostic statuses only.")], detail: "Excludes personal paths, machine names, display IDs, window titles, app lists and reminder contents. Nothing is uploaded.")
        if !diagnostics.isEmpty {
            group("Results", rows: diagnostics.map { check in
                let status = check["status"] as? String ?? ""
                let icon = NSImageView(image: NSImage(systemSymbolName: status == "ok" ? "checkmark.circle.fill" : "exclamationmark.circle", accessibilityDescription: status) ?? NSImage())
                icon.contentTintColor = status == "ok" ? .systemGreen : .systemOrange
                return row(check["name"] as? String ?? "", icon, detail: check["message"] as? String ?? "")
            })
        }
        let folder = ActionButton("Open folder", symbol: "folder") {
            if let directory = self.snapshot["directory"] as? String { let url = URL(fileURLWithPath: directory); do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) } catch { self.fail(error.localizedDescription) } }
        }
        folder.controlSize = .small
        group("Configuration", rows: [row("Dotfiles", folder, detail: "Shared settings and per-Mac overrides.")], detail: "Advanced routing lives in aerospace.toml. settings.local.toml overrides shared settings on this Mac.")
        let restore = ActionButton("Restore…") {
            let alert = NSAlert(); alert.messageText = "Restore the previous Hangar installation?"; alert.informativeText = "Hangar saves the current installation first. Desired settings files are retained; restore their separate settings backup if needed. Optional app installations and OS permissions are not rolled back."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Restore")
            guard self.showAlert(alert) == .alertSecondButtonReturn else { return }
            self.setBusy(true, "Restoring the previous installation…")
            self.run(["rollback"]) { code, out, err in if code != 0 { self.fail(out + err) } else { self.setBusy(false, "Restored. Reopen settings to use that version.") } }
        }
        restore.controlSize = .small
        group("Previous installation", rows: [row("Restore Hangar", restore, detail: "Your current installation is backed up first.")], detail: "Personal files, optional apps and macOS permissions are kept. Desired settings have separate backups.")
    }
    func loadFixture() {
        snapshot = ["version":"preview", "revision":"fixture", "profiles":["default","numbered-study"], "config":["profile":"default","shelf_style":"compact","apps":["terminal":"Terminal","browser":"Safari","finder":"Finder"], "hotkeys":["overview":"alt-o","picker_search":"ctrl-alt-cmd-w","shelf":"ctrl-alt-cmd-a","settings":"ctrl-alt-cmd-comma","palette":"ctrl-alt-cmd-slash","terminal":"ctrl-alt-cmd-return","browser":"ctrl-alt-cmd-b","finder":"ctrl-alt-cmd-e","menu_bar":"ctrl-alt-cmd-m","menu_search":"ctrl-alt-cmd-p","reload":"ctrl-alt-cmd-r","management_toggle":"ctrl-alt-cmd-escape","snap_left":"alt-left","snap_right":"alt-right","snap_up":"alt-up","snap_down":"alt-down","pair":"alt-p","separate":"alt-shift-p","layout_menu":"alt-g","gather":"ctrl-alt-cmd-s","mx_picker":"f17"], "modules":["shelf":true]]]
        let fixture = snapshot["config"] as! [String: Any]
        snapshot["defaults"] = ["hotkeys": fixture["hotkeys"] ?? [:]]
        snapshot["provenance"] = ["profile":"local", "apps.terminal":"shared", "apps.browser":"default", "apps.finder":"default", "shelf_style":"shared", "modules.shelf":"default", "hotkeys.overview":"shared", "hotkeys.picker_search":"default"]
        snapshot["profile_details"] = ["default":["description":"Tiled workspaces W (Work), B (Browser), S (Social) and M (Media). Work and Browser prefer the main display; Social and Media prefer a secondary display, falling back to main."]]
        draft = fixture
        catalog = [["id":"tinycast","name":"Tinycast","summary":"Launcher, clipboard, snippets and extensions. Your everyday commands in one native palette.","license":"AGPL-3.0","pricing":"Free and open source","available":true,"consent_required":true,"consent_message":"This self-signed build requires your consent before the installer removes macOS quarantine."], ["id":"shottr","name":"Shottr","summary":"Fast screenshots, annotations and text recognition.","license":"Proprietary","pricing":"Free use with reminders; paid license required for commercial use","installed":true], ["id":"thaw","name":"Thaw","summary":"Keep your menu bar organized and reachable.","license":"GPL-3.0","pricing":"Free and open source","available":false,"reason":"Requires macOS 26 or later."]]
        setBusy(false, "Preview · no settings are read or changed."); select(requestedTab, collect: false)
    }
}

func testSettingsAppearance() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "GroundControlAppearanceTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let controller = GroundControl(cli: "/unavailable-fixture-cli", tab: "shortcuts")
    var reduced = false
    controller.reduceTransparency = { reduced }
    controller.buildWindow(); controller.loadFixture()
    controller.window.contentView?.layoutSubtreeIfNeeded()
    guard let field = controller.fields["hotkeys.overview"], let initialMaterial = controller.sidebarMaterial else {
        throw NSError(domain: "GroundControlAppearanceTest", code: 2)
    }
    field.stringValue = "ctrl-alt-cmd-f12"
    controller.draft["fixtureUnsavedValue"] = "retained"
    try require(controller.window.makeFirstResponder(field), "fixture text control accepts focus")
    let responder = controller.window.firstResponder
    let initialType = type(of: initialMaterial)
    let sidebarChildren = controller.sidebarContent.subviews.map(ObjectIdentifier.init)
    let contentChildren = controller.content.arrangedSubviews.map(ObjectIdentifier.init)
    for opaque in [true, false, true, false] {
        reduced = opaque
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try require(controller.window.isOpaque == opaque, "window opacity follows accessibility notification")
        try require((controller.sidebarMaterial is SettingsBackground) == opaque, "opaque fallback replaces native material")
        if !opaque { try require(type(of: controller.sidebarMaterial!) == initialType, "native material restored") }
        try require(controller.sidebar.subviews.count == 2 && controller.sidebar.subviews.last === controller.sidebarContent, "persistent content stays above one material")
        try require(controller.sidebarContent.subviews.map(ObjectIdentifier.init) == sidebarChildren, "sidebar controls retained")
        try require(controller.content.arrangedSubviews.map(ObjectIdentifier.init) == contentChildren, "content controls retained")
        try require(controller.fields["hotkeys.overview"] === field && field.stringValue == "ctrl-alt-cmd-f12", "uncollected text edit retained")
        try require(controller.draft["fixtureUnsavedValue"] as? String == "retained" && controller.selected == "shortcuts", "draft and navigation retained")
        try require(controller.window.firstResponder === responder, "first responder retained")
        let material = controller.sidebarMaterial
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try require(controller.sidebarMaterial === material, "unchanged setting avoids rebuilding material")
    }
    print("PASS: native accessibility notifications swap opaque/material backgrounds four times, preserving hierarchy, draft, text edits, selection and first responder")
}

func testSettingsNavigation() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: "GroundControlNavigationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let fixtureID = UUID().uuidString
    let controller = GroundControl(cli: "/unavailable-fixture-cli", tab: "shortcuts", preview: true, navigationName: Notification.Name(settingsNavigation.rawValue + ".fixture." + fixtureID))
    controller.buildWindow(); controller.loadFixture()
    controller.fields["hotkeys.overview"]?.stringValue = "ctrl-alt-cmd-f12"
    controller.requestNavigation("unknown")
    try require(controller.pendingNavigation == nil && controller.selected == "shortcuts", "unknown pages ignored")
    controller.setBusy(true, "Fixture operation")
    controller.requestNavigation("sessions")
    try require(controller.selected == "shortcuts", "busy operation retains page and controls")
    controller.setBusy(false, "Fixture complete")
    controller.applyPendingNavigation()
    try require(controller.selected == "sessions" && controller.pendingNavigation == nil, "pending navigation delivered after operation")
    try require((controller.draft["hotkeys"] as? [String: String])?["overview"] == "ctrl-alt-cmd-f12", "uncollected edit survives navigation")
    controller.modalDepth = 1
    controller.requestNavigation("general")
    try require(controller.selected == "sessions", "modal interaction defers navigation")
    controller.modalDepth = 0; controller.applyPendingNavigation()
    try require(controller.selected == "general", "modal completion delivers pending page")
    controller.requestNavigation("shortcuts")
    try require(controller.fields["hotkeys.overview"]?.stringValue == "ctrl-alt-cmd-f12", "returning to editor restores unsaved edit")
    let field = controller.fields["hotkeys.overview"]
    controller.requestNavigation("shortcuts")
    try require(controller.fields["hotkeys.overview"] === field, "current-page request preserves control identity")
    let sender = Process(); sender.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    sender.arguments = ["--self-test-navigation-send", fixtureID]
    try sender.run(); sender.waitUntilExit()
    let deadline = Date(timeIntervalSinceNow: 2)
    while controller.selected != "sessions" && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    try require(sender.terminationStatus == 0 && controller.selected == "sessions", "separate process delivers navigation to existing controller")
    print("PASS: Settings navigation validates pages, defers while busy/modal, preserves unsaved edits and avoids rebuilding the current page")
}

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? { guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }; return arguments[i + 1] }
if let fixture = argument("--self-test-navigation-send"), let id = UUID(uuidString: fixture) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name(settingsNavigation.rawValue + ".fixture." + id.uuidString), object: nil, userInfo: ["tab": "sessions"], deliverImmediately: true)
    exit(0)
}
if arguments.contains("--navigate") {
    guard let page = argument("--navigate"), settingsPages.contains(page) else {
        fputs("Unknown Settings page\n", stderr); exit(2)
    }
    DistributedNotificationCenter.default().postNotificationName(settingsNavigation, object: nil, userInfo: ["tab": page], deliverImmediately: true)
    exit(0)
}
let isPreview = argument("--render-preview") != nil
let app = NSApplication.shared
app.setActivationPolicy(isPreview || (arguments.contains("--self-test-appearance") || arguments.contains("--self-test-navigation")) ? .prohibited : .regular)
if arguments.contains("--self-test-appearance") {
    do { try testSettingsAppearance(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
}
if arguments.contains("--self-test-navigation") {
    do { try testSettingsNavigation(); exit(0) }
    catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
}
if isPreview { app.appearance = NSAppearance(named: arguments.contains("--light") ? .aqua : .darkAqua) }
let controller = GroundControl(cli: argument("--cli") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hangar").path, tab: argument("--tab") ?? "general", preview: isPreview)
app.delegate = controller
if let path = argument("--render-preview") {
    controller.buildWindow(); controller.loadFixture()
    controller.window.appearance = app.appearance
    controller.window.displayIfNeeded()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
    CATransaction.flush()
    controller.window.contentView?.layoutSubtreeIfNeeded()
    if let view = controller.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)); exit(0) }
    }
    fputs("Could not render Ground Control preview\n", stderr); exit(1)
}
app.run()
