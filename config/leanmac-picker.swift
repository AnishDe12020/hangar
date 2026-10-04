import AppKit
import ApplicationServices
import Carbon
import Darwin

@_silgen_name("GetProcessForPID")
@discardableResult
func legacyGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

final class NativeFocus {
    typealias SetFrontWindow = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    typealias MainConnection = @convention(c) () -> UInt32
    typealias SetSpaceFront = @convention(c) (UInt32, UInt64, ProcessSerialNumber) -> CGError
    let setFront: SetFrontWindow, postEvent: PostEventRecord, connection: MainConnection, setSpaceFront: SetSpaceFront

    init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let a = dlsym(handle, "_SLPSSetFrontProcessWithOptions"),
              let b = dlsym(handle, "SLPSPostEventRecordTo"),
              let c = dlsym(handle, "CGSMainConnectionID"),
              let d = dlsym(handle, "SLSSpaceSetFrontPSN") else { return nil }
        setFront = unsafeBitCast(a, to: SetFrontWindow.self)
        postEvent = unsafeBitCast(b, to: PostEventRecord.self)
        connection = unsafeBitCast(c, to: MainConnection.self)
        setSpaceFront = unsafeBitCast(d, to: SetSpaceFront.self)
        var own = ProcessSerialNumber()
        _ = legacyGetProcessForPID(getpid(), &own)
    }

    private func exactInteger(_ value: Any?, minimum: UInt64, maximum: UInt64) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, double >= Double(minimum), double <= Double(maximum) else { return nil }
        return number.uint64Value
    }

    func focus(_ packet: [String: Any]) -> String? {
        guard let rawPID = exactInteger(packet["pid"], minimum: 1, maximum: UInt64(Int32.max)),
              let rawID = exactInteger(packet["id"], minimum: 1, maximum: UInt64(UInt32.max)) else {
            return "invalid target"
        }
        let restoresAny = packet["restores"] ?? []
        guard let restores = restoresAny as? [[String: Any]], restores.count <= 32 else { return "invalid restores" }
        var parsed = [(UInt64, pid_t)]()
        for restore in restores {
            guard restore.count == 2,
                  let space = exactInteger(restore["spaceID"], minimum: 1, maximum: 9_007_199_254_740_991),
                  let pid = exactInteger(restore["pid"], minimum: 1, maximum: UInt64(Int32.max)) else {
                return "invalid restore pair"
            }
            parsed.append((space, pid_t(pid)))
        }
        let pid = pid_t(rawPID), windowID = CGWindowID(rawID)
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              info.count == 1,
              exactInteger(info[0][kCGWindowNumber as String], minimum: 1, maximum: UInt64(UInt32.max)) == rawID,
              exactInteger(info[0][kCGWindowOwnerPID as String], minimum: 1, maximum: UInt64(Int32.max)) == rawPID else {
            return "window owner changed"
        }
        var target = ProcessSerialNumber(), restorePSNs = [ProcessSerialNumber]()
        guard legacyGetProcessForPID(pid, &target) == noErr else { return "cannot resolve target process" }
        for (_, restorePID) in parsed {
            var psn = ProcessSerialNumber()
            guard legacyGetProcessForPID(restorePID, &psn) == noErr else { return "cannot resolve restore process" }
            restorePSNs.append(psn)
        }
        var mutableID = windowID
        let frontError = setFront(&target, mutableID, 0x200)
        guard frontError == .success else { return "front-window failed: \(frontError.rawValue)" }
        var record = [UInt8](repeating: 0, count: 0x100)
        record[0x04] = 0xf8; record[0x08] = 0x01; record[0x3a] = 0x10
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &mutableID) { source in
            record.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: 0x3c).copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        withUnsafeBytes(of: &point) { source in
            record.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: 0x20).copyMemory(from: source.baseAddress!, byteCount: source.count) }
        }
        let keyError = record.withUnsafeMutableBufferPointer { postEvent(&target, $0.baseAddress!) }
        guard keyError == .success else { return "make-key failed: \(keyError.rawValue)" }
        let main = connection()
        for (index, restore) in parsed.enumerated() {
            let error = setSpaceFront(main, restore.0, restorePSNs[index])
            guard error == .success else { return "restore-space failed: \(error.rawValue)" }
        }
        return nil
    }
}

func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}
struct WindowItem: Decodable {
    let id: Int, pid: Int
    let title: String
    let app: String?
    let bundle: String?
    let workspace: String
    let monitor: String?
    let visible: Bool?
    let partner: Int?
    let pairSlot: Int?
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            [title, app ?? "", workspace, monitor ?? ""].joined(separator: " ")
                .localizedStandardContains(String($0))
        }
    }
}
struct WindowRow {
    let members: [WindowItem]
    let focusID: Int
    var id: Int { members.map { $0.id }.min()! }
    var workspace: String { members[0].workspace }
}
// Stable rows: pair members stay adjacent, retaining the first member's MRU rank.
func grouped(_ windows: [WindowItem]) -> [WindowRow] {
    let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<Int>(), result = [WindowRow]()
    for w in windows where !seen.contains(w.id) {
        seen.insert(w.id)
        var members = [w]
        if let id = w.partner, id != w.id, let mate = byID[id], mate.partner == w.id,
           mate.workspace == w.workspace, !seen.contains(id) {
            members.append(mate); seen.insert(id)
            if let a = w.pairSlot, let b = mate.pairSlot, a > b { members.reverse() }
        }
        result.append(WindowRow(members: members, focusID: w.id))
    }
    return result
}
// Search ranks only matching rows. Empty queries retain the incoming MRU order.
func searchRows(_ rows: [WindowRow], query: String, workspace: String?) -> [WindowRow] {
    func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let needle = normalized(query), tokens = needle.split(separator: " ").map(String.init)
    func score(_ item: WindowItem) -> Int {
        let app = normalized(item.app ?? ""), title = normalized(item.title)
        if app == needle { return 0 }; if title == needle { return 1 }
        if app.hasPrefix(needle) { return 2 }; if title.hasPrefix(needle) { return 3 }
        let words = (app + " " + title).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if tokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) { return 4 }
        if tokens.allSatisfy({ app.contains($0) || title.contains($0) }) { return 5 }
        return 6 // A workspace/display-only match stays behind app/title matches.
    }
    let matching = rows.enumerated().compactMap { index, row -> (index: Int, row: WindowRow, score: Int)? in
        guard workspace == nil || workspace == row.workspace else { return nil }
        let members = row.members.filter { $0.matches(query) }
        guard !members.isEmpty else { return nil }
        return (index, row, needle.isEmpty ? 0 : members.map(score).min()!)
    }
    return matching.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }.map(\.row)
}

let ink = NSColor.labelColor
let muted = NSColor.secondaryLabelColor
let accent = NSColor.controlAccentColor
let previewMode = CommandLine.arguments.contains("--render-preview")
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index+1 >= CommandLine.arguments.count || CommandLine.arguments[index+1].hasPrefix("--") {
    fputs("Usage: --render-preview PATH [--dark] [--empty] [--compact]\n", stderr); exit(2)
}

// One native material per panel; rows are lightweight AppKit drawing, with no
// animation clock or custom blur/shader passes while the helper is idle.
func materialSurface(_ content: NSView) -> NSView {
    let bounds = content.bounds
    let surface: NSView
    var embedsContent = false
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || previewMode {
        surface = NSView(frame: bounds); surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    } else {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular; glass.cornerRadius = 24; glass.contentView = content; embedsContent = true
            surface = glass
        } else {
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
            surface = effect
        }
        #else
        let effect = NSVisualEffectView(frame: bounds)
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        surface = effect
        #endif
    }
    surface.wantsLayer = true; surface.layer?.cornerRadius = 24; surface.layer?.masksToBounds = true
    surface.autoresizingMask = [.width, .height]
    if !embedsContent { surface.addSubview(content) }
    content.autoresizingMask = [.width, .height]
    return surface
}

func writePreview(_ view: NSView, to path: String) throws {
    view.layoutSubtreeIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "HangarPreview", code: 1) }
    view.cacheDisplay(in: view.bounds, to: image)
    guard let data = image.representation(using: .png, properties: [:]) else { throw NSError(domain: "HangarPreview", code: 2) }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}
func rounded(_ rect: NSRect, _ radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, width: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill(); path.fill()
    if let stroke = stroke { stroke.setStroke(); path.lineWidth = width; path.stroke() }
}
func symbol(_ name: String, in rect: NSRect, color: NSColor) {
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
    image?.isTemplate = false; image?.draw(in: rect)
}
func label(_ text: String, _ frame: NSRect, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular,
           _ color: NSColor = ink) -> NSTextField {
    let view = NSTextField(labelWithString: text)
    view.frame = frame; view.font = .systemFont(ofSize: size, weight: weight); view.textColor = color
    view.lineBreakMode = .byTruncatingTail; view.maximumNumberOfLines = 1
    return view
}
class Flipped: NSView { override var isFlipped: Bool { true } }
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class Backdrop: Flipped {
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds.insetBy(dx: 0.5, dy: 0.5), 24,
                fill: previewMode || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .windowBackgroundColor : .clear,
                stroke: NSColor.separatorColor.withAlphaComponent(0.35))
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: 24, y: bounds.height-46, width: max(0, bounds.width-48), height: 0.5).fill()
    }
}
final class GroupTile: Flipped {
    weak var picker: Picker?
    let row: WindowRow
    var selected = false { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    init(row: WindowRow, picker: Picker, frame: NSRect) {
        self.row = row; self.picker = picker
        super.init(frame: frame)
        let gutter: CGFloat = row.members.count == 2 ? 24 : 0
        let column = (frame.width-32-gutter)/CGFloat(row.members.count)
        for (i,item) in row.members.enumerated() {
            let x = 16+CGFloat(i)*(column+gutter)
            let icon = NSImageView(frame: NSRect(x: x, y: 15, width: 36, height: 36))
            icon.image = picker.icon(item.bundle, pid: item.pid, appName: item.app); icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            addSubview(label(item.app ?? "Window", NSRect(x: x+48, y: 12, width: column-57, height: 17), 11, .medium, muted))
            addSubview(label(item.title.isEmpty ? "Untitled window" : item.title, NSRect(x: x+48, y: 32, width: column-57, height: 20), 13, .medium))
        }
        toolTip = row.members.map { "\($0.app ?? "Window") — \($0.title)" }.joined(separator: " + ") + " · Space \(row.workspace)"
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
        setAccessibilityHelp(row.members.count == 2 ? "Open this split pair as one group." : "Open this standalone window.")
        setAccessibilityIdentifier("group-\(row.id)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds.insetBy(dx: 1, dy: 1), 14,
                fill: selected ? accent.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(hovered ? 0.07 : 0.035),
                stroke: selected ? accent.withAlphaComponent(0.85) : NSColor.separatorColor.withAlphaComponent(hovered ? 0.45 : 0.20), width: selected ? 1.5 : 0.5)
        if selected { rounded(NSRect(x: 2, y: 23, width: 3, height: 20), 1.5, fill: accent) }
        if row.members.count == 2 {
            let x = bounds.midX
            NSColor.separatorColor.withAlphaComponent(0.40).setFill()
            NSRect(x: x-1, y: 12, width: 1, height: 12).fill()
            NSRect(x: x-1, y: 42, width: 1, height: 12).fill()
            symbol("link", in: NSRect(x: x-6, y: 28, width: 11, height: 11), color: selected ? accent : muted)
        }
    }
    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { picker?.select(row.id) }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { picker?.commit() }
    }
    override func accessibilityPerformPress() -> Bool { picker?.select(row.id); picker?.commit(); return true }
}
final class SpaceChip: NSButton {
    var active = false
    var live = false
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds.insetBy(dx: 0.5, dy: 0.5), 8,
                fill: active ? accent.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.04),
                stroke: active ? accent.withAlphaComponent(0.55) : NSColor.separatorColor.withAlphaComponent(0.2))
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                  .foregroundColor: active ? accent : ink]
        let size = title.size(withAttributes: attr)
        title.draw(at: NSPoint(x: (bounds.width-size.width)/2-(live ? 3 : 0), y: (bounds.height-size.height)/2), withAttributes: attr)
        if live { accent.setFill(); NSBezierPath(ovalIn: NSRect(x: bounds.width-10, y: bounds.midY-2, width: 4, height: 4)).fill() }
    }
}
final class Picker: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    var panel: PickerPanel!
    var root: Backdrop!
    var content = Flipped(), scroll = NSScrollView(), search = NSSearchField()
    var footer: NSTextField!, countLabel: NSTextField!, actionHint: NSTextField!
    let chipScroll = NSScrollView(), chipContent = Flipped()
    var appearanceObserver: NSObjectProtocol?
    var chips = [SpaceChip](), tiles = [Int: GroupTile](), icons = [String: NSImage]()
    var windows = [WindowItem](), rows = [WindowRow](), filtered = [WindowRow](), order = [Int]()
    var selected: Int?, session = 0, hold = false, showing = false, loading = false
    var filterSpace: String?, originWorkspace: String?, keyMonitor: Any?
    var spaceIDs = [String](), query = ""
    var maximumHeight: CGFloat = 600
    let nativeFocus = NativeFocus()
    var lastFocusSequence = 0

    func start() {
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Departures — Window switcher"; panel.identifier = NSUserInterfaceItemIdentifier("leanmac-picker")
        panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.delegate = self
        root = Backdrop(frame: panel.contentView!.bounds)
        panel.contentView = materialSurface(root)
        root.addSubview(label("Departures", NSRect(x: 24, y: 18, width: 180, height: 28), 21, .semibold))
        countLabel = label("Window switcher", NSRect(x: 24, y: 49, width: 300, height: 17), 11, .regular, muted)
        root.addSubview(countLabel)
        search = NSSearchField(frame: .zero)
        search.placeholderString = "Search windows"; search.font = .systemFont(ofSize: 13)
        search.controlSize = .large; search.focusRingType = .none; search.delegate = self
        search.setAccessibilityLabel("Search windows"); root.addSubview(search)
        chipScroll.drawsBackground = false; chipScroll.hasHorizontalScroller = true
        chipScroll.autohidesScrollers = true; chipScroll.scrollerStyle = .overlay
        chipScroll.documentView = chipContent; root.addSubview(chipScroll)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true; scroll.documentView = content; root.addSubview(scroll)
        footer = label("", .zero, 11, .regular, muted); root.addSubview(footer)
        actionHint = label("", .zero, 11, .medium, muted); actionHint.alignment = .right; root.addSubview(actionHint)
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.root.removeFromSuperview(); self.panel.contentView = materialSurface(self.root)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self = self, self.showing else { return e }
            if e.type == .flagsChanged {
                if self.hold && !e.modifierFlags.contains(.option) { self.commit() }
                return e
            }
            switch e.keyCode {
            case 48: self.step(e.modifierFlags.contains(.shift) ? -1 : 1)
            case 53: self.close(cancel: true, reason: "escape")
            case 36, 76: self.commit()
            case 123: self.horizontal(-1)
            case 124: self.horizontal(1)
            case 125: self.vertical(1)
            case 126: self.vertical(-1)
            default: return e
            }
            // Left/right remain text-editing keys when there is a query.
            if [123,124].contains(e.keyCode) && !self.query.isEmpty { return e }
            return nil
        }
        emit(["action": "ready", "protocolVersion": 2, "nativeFocus": nativeFocus != nil])
    }
    func icon(_ bundle: String?, pid: Int? = nil, appName: String? = nil) -> NSImage? {
        let identifier = bundle.flatMap { $0.isEmpty ? nil : $0 }
        if let pid = pid, pid > 0, pid <= Int(Int32.max),
           let running = NSRunningApplication(processIdentifier: pid_t(pid)),
           (identifier != nil ? running.bundleIdentifier == identifier :
                appName != nil && running.localizedName == appName),
           let image = running.icon { return image }
        if let identifier = identifier {
            if let image = icons[identifier] { return image }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                icons[identifier] = image
                return image
            }
        }
        // Do not cache a missing app: LaunchServices can discover it later.
        let fallback = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Application")?
            .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))
        fallback?.isTemplate = false
        return fallback
    }
    func decodeWindows(_ packet: [String: Any]) -> [WindowItem] {
        guard let input = packet["windows"], let data = try? JSONSerialization.data(withJSONObject: input) else { return [] }
        return (try? JSONDecoder().decode([WindowItem].self, from: data)) ?? []
    }
    func receive(_ packet: [String: Any]) {
        defer {
            if let sequence = packet["sequence"] as? Int {
                emit(["action": "ack", "sequence": sequence,
                      "session": packet["session"] as? Int ?? 0,
                      "showing": showing && panel.isVisible])
            }
        }
        guard let action = packet["action"] as? String else { return }
        if action == "warm" { for w in decodeWindows(packet) { _ = icon(w.bundle, pid: w.pid, appName: w.app) }; return }
        if action == "show" { show(packet); return }
        if action == "focus" {
            let began = ProcessInfo.processInfo.systemUptime
            var result: [String: Any] = ["action": "focused", "sequence": packet["sequence"] as? Int ?? 0,
                                         "session": packet["session"] as? Int ?? 0,
                                         "id": packet["id"] as? Int ?? 0, "pid": packet["pid"] as? Int ?? 0]
            let focusSequence = packet["sequence"] as? Int ?? 0
            if focusSequence <= lastFocusSequence { result["ok"] = false; result["error"] = "stale focus request" }
            else if showing { lastFocusSequence = focusSequence; result["ok"] = false; result["error"] = "panel visible" }
            else if let engine = nativeFocus {
                lastFocusSequence = focusSequence
                if let error = engine.focus(packet) { result["ok"] = false; result["error"] = error }
                else { result["ok"] = true }
            } else { result["ok"] = false; result["error"] = "native focus unavailable" }
            result["nativeMs"] = (ProcessInfo.processInfo.systemUptime-began)*1000
            emit(result); return
        }
        guard packet["session"] as? Int == session, showing else { return }
        switch action {
        case "step": step(packet["delta"] as? Int ?? 1)
        case "navigate":
            if packet["axis"] as? String == "horizontal" { horizontal(packet["delta"] as? Int ?? 1) }
            else { vertical(packet["delta"] as? Int ?? 1) }
        case "confirm": commit()
        case "hide": close(cancel: false)
        default: break
        }
    }
    func show(_ packet: [String: Any]) {
        let began = ProcessInfo.processInfo.systemUptime
        session = packet["session"] as? Int ?? 0; hold = packet["hold"] as? Bool ?? false
        loading = packet["loading"] as? Bool ?? false; originWorkspace = packet["originWorkspace"] as? String
        windows = decodeWindows(packet); rows = grouped(windows)
        query = ""; filterSpace = nil; search.stringValue = ""
        let frame = packet["frame"] as? [String: Double] ?? [:]
        let x = frame["x"] ?? 0, y = frame["y"] ?? 0, sw = frame["w"] ?? 1470, sh = frame["h"] ?? 900
        let width = max(300, min(680, sw-40))
        maximumHeight = CGFloat(max(220, min(600, sh-64)))
        let height = min(max(240, Double(rows.count)*72 + 170), Double(maximumHeight))
        let top = Double(NSScreen.screens.first?.frame.maxY ?? CGFloat(sh))
        panel.setFrame(NSRect(x: x+(sw-width)/2, y: top-y-(sh+height)/2, width: width, height: height), display: false)
        root.frame = panel.contentView!.bounds
        search.frame = NSRect(x: max(205, width-264), y: 19, width: max(75, min(240, width-229)), height: 30)
        countLabel.frame.size.width = width-48
        chipScroll.frame = NSRect(x: 24, y: 79, width: width-48, height: 30)
        scroll.frame = NSRect(x: 16, y: 121, width: width-32, height: height-170)
        footer.frame = NSRect(x: 24, y: height-33, width: (width-48)/2, height: 18)
        actionHint.frame = NSRect(x: width/2, y: height-33, width: width/2-24, height: 18)
        footer.stringValue = "⇥  Next   ⇧⇥  Previous   ↑↓  Select"
        actionHint.stringValue = hold ? "Release ⌥ to open   ·   esc Cancel" : "↵ Open   ·   esc Cancel"
        countLabel.stringValue = "Window switcher  ·  \(windows.count) windows"
        createChips(); selected = rows.first?.id; render()
        // Initial Tab skips the entire current group, including its other member.
        if let selected = selected, let index = order.firstIndex(of: selected), !order.isEmpty {
            let delta = packet["step"] as? Int ?? 0
            self.selected = order[((index + delta) % order.count + order.count) % order.count]
        }
        showing = true
        if !previewMode { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); panel.makeFirstResponder(search) }
        updateSelection()
        emitState("shown", extra: ["elapsedMs": (ProcessInfo.processInfo.systemUptime-began)*1000])
    }
    func createChips() {
        chips.forEach { $0.removeFromSuperview() }; chips=[]
        spaceIDs = Array(Set(windows.map { $0.workspace })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var x: CGFloat = 0
        for (index, space) in (["All"] + spaceIDs).enumerated() {
            let chip = SpaceChip(frame: NSRect(x: x, y: 0, width: index == 0 ? 48 : max(36, CGFloat(space.count)*8+22), height: 28))
            chip.title = space; chip.tag = index; chip.active = index == 0; chip.isBordered = false
            chip.live = index > 0 && windows.contains { $0.workspace == space && $0.visible == true }
            chip.target = self; chip.action = #selector(changeSpace(_:))
            chip.toolTip = index == 0 ? "All spaces" : "Filter space \(space)"
            chip.setAccessibilityLabel(chip.toolTip); chipContent.addSubview(chip); chips.append(chip)
            x += chip.frame.width+8
        }
        chipContent.frame = NSRect(x: 0, y: 0, width: max(x-8, chipScroll.bounds.width), height: 28)
        chipScroll.contentView.scroll(to: .zero)
    }
    @objc func changeSpace(_ button: SpaceChip) {
        filterSpace = button.tag == 0 ? nil : spaceIDs[button.tag-1]
        chips.forEach { $0.active = $0 === button; $0.needsDisplay = true }
        render(); panel.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { query = search.stringValue; render() }
    func render() {
        filtered = searchRows(rows, query: query, workspace: filterSpace)
        order = filtered.map { $0.id }
        if selected == nil || !order.contains(selected!) { selected = order.first }
        content.subviews.forEach { $0.removeFromSuperview() }; tiles = [:]
        let width = scroll.bounds.width-4
        var y: CGFloat = 0, previousSpace: String?
        for row in filtered {
            if previousSpace != row.workspace {
                let badge = SpaceChip(frame: NSRect(x: 6, y: y+3, width: 27, height: 21))
                badge.title = row.workspace; badge.active = row.workspace == originWorkspace; badge.isEnabled = false
                content.addSubview(badge)
                content.addSubview(label(row.members[0].monitor ?? "Display", NSRect(x: 43, y: y+6, width: width-140, height: 16), 10, .medium, muted))
                if row.workspace == originWorkspace {
                    content.addSubview(label("CURRENT", NSRect(x: width-65, y: y+7, width: 62, height: 14), 9, .semibold, accent))
                }
                previousSpace = row.workspace; y += 32
            }
            let tile = GroupTile(row: row, picker: self, frame: NSRect(x: 4, y: y, width: width-8, height: 66))
            content.addSubview(tile); tiles[row.id] = tile; y += 74
        }
        if order.isEmpty {
            let message = loading ? "Finding your windows…" : (windows.isEmpty ? "No windows to switch to" : "No matching windows")
            let detail = loading ? "Your workspaces will appear here shortly." : (windows.isEmpty ? "Open an app, then return to Departures." : "Try another search or choose All workspaces.")
            let heading = label(message, NSRect(x: 12, y: 28, width: width-24, height: 24), 15, .medium)
            heading.alignment = .center; content.addSubview(heading)
            let hint = label(detail, NSRect(x: 12, y: 57, width: width-24, height: 20), 12, .regular, muted)
            hint.alignment = .center; content.addSubview(hint); y = 111
        }
        let height = min(maximumHeight, max(265, y+176))
        if abs(panel.frame.height-height) > 0.5 {
            // Keep the search field anchored while results expand or contract.
            let old = panel.frame
            panel.setFrame(NSRect(x: old.minX, y: old.maxY-height, width: old.width, height: height), display: true)
            root.frame = panel.contentView!.bounds
            scroll.frame.size.height = height-170
            footer.frame.origin.y = height-33; actionHint.frame.origin.y = height-33
        }
        content.frame = NSRect(x: 0, y: 0, width: scroll.bounds.width, height: max(y+8, scroll.bounds.height))
        updateSelection()
    }
    func select(_ id: Int) { guard order.contains(id) else { return }; selected = id; updateSelection() }
    func step(_ delta: Int) {
        guard !order.isEmpty else { return }
        let index = selected.flatMap { order.firstIndex(of: $0) } ?? 0
        selected = order[((index+delta) % order.count+order.count) % order.count]; updateSelection()
    }
    func horizontal(_ delta: Int) {
        if query.isEmpty { step(delta) }
    }
    func vertical(_ delta: Int) {
        step(delta)
    }
    func updateSelection() {
        for (id, tile) in tiles where tile.selected != (id == selected) {
            tile.selected = id == selected; tile.setAccessibilityValue(tile.selected ? "Selected" : "")
        }
        if let id = selected, let tile = tiles[id] {
            let frame = tile.convert(tile.bounds, to: content).insetBy(dx: 0, dy: -8)
            content.scrollToVisible(frame)
        }
        if showing { emitState("selection") }
    }
    func emitState(_ action: String, extra: [String: Any] = [:]) {
        var value: [String: Any] = ["action": action, "session": session, "rows": filtered.count,
                                    "windows": filtered.reduce(0) { $0+$1.members.count }, "query": query,
                                    "width": panel.frame.width, "height": panel.frame.height]
        if let row = filtered.first(where: { $0.id == selected }) {
            value["id"] = row.focusID; value["ids"] = row.members.map { $0.id }; value["group"] = row.id
        }
        for (key,v) in extra { value[key] = v }; emit(value)
    }
    func commit() {
        guard showing, !loading, let row = filtered.first(where: { $0.id == selected }),
              let item = row.members.first(where: { $0.id == row.focusID }) else { return }
        close(cancel: false)
        emit(["action": "choose", "session": session, "hidden": !panel.isVisible,
              "id": item.id, "pid": item.pid, "ids": row.members.map { $0.id }])
    }
    func close(cancel: Bool, reason: String = "deactivate") {
        guard showing else { return }; showing = false; panel.orderOut(nil)
        if cancel { emit(["action": "cancel", "session": session, "reason": reason, "hidden": !panel.isVisible]) }
    }
    func windowDidResignKey(_ notification: Notification) { if showing { close(cancel: true) } }
}

if CommandLine.arguments.contains("--self-test") {
    func w(_ id: Int, _ space: String, _ partner: Int? = nil) -> WindowItem {
        WindowItem(id: id, pid: 1, title: "Window \(id)", app: "App", bundle: nil, workspace: space, monitor: nil, visible: true, partner: partner, pairSlot: nil)
    }
    let rows = grouped([w(1,"1",3),w(2,"1"),w(3,"1",1),w(4,"2")])
    precondition(rows.map { $0.members.map { $0.id } } == [[1,3],[2],[4]])
    precondition(rows.map { $0.id } == [1,2,4])
    precondition(rows[0].focusID == 1)
    precondition(grouped([w(3,"1",1),w(1,"1",3)])[0].focusID == 3)
    precondition(grouped([w(1,"1",2),w(2,"2",1)]).count == 2)
    precondition(grouped([w(1,"1",2),w(2,"1")]).count == 2)
    precondition(grouped([w(1,"1",1)]).count == 1)
    precondition(grouped([w(1,"1"),w(1,"1")]).count == 1)
    precondition(w(1,"1").matches("app 1")); precondition(!w(1,"1").matches("missing"))
    func result(_ id: Int, app: String, title: String, space: String = "1") -> WindowItem {
        WindowItem(id: id, pid: 1, title: title, app: app, bundle: nil, workspace: space, monitor: "Display", visible: true, partner: nil, pairSlot: nil)
    }
    let ranked = grouped([
        result(10, app: "Browser", title: "A note about Safari"), result(11, app: "Safari Technology Preview", title: "Home"),
        result(12, app: "Safari", title: "Other"), result(13, app: "Notes", title: "Safari"),
        result(14, app: "Safari", title: "Later"), result(15, app: "Finder", title: "Files", space: "Safari")])
    precondition(searchRows(ranked, query: "safari", workspace: nil).map(\.id) == [12, 14, 13, 11, 10, 15])
    precondition(searchRows(ranked, query: "  SAFARI  ", workspace: nil).map(\.id) == [12, 14, 13, 11, 10, 15])
    precondition(searchRows(ranked, query: "", workspace: nil).map(\.id) == ranked.map(\.id))
    precondition(searchRows(ranked, query: "   ", workspace: nil).map(\.id) == ranked.map(\.id))
    precondition(searchRows(ranked, query: "safari", workspace: "Safari").map(\.id) == [15])
    let accented = grouped([result(20, app: "Notes", title: "Café plans"), result(21, app: "Preview", title: "Plans for a café")])
    precondition(searchRows(accented, query: "cafe", workspace: nil).map(\.id) == [20, 21])
    precondition(searchRows(accented, query: "plans cafe", workspace: nil).map(\.id) == [20, 21])
    // Ranking never rebuilds pair identities or changes the MRU focus member.
    let pairs = grouped([w(3,"1",1), w(1,"1",3), w(2,"1")])
    precondition(searchRows(pairs, query: "window 1", workspace: nil)[0].focusID == 3)
    let visible = searchRows(ranked, query: "Safari", workspace: nil).map(\.id)
    precondition(visible.contains(10) && visible.first == 12)
    precondition(searchRows(ranked, query: "Technology", workspace: nil).map(\.id) == [11])
    print("Native picker model: grouping/MRU plus deterministic search exact/prefix/Unicode/tie/filter checks passed")
} else {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let picker = Picker()
    if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), index+1 < CommandLine.arguments.count {
        if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
        picker.start()
        let fixture: [[String: Any]] = [
            ["id": 1, "pid": 1, "app": "Safari", "bundle": "com.apple.Safari", "title": "A quieter place to work", "workspace": "1", "monitor": "Studio Display", "visible": true, "partner": 2, "pairSlot": 1],
            ["id": 2, "pid": 1, "app": "Notes", "bundle": "com.apple.Notes", "title": "Launch notes", "workspace": "1", "monitor": "Studio Display", "partner": 1, "pairSlot": 2],
            ["id": 3, "pid": 1, "app": "Finder", "bundle": "com.apple.finder", "title": "Design references", "workspace": "1", "monitor": "Studio Display", "visible": true],
            ["id": 4, "pid": 1, "app": "Terminal", "bundle": "com.apple.Terminal", "title": "hangar — main", "workspace": "2", "monitor": "Mac display"]]
        picker.show(["session": 1, "windows": fixture, "originWorkspace": "1", "frame": ["x": 0.0, "y": 0.0, "w": CommandLine.arguments.contains("--compact") ? 480.0 : 1440.0, "h": 900.0]])
        if CommandLine.arguments.contains("--empty") { picker.query = "no matching window"; picker.search.stringValue = picker.query; picker.render() }
        do { try writePreview(picker.panel.contentView!, to: CommandLine.arguments[index+1]); exit(0) }
        catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
    }
    DispatchQueue.main.async { picker.start() }
    DispatchQueue.global(qos: .userInitiated).async {
        while let line = readLine() {
            guard line.utf8.count < 2_000_000, let data = line.data(using: .utf8),
                  let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            DispatchQueue.main.async { picker.receive(packet) }
        }
        DispatchQueue.main.async { app.terminate(nil) }
    }
    app.run()
}
