import AppKit

// Presentation only. Hammerspoon validates and executes every window operation.
let dragType = NSPasteboard.PasteboardType("local.leanmac.windows")
let accent = NSColor(name: NSColor.Name("HangarAccent")) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.40, green: 0.84, blue: 0.78, alpha: 1)
        : NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.40, alpha: 1)
}
let previewMode = CommandLine.arguments.contains("--render-preview")
let hiddenMode = previewMode || CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--surface-check")
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
   index+1 >= CommandLine.arguments.count || CommandLine.arguments[index+1].hasPrefix("--") {
    fputs("Usage: --render-preview PATH [--dark|--light] [--empty] [--compact]\n", stderr); exit(2)
}
var testPackets: [[String:Any]]?
func emit(_ value: [String: Any]) {
    if testPackets != nil { testPackets!.append(value); return }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}
func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor) -> NSTextField {
    let v = NSTextField(labelWithString: text)
    v.font = .systemFont(ofSize: size); v.textColor = color
    v.lineBreakMode = .byTruncatingTail
    return v
}
final class Action: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func invoke(_ sender: Any?) { run() }
}
let overviewStyle: NSWindow.StyleMask = [.titled, .closable, .resizable, .utilityWindow]
func fitOverviewContent(_ requested: NSRect, inside available: NSRect) -> NSRect {
    // visibleFrame constrains the complete window, including the native titlebar.
    var frame = NSWindow.frameRect(forContentRect: requested, styleMask: overviewStyle)
    frame.size.width = min(frame.width, available.width); frame.size.height = min(frame.height, available.height)
    frame.origin.x = min(max(frame.minX, available.minX), available.maxX - frame.width)
    frame.origin.y = min(max(frame.minY, available.minY), available.maxY - frame.height)
    return NSWindow.contentRect(forFrameRect: frame, styleMask: overviewStyle)
}
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { board.send("close") }
}
class Flipped: NSView { override var isFlipped: Bool { true } }
final class Backdrop: Flipped {
    override func draw(_ dirtyRect: NSRect) {
        if previewMode || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
        }
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
        NSRect(x: 24, y: bounds.height-65, width: max(0, bounds.width-48), height: 0.5).fill()
    }
}
func materialSurface(_ content: NSView) -> NSView {
    let surface: NSView
    var embedsContent = false
    if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || previewMode {
        surface = NSView(frame: content.bounds)
        surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    } else {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.style = .regular; glass.cornerRadius = 20; glass.contentView = content; embedsContent = true
            surface = glass
        } else {
            let effect = NSVisualEffectView(frame: content.bounds)
            effect.material = .underWindowBackground; effect.blendingMode = .behindWindow; effect.state = .active
            surface = effect
        }
        #else
        let effect = NSVisualEffectView(frame: content.bounds)
        effect.material = .underWindowBackground; effect.blendingMode = .behindWindow; effect.state = .active
        surface = effect
        #endif
    }
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

final class Tile: NSView, NSDraggingSource {
    let ids: [Int]
    let workspace: String
    let title: String
    let subtitle: String
    let icon: NSImage?
    let handle: Bool
    var start = NSPoint.zero
    var dragged = false
    var target = false
    var hovered = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { !handle }
    override var isFlipped: Bool { true }
    init(frame: NSRect, ids: [Int], workspace: String, title: String, subtitle: String = "", icon: NSImage? = nil, handle: Bool = false) {
        self.ids=ids; self.workspace=workspace; self.title=title; self.subtitle=subtitle; self.icon=icon; self.handle=handle
        super.init(frame: frame)
        registerForDraggedTypes([dragType])
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel(handle ? "Move linked pair" : "Focus \(title): \(subtitle)")
        setAccessibilityHelp("Drag to another space. Right-click for move, swap and separate actions.")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: NSRect) {
        let focused = window?.firstResponder === self
        let path=NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: handle ? 10 : 14, yRadius: handle ? 10 : 14)
        (handle ? NSColor.labelColor.withAlphaComponent(0.04) : NSColor.labelColor.withAlphaComponent(hovered ? 0.085 : 0.045)).setFill(); path.fill()
        (target || focused ? accent : NSColor.separatorColor.withAlphaComponent(hovered ? 0.6 : 0.35)).setStroke()
        path.lineWidth=target || focused ? 2 : 0.5; path.stroke()
        let p=NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        let x: CGFloat = handle ? 14 : 68
        if let icon=icon { icon.draw(in: NSRect(x: 15, y: 11, width: 40, height: 40), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        (title as NSString).draw(in: NSRect(x:x,y:handle ? 9 : 20,width:bounds.width-x-14,height:20), withAttributes: [.font:NSFont.systemFont(ofSize:handle ? 11 : 13,weight:.semibold),.foregroundColor:handle ? NSColor.secondaryLabelColor : NSColor.labelColor,.paragraphStyle:p])
        if !handle {
            ((subtitle.isEmpty ? "Untitled window" : subtitle) as NSString).draw(in: NSRect(x:16,y:61,width:bounds.width-32,height:20),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:p])
        }
    }
    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 49 { board.send("focus", ["ids": ids]); return }
        if [123, 124, 125, 126].contains(event.keyCode) { board.step(from: self, delta: [123, 126].contains(event.keyCode) ? -1 : 1); return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) { if !handle { window?.makeFirstResponder(self) }; start=event.locationInWindow; dragged=false; board.pointerDown=true; board.pointer("down",ids) }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDragged(with event: NSEvent) {
        guard !board.busy, !dragged, hypot(event.locationInWindow.x-start.x,event.locationInWindow.y-start.y)>5 else { return }
        dragged=true; board.dragging=true
        board.pointer("drag",ids)
        let item=NSPasteboardItem()
        var payload:[String:Any]=["ids":ids,"workspace":workspace,"session":board.session,"version":board.version]
        payload["pair"]=board.pairFor(ids).flatMap{board.pairMeta($0)} ?? false
        guard let data=try? JSONSerialization.data(withJSONObject:payload) else { return }
        item.setData(data,forType:dragType)
        let dragging=NSDraggingItem(pasteboardWriter:item)
        let image=NSImage(size:bounds.size)
        image.lockFocus(); draw(bounds); image.unlockFocus()
        dragging.setDraggingFrame(bounds,contents:image)
        beginDraggingSession(with:[dragging],event:event,source:self)
    }
    override func mouseUp(with event: NSEvent) { board.pointerDown=false; if !dragged && !handle { board.send("focus",["ids":ids]) };board.applyQueued() }
    override func accessibilityPerformPress() -> Bool { guard !handle else { return false }; board.send("focus",["ids":ids]); return true }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { board.pointerDown=false;board.dragging=false; board.applyQueued() }
    override func menu(for event: NSEvent) -> NSMenu? { board.menu(ids, workspace:workspace) }
    func pairPayload(_ sender: NSDraggingInfo) -> [String:Any]? {
        guard !handle, ids.count==1, let data=board.payload(sender), let source=data["ids"] as? [Int],source.count==1,source[0] != ids[0],data["workspace"] as? String == workspace else { return nil }
        return data
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        target=pairPayload(sender) != nil; needsDisplay=true
        return board.payload(sender) == nil ? [] : .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { target=false; needsDisplay=true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { board.payload(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        board.pointer("drop",ids)
        target=false; needsDisplay=true
        guard let data=board.payload(sender),let source=data["ids"] as? [Int] else { return false }
        if pairPayload(sender) != nil { board.send("pair",["ids":[source[0],ids[0]]],snapshot:data) }
        else { board.send("move",["ids":source,"target":workspace],snapshot:data) }
        return true
    }
}
final class WorkspaceButton: NSButton {
    var visible = false
    override func draw(_ dirtyRect: NSRect) {
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: visible ? accent : NSColor.labelColor])
        text.draw(at: NSPoint(x: 5, y: (bounds.height-text.size().height)/2))
        let arrow = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.tertiaryLabelColor]))
        arrow?.isTemplate = false; arrow?.draw(in: NSRect(x: bounds.width-22, y: (bounds.height-11)/2, width: 11, height: 11))
        if isHighlighted { NSColor.labelColor.withAlphaComponent(0.06).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill() }
    }
}
final class Lane: NSView {
    let workspace: String
    var target=false
    override var isFlipped: Bool { true }
    init(frame:NSRect,workspace:String) { self.workspace=workspace; super.init(frame:frame); registerForDraggedTypes([dragType]) }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ rect:NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
        (target ? accent.withAlphaComponent(0.10) : NSColor.labelColor.withAlphaComponent(0.025)).setFill(); path.fill()
        (target ? accent : NSColor.separatorColor.withAlphaComponent(0.20)).setStroke(); path.lineWidth = target ? 2 : 0.5; path.stroke()
    }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation { target=board.payload(sender) != nil; needsDisplay=true; return target ? .move : [] }
    override func draggingExited(_ sender:NSDraggingInfo?) { target=false; needsDisplay=true }
    override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool { board.payload(sender) != nil }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        target=false;needsDisplay=true
        guard let p=board.payload(sender),let ids=p["ids"] as? [Int] else { return false }
        board.send("move",["ids":ids,"target":workspace],snapshot:p);return true
    }
}

final class Board: NSObject, NSWindowDelegate, NSMenuDelegate {
    var panel: Panel!
    var root=Backdrop()
    var deckScroll: NSScrollView?
    var laneScrolls: [String:NSScrollView] = [:]
    var windowTiles: [Tile] = []
    var appearanceObserver: NSObjectProtocol?
    var status=label("Loading spaces…",size:11,color:.secondaryLabelColor)
    var model:[String:Any]=[:]
    var queued:[String:Any]?
    var actions:[Action]=[]
    var menuActions:[Action]=[]
    var icons:[String:NSImage]=[:]
    var version=0,session=0
    var busy=false,dragging=false,menuOpen=false,pointerDown=false
    func pointer(_ phase:String,_ ids:[Int]) { emit(["action":"pointer","phase":phase,"ids":ids,"busy":busy,"dragging":dragging]) }
    var spaces:[[String:Any]] { model["spaces"] as? [[String:Any]] ?? [] }
    var rows:[[String:Any]] { model["windows"] as? [[String:Any]] ?? [] }
    func start() {
        let args=CommandLine.arguments.dropFirst().compactMap(Double.init)
        var f=args.count==4 ? NSRect(x:args[0],y:(NSScreen.screens.first?.frame.maxY ?? 900)-args[1]-args[3],width:args[2],height:args[3]) : NSRect(x:100,y:100,width:1100,height:670)
        if previewMode && CommandLine.arguments.contains("--compact") { f.size=NSSize(width:720,height:520) }
        if !previewMode, let screen = NSScreen.screens.first(where: { $0.frame.intersects(f) }) ?? NSScreen.main {
            let area = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            f = fitOverviewContent(f, inside: area)
        }
        panel=Panel(contentRect:f,styleMask:overviewStyle,backing:.buffered,defer:false)
        panel.title="Tower — Workspace overview";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true
        panel.minSize=NSSize(width:min(680, f.width),height:min(450, f.height));panel.animationBehavior = .none;panel.level = .floating;panel.hidesOnDeactivate=false
        panel.isReleasedWhenClosed=false;panel.delegate=self
        // A default NSPanel is opaque even when its content is a glass view.
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=true
        root.frame=NSRect(origin:.zero,size:f.size);panel.contentView=materialSurface(root)
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.root.removeFromSuperview(); self.panel.contentView = materialSurface(self.root)
        }
        render()
        if !hiddenMode { panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
        emit(["action":"ready"])
    }
    // Resolve the running app first: apps outside /Applications, helper hosts,
    // and launchers are not always registered with LaunchServices. Never let a
    // recycled PID override the bundle identity in the window snapshot.
    func applicationIcon(_ row:[String:Any])->(image:NSImage, source:String)? {
        let bundle = (row["bundle"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        let name = row["app"] as? String ?? ""
        if let rawPID=row["pid"] as? Int, rawPID>0, rawPID<=Int(Int32.max),
           let running=NSRunningApplication(processIdentifier:pid_t(rawPID)), !running.isTerminated,
           (!bundle.isEmpty ? running.bundleIdentifier == bundle : !name.isEmpty && running.localizedName == name) {
            if let image=running.icon { return (image,"runningApplication") }
            if let url=running.bundleURL { return (NSWorkspace.shared.icon(forFile:url.path),"runningBundleURL") }
        }
        guard !bundle.isEmpty else { return nil }
        if let image=icons[bundle] { return (image,"bundleCache") }
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { return nil }
        let image=NSWorkspace.shared.icon(forFile:url.path);icons[bundle]=image
        return (image,"bundleURL")
    }
    func icon(_ row:[String:Any])->NSImage? {
        if let resolved=applicationIcon(row) { return resolved.image }
        let fallback=NSImage(systemSymbolName:"macwindow",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[.secondaryLabelColor]))
        fallback?.isTemplate=false;return fallback
    }
    func button(_ title:String, frame:NSRect, _ run:@escaping ()->Void)->NSButton {
        let a=Action(run);actions.append(a)
        let b=NSButton(title:title,target:a,action:#selector(Action.invoke));b.bezelStyle = .rounded;b.controlSize = .small;b.frame=frame;return b
    }
    func render() {
        guard panel != nil else { return }
        let horizontal = deckScroll?.contentView.bounds.origin.x ?? 0
        let offsets = laneScrolls.mapValues { $0.contentView.bounds.origin.y }
        let focusedID = (panel.firstResponder as? Tile)?.ids.first
        root.subviews.forEach{$0.removeFromSuperview()};actions=[];laneScrolls=[:];windowTiles=[]
        let width=root.bounds.width,height=root.bounds.height
        let heading=label("Tower",size:20);heading.font = .systemFont(ofSize:20,weight:.semibold)
        heading.frame=NSRect(x:24,y:17,width:180,height:30);root.addSubview(heading)
        let summary=label("\(spaces.count) workspaces  ·  \(rows.count) windows",size:12,color:.secondaryLabelColor)
        summary.alignment = .right;summary.frame=NSRect(x:width-410,y:24,width:282,height:20);root.addSubview(summary)
        let refresh=button("Refresh",frame:NSRect(x:width-108,y:17,width:84,height:30)){self.send("refresh")}
        refresh.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:nil);refresh.imagePosition = .imageLeading
        refresh.toolTip="Refresh workspaces and windows";root.addSubview(refresh)
        let n=max(1,spaces.count),gap:CGFloat=14,margin:CGFloat=24
        // Keep cards readable even with many workspaces or a small display.
        let col=max(236,min(320,(width-margin*2-gap*CGFloat(n-1))/CGFloat(n)))
        let deckWidth=max(width-margin*2,CGFloat(n)*(col+gap)-gap)
        let deck=NSScrollView(frame:NSRect(x:margin,y:66,width:width-margin*2,height:max(180,height-144)))
        deck.hasHorizontalScroller=true;deck.autohidesScrollers=true;deck.scrollerStyle = .overlay;deck.drawsBackground=false
        let columns=Flipped(frame:NSRect(x:0,y:0,width:deckWidth,height:deck.bounds.height-12));deck.documentView=columns
        deckScroll=deck;root.addSubview(deck)
        for (index,space) in spaces.enumerated() {
            guard let ws=space["id"] as? String else { continue }
            let x=CGFloat(index)*(col+gap),visible=space["visible"] as? Bool == true
            let switchAction=Action { self.send("workspace",["target":ws]) };actions.append(switchAction)
            let header=WorkspaceButton(title:"Workspace \(ws)",target:switchAction,action:#selector(Action.invoke))
            header.frame=NSRect(x:x,y:0,width:col,height:32);header.visible=visible;header.isBordered=false
            header.toolTip="Switch to workspace \(ws)";columns.addSubview(header)
            let monitor=(space["monitor"] as? String ?? "Display").replacingOccurrences(of:"Built-in Retina Display",with:"Mac display")
            let subtitle=label(monitor,size:11,color:.secondaryLabelColor);subtitle.frame=NSRect(x:x+5,y:35,width:col-10,height:17);columns.addSubview(subtitle)
            let members=rows.filter{$0["workspace"] as? String == ws}
            let state=label((visible ? "●  Visible  ·  " : "")+"\(members.count) window\(members.count == 1 ? "" : "s")",size:10,color:visible ? accent : .secondaryLabelColor)
            state.frame=NSRect(x:x+5,y:56,width:col-10,height:16);columns.addSubview(state)
            let scroll=NSScrollView(frame:NSRect(x:x,y:84,width:col,height:max(80,columns.bounds.height-84)))
            scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.scrollerStyle = .overlay;scroll.drawsBackground=false
            let lane=Lane(frame:NSRect(x:0,y:0,width:col,height:scroll.bounds.height),workspace:ws)
            var y:CGFloat=8;var used=Set<Int>()
            for pair in model["pairs"] as? [[String:Any]] ?? [] where pair["workspace"] as? String == ws {
                guard let ids=pair["ids"] as? [Int],ids.count==2,ids.allSatisfy({ id in members.contains{$0["id"] as? Int == id} }) else { continue }
                let handle=Tile(frame:NSRect(x:8,y:y,width:col-16,height:32),ids:ids,workspace:ws,title:"Linked pair  ·  Drag together",handle:true)
                lane.addSubview(handle);y+=38
                for id in ids {
                    let row=members.first{$0["id"] as? Int == id}!
                    let view=tile(row,frame:NSRect(x:8,y:y,width:col-16,height:94));lane.addSubview(view);windowTiles.append(view)
                    y+=100;used.insert(id)
                };y+=10
            }
            for row in members {
                guard let id=row["id"] as? Int,!used.contains(id) else { continue }
                let view=tile(row,frame:NSRect(x:8,y:y,width:col-16,height:94));lane.addSubview(view);windowTiles.append(view);y+=102
            }
            if members.isEmpty {
                let empty=label("No windows",size:13,color:.secondaryLabelColor);empty.alignment = .center
                empty.frame=NSRect(x:10,y:45,width:col-20,height:22);lane.addSubview(empty);y=78
            }
            let empty=label("Drop a window here",size:11,color:.tertiaryLabelColor);empty.alignment = .center
            empty.frame=NSRect(x:10,y:y+15,width:col-20,height:20);lane.addSubview(empty);y+=65
            lane.frame.size.height=max(y,scroll.bounds.height);scroll.documentView=lane;columns.addSubview(scroll);laneScrolls[ws]=scroll
            scroll.contentView.scroll(to:NSPoint(x:0,y:min(offsets[ws] ?? 0,max(0,y-scroll.bounds.height))))
        }
        if spaces.isEmpty {
            let empty=label(model.isEmpty ? "Loading your workspaces…" : "No workspaces available",size:16,color:.secondaryLabelColor)
            empty.alignment = .center;empty.frame=NSRect(x:0,y:70,width:columns.bounds.width,height:26);columns.addSubview(empty)
            let hint=label("Use Refresh to request the latest workspace list.",size:12,color:.tertiaryLabelColor)
            hint.alignment = .center;hint.frame=NSRect(x:0,y:105,width:columns.bounds.width,height:24);columns.addSubview(hint)
        }
        deck.contentView.scroll(to:NSPoint(x:min(horizontal,max(0,deckWidth-deck.bounds.width)),y:0))
        let hints=label("Drag to move  ·  Drop onto a window to pair  ·  Right-click for actions",size:11,color:.secondaryLabelColor)
        hints.frame=NSRect(x:24,y:height-53,width:width-48,height:18);root.addSubview(hints)
        let keys=label("Tab / arrows Select  ·  ↵ Open  ·  esc Close",size:10,color:.secondaryLabelColor)
        keys.alignment = .right;keys.frame=NSRect(x:width-314,y:height-29,width:290,height:17);root.addSubview(keys)
        status.frame=NSRect(x:24,y:height-30,width:max(80,width-360),height:20);root.addSubview(status)
        for (index,tile) in windowTiles.enumerated() { tile.nextKeyView = index+1 < windowTiles.count ? windowTiles[index+1] : refresh }
        refresh.nextKeyView = windowTiles.first
        if let id=focusedID,let tile=windowTiles.first(where:{$0.ids.first == id}) { panel.makeFirstResponder(tile) }
        panel.initialFirstResponder = windowTiles.first ?? refresh
    }
    func step(from tile: Tile, delta: Int) {
        guard !windowTiles.isEmpty,let index=windowTiles.firstIndex(where:{$0 === tile}) else { return }
        let next=windowTiles[(index+delta+windowTiles.count)%windowTiles.count]
        panel.makeFirstResponder(next);next.scrollToVisible(next.bounds)
        if let scroll=laneScrolls[next.workspace] { scroll.superview?.scrollToVisible(scroll.frame) }
    }
    func tile(_ row:[String:Any],frame:NSRect)->Tile {
        Tile(frame:frame,ids:[row["id"] as! Int],workspace:row["workspace"] as! String,title:row["app"] as? String ?? "Window",subtitle:row["title"] as? String ?? "",icon:icon(row))
    }
    func payload(_ sender:NSDraggingInfo)->[String:Any]? {
        guard !busy,sender.draggingSource is Tile,let data=sender.draggingPasteboard.data(forType:dragType),let p=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],p["session"] as? Int == session,p["version"] as? Int == version else { return nil };return p
    }
    // The linked pair containing this tile's window(s), in displayed order.
    func pairFor(_ ids:[Int])->[String:Any]? {
        guard let first=ids.first else { return nil }
        for pair in model["pairs"] as? [[String:Any]] ?? [] {
            guard let member=pair["ids"] as? [Int],member.contains(first) else { continue }
            if ids.count==2 && member != ids { continue }
            return pair
        }
        return nil
    }
    // Exact member identities captured when a menu opens or a drag begins, so a
    // stale gesture cannot act on a pair that changed underneath it.
    func pairMeta(_ pair:[String:Any])->[String:Any]? {
        guard let ids=pair["ids"] as? [Int],ids.count==2,
              let a=rows.first(where:{$0["id"] as? Int == ids[0]}),let b=rows.first(where:{$0["id"] as? Int == ids[1]}),
              let apid=a["pid"] as? Int,let bpid=b["pid"] as? Int else { return nil }
        return ["a":["id":ids[0],"pid":apid],"b":["id":ids[1],"pid":bpid]]
    }
    func menu(_ ids:[Int],workspace:String)->NSMenu {
        let m=NSMenu();m.autoenablesItems=false;m.delegate=self;menuActions=[]
        // AppKit sends the menu action after menuDidClose. Keep its target
        // alive even if closing the menu applies a queued board refresh, and
        // keep the version/session the menu was opened against.
        let snap:[String:Any]=["session":session,"version":version]
        let pair=pairFor(ids);let meta=pair.flatMap{pairMeta($0)}
        func add(_ title:String,_ run:@escaping ()->Void) { let a=Action(run);menuActions.append(a);let item=NSMenuItem(title:title,action:#selector(Action.invoke),keyEquivalent:"");item.target=a;item.isEnabled = !busy;m.addItem(item) }
        if ids.count==1 { add("Focus window"){self.send("focus",["ids":ids],snapshot:snap)} }
        if ids.count==1 {
            let partners=NSMenu();partners.autoenablesItems=false
            for row in rows where row["workspace"] as? String == workspace {
                guard let id=row["id"] as? Int,id != ids[0] else { continue }
                let a=Action{self.send("pair",["ids":[ids[0],id]],snapshot:snap)};menuActions.append(a)
                let name=(row["app"] as? String ?? "Window")+" — "+String((row["title"] as? String ?? "").prefix(45))
                let item=NSMenuItem(title:name,action:#selector(Action.invoke),keyEquivalent:"");item.target=a;item.isEnabled = !busy;partners.addItem(item)
            }
            if !partners.items.isEmpty { let item=NSMenuItem(title:"Pair with…",action:nil,keyEquivalent:"");item.submenu=partners;m.addItem(item) }
        }
        for space in spaces { if let ws=space["id"] as? String,ws != workspace { add("Move \(ids.count==2 ? "pair" : "window") to \(ws)"){var e:[String:Any]=["ids":ids,"target":ws];if let meta=meta{e["pair"]=meta};self.send("move",e,snapshot:snap)} } }
        if let pair=pair,let meta=meta,let members=pair["ids"] as? [Int] {
            add("Swap positions"){self.send("swap",["ids":members,"pair":meta],snapshot:snap)}
            add("Separate from pair"){self.send("separate",["ids":[ids[0]],"pair":meta],snapshot:snap)}
        }
        return m
    }
    func send(_ action:String,_ extra:[String:Any]=[:],snapshot:[String:Any]?=nil) {
        guard !busy || action=="close" else { return }
        var p=extra;p["action"]=action;p["session"]=snapshot?["session"] ?? session;p["version"]=snapshot?["version"] ?? version
        if p["pair"] == nil, let pair=snapshot?["pair"] { p["pair"]=pair }
        if ["move","pair","separate","swap"].contains(action) { busy=true;status.stringValue="Arranging…" }
        emit(p)
    }
    func receive(_ packet:[String:Any]) {
        if packet["visible"] as? Bool == false { panel?.orderOut(nil) }
        // Focusing the panel produces a new snapshot between mouseDown and
        // mouseDragged. Never replace the drag source out from under AppKit.
        if pointerDown || dragging || menuOpen { queued=packet;return }
        if let new=packet["model"] as? [String:Any], let next=new["version"] as? Int,next != version || new["session"] as? Int != session {
            model=new;version=next;session=new["session"] as? Int ?? 0;busy=new["busy"] as? Bool ?? false;render()
        }
        if let text=packet["status"] as? String { status.stringValue=text }
        if let locked=packet["busy"] as? Bool { busy=locked }
        if packet["visible"] as? Bool == true, !(panel?.isVisible ?? false) { panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
        emit(["action":"ack","version":version,"session":session,"busy":busy,"dragging":dragging])
    }
    func applyQueued() { if let packet=queued { queued=nil;if !busy { receive(packet) } } }
    func menuWillOpen(_ menu:NSMenu) { menuOpen=true }
    func menuDidClose(_ menu:NSMenu) { menuOpen=false;applyQueued() }
    func windowShouldClose(_ sender:NSWindow)->Bool { send("close");return false }
    func windowDidResize(_ notification:Notification) { render() }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let board=Board()
if CommandLine.arguments.contains("--surface-check") {
    testPackets=[];board.start()
    var checks:[[String:Any]]=[]
    for (name,bundle) in [("Finder","com.apple.finder"),("Safari","com.apple.Safari"),("Terminal","com.apple.Terminal")] {
        let running=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first
        let row:[String:Any]=["app":name,"bundle":bundle,"pid":Int(running?.processIdentifier ?? 0)]
        let resolved=board.applicationIcon(row)
        checks.append(["app":name,"resolved":resolved != nil,"source":resolved?.source ?? "fallback"])
    }
    let finder=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.finder").first
    let missingBundle:[String:Any]=["app":"Finder","pid":Int(finder?.processIdentifier ?? 0)]
    let pidFallback=board.applicationIcon(missingBundle)
    // The same PID under a conflicting claimed identity must not display Finder.
    let conflict:[String:Any]=["app":"Unknown","bundle":"local.hangar.invalid-fixture","pid":Int(finder?.processIdentifier ?? 0)]
    let conflictingPIDRejected=board.applicationIcon(conflict) == nil
    testPackets=nil
    emit(["surface":String(describing:type(of:board.panel.contentView!)),
          "opaque":board.panel.isOpaque,"backgroundAlpha":board.panel.backgroundColor.alphaComponent,
          "visible":board.panel.isVisible,"preview":previewMode,
          "reduceTransparency":NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
          "icons":checks,"missingBundlePIDFallback":pidFallback?.source ?? "unavailable",
          "conflictingPIDRejected":conflictingPIDRejected])
    exit(board.panel.isOpaque || !conflictingPIDRejected || checks.contains{$0["resolved"] as? Bool != true} ? 1 : 0)
}
if CommandLine.arguments.contains("--self-test") {
    testPackets=[]
    board.model=["spaces":[["id":"1"],["id":"2"]],"windows":[
        ["id":1,"pid":101,"workspace":"1"],["id":2,"pid":102,"workspace":"1"],["id":3,"pid":103,"workspace":"1"]],
        "pairs":[["ids":[1,2],"workspace":"1"]]]
    var checks=0
    func check(_ value:Bool) { precondition(value); checks+=1 }
    for ids in [[1],[2],[1,2]] {
        board.busy=false;board.version=4;board.session=7
        let menu=board.menu(ids,workspace:"1")
        let swap=menu.items.first{$0.title=="Swap positions"}!
        board.version=5
        (swap.target as! Action).run()
        let packet=testPackets!.last!
        check(packet["ids"] as? [Int] == [1,2] && packet["version"] as? Int == 4 && board.busy)
        board.busy=false
        (menu.items.first{$0.title=="Separate from pair"}!.target as! Action).run()
        check(testPackets!.last!["ids"] as? [Int] == [ids[0]] && testPackets!.last!["pair"] != nil)
    }
    board.busy=false
    check(!board.menu([3],workspace:"1").items.contains{$0.title=="Swap positions" || $0.title=="Separate from pair"})
    let meta=board.pairMeta(board.pairFor([2])!)!
    board.send("move",["ids":[2],"target":"1"],snapshot:["version":4,"session":7,"pair":meta])
    check((testPackets!.last!["pair"] as? [String:Any])?["a"] != nil)
    board.busy=false
    board.send("move",["ids":[3],"target":"1"],snapshot:["version":4,"session":7,"pair":false])
    check(testPackets!.last!["pair"] as? Bool == false)
    // Exercise the keyboard and overflow layout on a hidden native panel.
    board.busy=false;board.start()
    check(!board.panel.isVisible && board.windowTiles.count == 3)
    let first=board.windowTiles[0],second=board.windowTiles[1]
    board.panel.makeFirstResponder(first);board.step(from:first,delta:1)
    check(board.panel.firstResponder === second)
    let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
    second.keyDown(with:enter)
    check(testPackets!.last!["action"] as? String == "focus" && testPackets!.last!["ids"] as? [Int] == second.ids)
    board.model=["spaces":(1...9).map{["id":String($0)]},"windows":[
        ["id":1,"workspace":"1"],["id":2,"workspace":"9"]]]
    board.root.frame.size=NSSize(width:680,height:450);board.render()
    check(board.deckScroll!.documentView!.frame.width > board.deckScroll!.bounds.width)
    check(board.windowTiles.allSatisfy{$0.frame.width >= 220})
    board.step(from:board.windowTiles[0],delta:1)
    check(board.panel.firstResponder === board.windowTiles[1] && board.deckScroll!.contentView.bounds.origin.x > 0)
    for area in [NSRect(x: 20, y: 20, width: 1240, height: 635), NSRect(x: -1900, y: 80, width: 1860, height: 1000), NSRect(x: 0, y: 0, width: 2560, height: 1400)] {
        let content = fitOverviewContent(NSRect(x: 100, y: 100, width: 1100, height: 670), inside: area)
        let frame = NSWindow.frameRect(forContentRect: content, styleMask: overviewStyle)
        check(area.contains(frame))
    }
    for size in [NSSize(width: 680, height: 450), NSSize(width: 1800, height: 950)] {
        board.root.frame.size = size; board.render()
        check(board.deckScroll!.frame.maxY < size.height - 65)
        check(board.windowTiles.allSatisfy { $0.frame.width >= 220 })
    }
    print("\(checks) native overview menu/payload/keyboard/layout checks passed")
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--render-preview"), index+1 < CommandLine.arguments.count {
    if CommandLine.arguments.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
    else if CommandLine.arguments.contains("--light") { app.appearance = NSAppearance(named: .aqua) }
    board.start()
    board.model = ["session": 1, "version": 1, "spaces": [
        ["id": "1", "monitor": "Studio Display", "visible": true], ["id": "2", "monitor": "Mac display", "visible": true],
        ["id": "3", "monitor": "Studio Display"], ["id": "4", "monitor": "Studio Display"]],
        "windows": [
            ["id": 1, "pid": 1, "workspace": "1", "app": "Safari", "bundle": "com.apple.Safari", "title": "A quieter place to work"],
            ["id": 2, "pid": 1, "workspace": "1", "app": "Notes", "bundle": "com.apple.Notes", "title": "Launch notes"],
            ["id": 3, "pid": 1, "workspace": "2", "app": "Finder", "bundle": "com.apple.finder", "title": "Design references"],
            ["id": 4, "pid": 1, "workspace": "2", "app": "Terminal", "bundle": "com.apple.Terminal", "title": "hangar — main"],
            ["id": 5, "pid": 1, "workspace": "3", "app": "Safari", "bundle": "com.apple.Safari", "title": "Weekend reading"]],
        "pairs": [["ids": [1, 2], "workspace": "1"]]]
    if CommandLine.arguments.contains("--empty") { board.model = ["spaces": [], "windows": []] }
    board.status.stringValue = "Ready";board.render()
    do { try writePreview(board.panel.contentView!, to: CommandLine.arguments[index+1]); exit(0) }
    catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
}
DispatchQueue.main.async { board.start() }
DispatchQueue.global(qos:.userInitiated).async {
    while let line=readLine() {
        guard line.utf8.count<2_000_000,let data=line.data(using:.utf8),let packet=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else { continue }
        DispatchQueue.main.async { board.receive(packet) }
    }
    DispatchQueue.main.async { app.terminate(nil) }
}
app.run()
