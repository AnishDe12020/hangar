import AppKit

// Disposable windows only. Closing stdin exits this process and all its windows.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var windows: [NSWindow] = []
func report() {
    let rows = windows.map { window in
        ["id": window.windowNumber, "title": window.title,
         "x": window.frame.minX, "y": window.frame.minY,
         "w": window.frame.width, "h": window.frame.height] as [String: Any]
    }
    let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}
DispatchQueue.main.async {
    for index in 1...5 {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 360, height: 280),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "LeanMac pair regression \(index)"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Disposable regression window \(index)")
        label.frame = NSRect(x: 25, y: 100, width: 310, height: 24)
        window.contentView?.addSubview(label)
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
    app.activate(ignoringOtherApps: true)
    report()
}
DispatchQueue.global().async {
    while let command = readLine() {
        DispatchQueue.main.async {
            if command == "frames" { report() }
        }
    }
    DispatchQueue.main.async { app.terminate(nil) }
}
app.run()
