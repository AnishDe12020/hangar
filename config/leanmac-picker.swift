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
let ink = NSColor(calibratedWhite: 0.96, alpha: 1)
let muted = NSColor(calibratedWhite: 0.64, alpha: 1)
let accent = NSColor(calibratedRed: 0.47, green: 0.87, blue: 0.81, alpha: 1)
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
        rounded(bounds.insetBy(dx: 0.5, dy: 0.5), 22,
                fill: NSColor(calibratedWhite: 0.075, alpha: 0.86),
                stroke: NSColor(white: 1, alpha: 0.16))
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
        let column = (frame.width-20-gutter)/CGFloat(row.members.count)
        for (i,item) in row.members.enumerated() {
            let x = 10+CGFloat(i)*(column+gutter)
            let icon = NSImageView(frame: NSRect(x: x, y: 12, width: 28, height: 28))
            icon.image = picker.icon(item.bundle); icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            addSubview(label(item.app ?? "Window", NSRect(x: x+37, y: 7, width: column-53, height: 15), 10, .medium, muted))
            addSubview(label(item.title, NSRect(x: x+37, y: 24, width: column-53, height: 18), 12, .medium))
        }
        toolTip = row.members.map { "\($0.app ?? "Window") — \($0.title)" }.joined(separator: " + ") + " · Space \(row.workspace)"
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
        setAccessibilityHelp(row.members.count == 2 ? "Open this split pair as one group." : "Open this standalone window.")
        setAccessibilityIdentifier("group-\(row.id)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        rounded(bounds.insetBy(dx: 1, dy: 1), 9,
                fill: selected ? accent.withAlphaComponent(0.13) : NSColor(white: 1, alpha: hovered ? 0.07 : 0.025),
                stroke: selected ? accent : NSColor(white: 1, alpha: 0.055), width: selected ? 1.5 : 1)
        if row.members.count == 2 {
            let x = bounds.midX
            NSColor(white: 1, alpha: 0.10).setFill()
            NSRect(x: x-1, y: 9, width: 1, height: 10).fill()
            NSRect(x: x-1, y: 34, width: 1, height: 9).fill()
            symbol("link", in: NSRect(x: x-6, y: 21, width: 11, height: 11), color: selected ? accent : muted)
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
                fill: active ? accent.withAlphaComponent(0.16) : NSColor(white: 1, alpha: 0.045),
                stroke: active ? accent.withAlphaComponent(0.55) : NSColor(white: 1, alpha: 0.06))
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
    var footer: NSTextField!, countLabel: NSTextField!
    var chips = [SpaceChip](), tiles = [Int: GroupTile](), icons = [String: NSImage]()
    var windows = [WindowItem](), rows = [WindowRow](), filtered = [WindowRow](), order = [Int]()
    var selected: Int?, session = 0, hold = false, showing = false, loading = false
    var filterSpace: String?, originWorkspace: String?, keyMonitor: Any?
    var spaceIDs = [String](), query = ""
    var maximumHeight: CGFloat = 520
    let nativeFocus = NativeFocus()
    var lastFocusSequence = 0

    func start() {
        panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "LeanMac Window Switcher"; panel.identifier = NSUserInterfaceItemIdentifier("leanmac-picker")
        panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua); panel.delegate = self
        root = Backdrop(frame: panel.contentView!.bounds); root.wantsLayer = true
        root.layer?.cornerRadius = 22; root.layer?.masksToBounds = true
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.wantsLayer = true
        blur.layer?.cornerRadius = root.layer!.cornerRadius; blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]; blur.material = .hudWindow
        blur.blendingMode = .behindWindow; blur.state = .active
        panel.contentView = blur; blur.addSubview(root); root.autoresizingMask = [.width, .height]
        root.addSubview(label("Switch", NSRect(x: 18, y: 12, width: 70, height: 22), 16, .semibold))
        countLabel = label("", NSRect(x: 82, y: 16, width: 140, height: 16), 10, .medium, muted)
        root.addSubview(countLabel)
        search = NSSearchField(frame: NSRect(x: 180, y: 22, width: 370, height: 30))
        search.placeholderString = "Search windows"; search.font = .systemFont(ofSize: 13)
        search.focusRingType = .none; search.delegate = self
        search.setAccessibilityLabel("Search windows"); root.addSubview(search)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = content; root.addSubview(scroll)
        footer = label("", .zero, 11, .medium, muted); root.addSubview(footer)
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
    func icon(_ bundle: String?) -> NSImage? {
        guard let bundle = bundle else { return NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) }
        if let icon = icons[bundle] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
        icons[bundle] = icon; return icon
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
        if action == "warm" { for w in decodeWindows(packet) { _ = icon(w.bundle) }; return }
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
        let width = min(620, sw-48)
        maximumHeight = CGFloat(min(520, sh-80))
        let height = min(max(180, Double(rows.count)*56 + 120), Double(maximumHeight))
        let top = Double(NSScreen.screens.first?.frame.maxY ?? CGFloat(sh))
        panel.setFrame(NSRect(x: x+(sw-width)/2, y: top-y-(sh+height)/2, width: width, height: height), display: false)
        root.frame = panel.contentView!.bounds
        search.frame = NSRect(x: width-236, y: 11, width: 218, height: 24)
        scroll.frame = NSRect(x: 10, y: 66, width: width-20, height: height-96)
        footer.frame = NSRect(x: 18, y: height-23, width: width-36, height: 15)
        footer.font = .systemFont(ofSize: 10, weight: .medium)
        footer.stringValue = hold ? "⇥ / ⇧⇥ or ↑↓  switch group                          release ⌥ open · esc cancel"
                                  : "⇥ / ⇧⇥ or ↑↓  switch group                          ↵ open · esc cancel"
        countLabel.stringValue = "\(rows.count) items · \(windows.count) windows"
        createChips(); selected = rows.first?.id; render()
        // Initial Tab skips the entire current group, including its other member.
        if let selected = selected, let index = order.firstIndex(of: selected), !order.isEmpty {
            let delta = packet["step"] as? Int ?? 0
            self.selected = order[((index + delta) % order.count + order.count) % order.count]
        }
        showing = true; panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); panel.makeFirstResponder(search)
        updateSelection()
        emitState("shown", extra: ["elapsedMs": (ProcessInfo.processInfo.systemUptime-began)*1000])
    }
    func createChips() {
        chips.forEach { $0.removeFromSuperview() }; chips=[]
        spaceIDs = Array(Set(windows.map { $0.workspace })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var x: CGFloat = 18
        for (index, space) in (["All"] + spaceIDs).enumerated() {
            let chip = SpaceChip(frame: NSRect(x: x, y: 39, width: index == 0 ? 39 : 30, height: 21))
            chip.title = space; chip.tag = index; chip.active = index == 0; chip.isBordered = false
            chip.live = index > 0 && windows.contains { $0.workspace == space && $0.visible == true }
            chip.target = self; chip.action = #selector(changeSpace(_:))
            chip.toolTip = index == 0 ? "All spaces" : "Filter space \(space)"
            chip.setAccessibilityLabel(chip.toolTip); root.addSubview(chip); chips.append(chip)
            x += chip.frame.width+7
        }
    }
    @objc func changeSpace(_ button: SpaceChip) {
        filterSpace = button.tag == 0 ? nil : spaceIDs[button.tag-1]
        chips.forEach { $0.active = $0 === button; $0.needsDisplay = true }
        render(); panel.makeFirstResponder(search)
    }
    func controlTextDidChange(_ obj: Notification) { query = search.stringValue; render() }
    func render() {
        filtered = rows.filter { row in
            (filterSpace == nil || filterSpace == row.workspace) && row.members.contains { $0.matches(query) }
        }
        order = filtered.map { $0.id }
        if selected == nil || !order.contains(selected!) { selected = order.first }
        content.subviews.forEach { $0.removeFromSuperview() }; tiles = [:]
        let width = scroll.bounds.width-8
        var y: CGFloat = 0, previousSpace: String?
        for row in filtered {
            if previousSpace != row.workspace {
                let badge = SpaceChip(frame: NSRect(x: 6, y: y+3, width: 23, height: 18))
                badge.title = row.workspace; badge.active = row.workspace == originWorkspace; badge.isEnabled = false
                content.addSubview(badge)
                content.addSubview(label(row.members[0].monitor ?? "Display", NSRect(x: 37, y: y+4, width: width-130, height: 15), 9, .medium, muted))
                if row.workspace == originWorkspace {
                    content.addSubview(label("CURRENT", NSRect(x: width-65, y: y+5, width: 62, height: 14), 8, .semibold, accent))
                }
                previousSpace = row.workspace; y += 26
            }
            let tile = GroupTile(row: row, picker: self, frame: NSRect(x: 4, y: y, width: width-8, height: 52))
            content.addSubview(tile); tiles[row.id] = tile; y += 56
        }
        if order.isEmpty {
            content.addSubview(label(loading ? "Loading…" : "No matching groups", NSRect(x: 10, y: 20, width: width-20, height: 22), 13, .medium, muted))
            y = 70
        }
        let height = min(maximumHeight, max(180, y+102))
        if abs(panel.frame.height-height) > 0.5 {
            // Keep the search field anchored while results expand or contract.
            let old = panel.frame
            panel.setFrame(NSRect(x: old.minX, y: old.maxY-height, width: old.width, height: height), display: true)
            root.frame = panel.contentView!.bounds
            scroll.frame.size.height = height-96
            footer.frame.origin.y = height-23
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
    print("Native picker model: 10 checks passed")
} else {
    let app = NSApplication.shared; app.setActivationPolicy(.accessory)
    let picker = Picker()
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
