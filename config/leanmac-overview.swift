import AppKit

// Presentation only. Hammerspoon validates and executes every window operation.
let dragType = NSPasteboard.PasteboardType("local.leanmac.windows")
let accent = NSColor.systemMint
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
final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { board.send("close") }
}
final class Flipped: NSView { override var isFlipped: Bool { true } }

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
        let path=NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 11, yRadius: 11)
        (handle ? accent.withAlphaComponent(0.12) : NSColor.controlBackgroundColor.withAlphaComponent(0.75)).setFill(); path.fill()
        (target ? accent : NSColor.separatorColor.withAlphaComponent(0.45)).setStroke(); path.lineWidth=target ? 2 : 0.5; path.stroke()
        let p=NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
        let x: CGFloat = handle ? 12 : 58
        if let icon=icon { icon.draw(in: NSRect(x: 12, y: 16, width: 34, height: 34), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        (title as NSString).draw(in: NSRect(x:x,y:handle ? 8 : 15,width:bounds.width-x-10,height:20), withAttributes: [.font:NSFont.systemFont(ofSize:handle ? 11 : 12,weight:.semibold),.foregroundColor:handle ? accent : NSColor.labelColor,.paragraphStyle:p])
        if !handle {
            (subtitle as NSString).draw(in: NSRect(x:12,y:60,width:bounds.width-24,height:30),withAttributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:p])
        }
    }
    override func mouseDown(with event: NSEvent) { start=event.locationInWindow; dragged=false; board.pointerDown=true; board.pointer("down",ids) }
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
    override func accessibilityPerformPress() -> Bool { board.send("focus",["ids":ids]); return true }
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
final class Lane: NSView {
    let workspace: String
    var target=false
    override var isFlipped: Bool { true }
    init(frame:NSRect,workspace:String) { self.workspace=workspace; super.init(frame:frame); registerForDraggedTypes([dragType]) }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ rect:NSRect) {
        if target { accent.withAlphaComponent(0.1).setFill(); NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill() }
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
    var root=Flipped()
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
        let f=args.count==4 ? NSRect(x:args[0],y:(NSScreen.screens.first?.frame.maxY ?? 900)-args[1]-args[3],width:args[2],height:args[3]) : NSRect(x:100,y:100,width:1100,height:670)
        panel=Panel(contentRect:f,styleMask:[.titled,.closable,.resizable,.utilityWindow],backing:.buffered,defer:false)
        panel.title="LeanMac Spaces";panel.titleVisibility = .hidden;panel.titlebarAppearsTransparent=true
        panel.minSize=NSSize(width:820,height:470);panel.level = .floating;panel.hidesOnDeactivate=false
        panel.isReleasedWhenClosed=false;panel.delegate=self
        let effect=NSVisualEffectView(frame:NSRect(origin:.zero,size:f.size));effect.material = .popover;effect.blendingMode = .behindWindow;effect.state = .active
        root.frame=effect.bounds;root.autoresizingMask=[.width,.height];effect.addSubview(root);panel.contentView=effect
        render();panel.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        emit(["action":"ready"])
    }
    func icon(_ bundle:String)->NSImage? {
        if let image=icons[bundle] { return image }
        guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else { return nil }
        let image=NSWorkspace.shared.icon(forFile:url.path);image.size=NSSize(width:40,height:40);icons[bundle]=image;return image
    }
    func button(_ title:String, frame:NSRect, _ run:@escaping ()->Void)->NSButton {
        let a=Action(run);actions.append(a)
        let b=NSButton(title:title,target:a,action:#selector(Action.invoke));b.bezelStyle = .rounded;b.controlSize = .small;b.frame=frame;return b
    }
    func render() {
        guard panel != nil else { return }
        let offsets=root.subviews.compactMap { $0 as? NSScrollView }.map { $0.contentView.bounds.origin.y }
        root.subviews.forEach{$0.removeFromSuperview()};actions=[]
        let width=root.bounds.width,height=root.bounds.height
        let heading=label("Spaces",size:22);heading.font = .systemFont(ofSize:22,weight:.semibold);heading.frame=NSRect(x:24,y:12,width:150,height:30);root.addSubview(heading)
        let hint=label("⌥O   ·   Drag to move or pair   ·   Right-click for actions",size:11,color:.secondaryLabelColor);hint.frame=NSRect(x:180,y:23,width:width-310,height:20);root.addSubview(hint)
        root.addSubview(button("Refresh",frame:NSRect(x:width-98,y:13,width:78,height:28)){self.send("refresh")})
        let n=max(1,spaces.count),gap:CGFloat=12,margin:CGFloat=20
        let col=(width-margin*2-gap*CGFloat(n-1))/CGFloat(n)
        for (index,space) in spaces.enumerated() {
            guard let ws=space["id"] as? String else { continue }
            let x=margin+CGFloat(index)*(col+gap)
            let header=button(ws,frame:NSRect(x:x,y:57,width:36,height:30)){self.send("workspace",["target":ws])};header.font = .systemFont(ofSize:18,weight:.semibold);root.addSubview(header)
            let monitor=(space["monitor"] as? String ?? "Display").replacingOccurrences(of:"Built-in Retina Display",with:"Mac display")
            let subtitle=label(monitor,size:10,color:.secondaryLabelColor);subtitle.frame=NSRect(x:x+45,y:57,width:col-48,height:16);root.addSubview(subtitle)
            let members=rows.filter{$0["workspace"] as? String == ws}
            let visible=space["visible"] as? Bool == true
            let state=label((visible ? "●  " : "")+"\(members.count) windows",size:10,color:visible ? accent : .tertiaryLabelColor);state.frame=NSRect(x:x+45,y:73,width:col-48,height:16);root.addSubview(state)
            let scroll=NSScrollView(frame:NSRect(x:x,y:98,width:col,height:height-143));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
            let lane=Lane(frame:NSRect(x:0,y:0,width:col,height:scroll.bounds.height),workspace:ws)
            var y:CGFloat=0;var used=Set<Int>()
            for pair in model["pairs"] as? [[String:Any]] ?? [] where pair["workspace"] as? String == ws {
                guard let ids=pair["ids"] as? [Int],ids.count==2,ids.allSatisfy({ id in members.contains{$0["id"] as? Int == id} }) else { continue }
                let h=Tile(frame:NSRect(x:0,y:y,width:col,height:30),ids:ids,workspace:ws,title:"⠿  Linked pair",handle:true);lane.addSubview(h);y+=33
                for (i,id) in ids.enumerated() {
                    let row=members.first{$0["id"] as? Int == id}!
                    lane.addSubview(tile(row,frame:NSRect(x:CGFloat(i)*(col+6)/2,y:y,width:(col-6)/2,height:96)));used.insert(id)
                };y+=108
            }
            for row in members { guard let id=row["id"] as? Int,!used.contains(id) else { continue };lane.addSubview(tile(row,frame:NSRect(x:0,y:y,width:col,height:96)));y+=105 }
            let empty=label("Drop here",size:11,color:.tertiaryLabelColor);empty.alignment = .center;empty.frame=NSRect(x:0,y:y+16,width:col,height:20);lane.addSubview(empty);y+=80
            lane.frame.size.height=max(y,scroll.bounds.height);scroll.documentView=lane;root.addSubview(scroll)
            if index<offsets.count { scroll.contentView.scroll(to:NSPoint(x:0,y:min(offsets[index],max(0,y-scroll.bounds.height)))) }
        }
        status.frame=NSRect(x:24,y:height-31,width:width-48,height:22);root.addSubview(status)
    }
    func tile(_ row:[String:Any],frame:NSRect)->Tile {
        Tile(frame:frame,ids:[row["id"] as! Int],workspace:row["workspace"] as! String,title:row["app"] as? String ?? "Window",subtitle:row["title"] as? String ?? "",icon:icon(row["bundle"] as? String ?? ""))
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
    print("\(checks) native overview menu/payload checks passed")
    exit(0)
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
