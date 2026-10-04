import Carbon.HIToolbox
import Foundation

// Secure Input filters ordinary global key event taps. Carbon hotkeys are the
// same narrow mechanism used by AltTab: they keep firing without reading typed
// text. AeroSpace commands run off the event loop so key repeat stays smooth.

private let notificationName = Notification.Name("local.leanmac.hotkeys")
private let signature: OSType = 0x4C4D484B // LMHK
private let commandQueue = DispatchQueue(label: "local.leanmac.hotkeys.aerospace")

private struct Binding {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let action: Action
}

private enum Action {
    case aerospace([[String]])
    case notification(String)
    case picker(String)
}

private var actions: [UInt32: Action] = [:]
private var hotKeyRefs: [EventHotKeyRef] = []
private var pickerIsActive = false
private var optionReleaseTimer: DispatchSourceTimer?

private func post(_ action: String) {
    DistributedNotificationCenter.default().postNotificationName(
        notificationName,
        object: action,
        userInfo: nil,
        deliverImmediately: true
    )
}

private func aerospacePath() -> String? {
    let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

private func runAeroSpace(_ commands: [[String]]) {
    guard let executable = aerospacePath() else {
        NSLog("Hangar hotkeys: aerospace CLI not found")
        return
    }
    commandQueue.async {
        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NSLog("Hangar hotkeys: aerospace %@ failed (%d)", arguments.joined(separator: " "), process.terminationStatus)
                    break
                }
            } catch {
                NSLog("Hangar hotkeys: failed to launch aerospace: %@", error.localizedDescription)
                break
            }
        }
    }
}

private func stopOptionReleaseWatch() {
    optionReleaseTimer?.cancel()
    optionReleaseTimer = nil
}

private func watchForOptionRelease() {
    guard optionReleaseTimer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
    timer.setEventHandler {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if !flags.contains(.maskAlternate) {
            if pickerIsActive { post("picker-confirm") }
            pickerIsActive = false
            stopOptionReleaseWatch()
        }
    }
    optionReleaseTimer = timer
    timer.resume()
}

private func perform(_ action: Action) {
    switch action {
    case let .aerospace(commands):
        runAeroSpace(commands)
    case let .notification(name):
        post(name)
    case let .picker(name):
        pickerIsActive = true
        post(name)
        watchForOptionRelease()
    }
}

private let hotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, let action = actions[hotKeyID.id] else { return status }
    perform(action)
    return noErr
}

private func command(_ arguments: String...) -> Action { .aerospace([arguments]) }

private let workspaceNames: [String] = {
    let selector = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LeanMac/aerospace-profile")
    let profile = (try? String(contentsOf: selector, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return profile == "numbered-study" ? ["1", "2", "3", "4"] : ["W", "B", "S", "M"]
}()

private func workspace(_ index: Int, move: Bool = false) -> Action {
    command(move ? "move-node-to-workspace" : "workspace", workspaceNames[index])
}

private let option = UInt32(optionKey)
private let shift = UInt32(shiftKey)
private let control = UInt32(controlKey)

private let bindings: [Binding] = [
    // Exact-window picker and searchable mouse-button picker.
    Binding(id: 1, keyCode: UInt32(kVK_Tab), modifiers: option, action: .picker("picker-forward")),
    Binding(id: 2, keyCode: UInt32(kVK_Tab), modifiers: option | shift, action: .picker("picker-backward")),
    Binding(id: 3, keyCode: UInt32(kVK_F17), modifiers: 0, action: .notification("picker-search")),

    // Focus and move nodes.
    Binding(id: 10, keyCode: UInt32(kVK_ANSI_H), modifiers: option, action: command("focus", "left")),
    Binding(id: 11, keyCode: UInt32(kVK_ANSI_J), modifiers: option, action: command("focus", "down")),
    Binding(id: 12, keyCode: UInt32(kVK_ANSI_K), modifiers: option, action: command("focus", "up")),
    Binding(id: 13, keyCode: UInt32(kVK_ANSI_L), modifiers: option, action: command("focus", "right")),
    Binding(id: 14, keyCode: UInt32(kVK_ANSI_H), modifiers: option | shift, action: command("move", "left")),
    Binding(id: 15, keyCode: UInt32(kVK_ANSI_J), modifiers: option | shift, action: command("move", "down")),
    Binding(id: 16, keyCode: UInt32(kVK_ANSI_K), modifiers: option | shift, action: command("move", "up")),
    Binding(id: 17, keyCode: UInt32(kVK_ANSI_L), modifiers: option | shift, action: command("move", "right")),

    // Numbered workspaces.
    Binding(id: 20, keyCode: UInt32(kVK_ANSI_1), modifiers: option, action: workspace(0)),
    Binding(id: 21, keyCode: UInt32(kVK_ANSI_2), modifiers: option, action: workspace(1)),
    Binding(id: 22, keyCode: UInt32(kVK_ANSI_3), modifiers: option, action: workspace(2)),
    Binding(id: 23, keyCode: UInt32(kVK_ANSI_4), modifiers: option, action: workspace(3)),
    Binding(id: 24, keyCode: UInt32(kVK_ANSI_1), modifiers: option | shift, action: workspace(0, move: true)),
    Binding(id: 25, keyCode: UInt32(kVK_ANSI_2), modifiers: option | shift, action: workspace(1, move: true)),
    Binding(id: 26, keyCode: UInt32(kVK_ANSI_3), modifiers: option | shift, action: workspace(2, move: true)),
    Binding(id: 27, keyCode: UInt32(kVK_ANSI_4), modifiers: option | shift, action: workspace(3, move: true)),
    Binding(id: 28, keyCode: UInt32(kVK_ANSI_Grave), modifiers: option, action: command("workspace-back-and-forth")),

    // Monitors.
    Binding(id: 30, keyCode: UInt32(kVK_ANSI_Comma), modifiers: option, action: command("focus-monitor", "--wrap-around", "prev")),
    Binding(id: 31, keyCode: UInt32(kVK_ANSI_Period), modifiers: option, action: command("focus-monitor", "--wrap-around", "next")),
    Binding(id: 32, keyCode: UInt32(kVK_ANSI_Comma), modifiers: option | shift, action: command("move-node-to-monitor", "--focus-follows-window", "--wrap-around", "prev")),
    Binding(id: 33, keyCode: UInt32(kVK_ANSI_Period), modifiers: option | shift, action: command("move-node-to-monitor", "--focus-follows-window", "--wrap-around", "next")),

    // Layouts and sizes. Option+? is the keymap; Ctrl+Option+? resets accordion.
    Binding(id: 40, keyCode: UInt32(kVK_ANSI_F), modifiers: option, action: command("fullscreen")),
    Binding(id: 41, keyCode: UInt32(kVK_Space), modifiers: option | shift, action: command("layout", "floating", "tiling")),
    Binding(id: 42, keyCode: UInt32(kVK_ANSI_Slash), modifiers: option, action: .aerospace([
        ["flatten-workspace-tree"], ["layout", "--root", "tiles", "horizontal"], ["balance-sizes"]
    ])),
    Binding(id: 43, keyCode: UInt32(kVK_ANSI_Slash), modifiers: option | shift, action: .notification("keymap")),
    Binding(id: 44, keyCode: UInt32(kVK_ANSI_Slash), modifiers: control | option | shift, action: .aerospace([
        ["flatten-workspace-tree"], ["layout", "--root", "accordion", "horizontal"]
    ])),
    Binding(id: 45, keyCode: UInt32(kVK_ANSI_Minus), modifiers: option, action: command("resize", "smart", "-50")),
    Binding(id: 46, keyCode: UInt32(kVK_ANSI_Equal), modifiers: option, action: command("resize", "smart", "+50")),
    Binding(id: 47, keyCode: UInt32(kVK_ANSI_Equal), modifiers: option | shift, action: command("balance-sizes")),
    Binding(id: 48, keyCode: UInt32(kVK_ANSI_R), modifiers: option | shift, action: command("reload-config")),

    // Windows-style snap zones are implemented by Hammerspoon.
    Binding(id: 50, keyCode: UInt32(kVK_LeftArrow), modifiers: option, action: .notification("snap-left")),
    Binding(id: 51, keyCode: UInt32(kVK_RightArrow), modifiers: option, action: .notification("snap-right")),
    Binding(id: 52, keyCode: UInt32(kVK_UpArrow), modifiers: option, action: .notification("snap-up")),
    Binding(id: 53, keyCode: UInt32(kVK_DownArrow), modifiers: option, action: .notification("snap-down")),

    // MX Master gesture button left/right.
    Binding(id: 60, keyCode: UInt32(kVK_F18), modifiers: 0, action: command("workspace", "--wrap-around", "prev")),
    Binding(id: 61, keyCode: UInt32(kVK_F19), modifiers: 0, action: command("workspace", "--wrap-around", "next")),
]

private func registerHotKeys() -> Bool {
    var eventTypes = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    ]
    var handler: EventHandlerRef?
    let handlerStatus = InstallEventHandler(
        GetApplicationEventTarget(),
        hotKeyHandler,
        eventTypes.count,
        &eventTypes,
        nil,
        &handler
    )
    guard handlerStatus == noErr else {
        NSLog("Hangar hotkeys: could not install Carbon handler (%d)", handlerStatus)
        return false
    }

    var allRegistered = true
    for binding in bindings {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: binding.id)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            actions[binding.id] = binding.action
            hotKeyRefs.append(ref)
        } else {
            allRegistered = false
            NSLog("Hangar hotkeys: registration %u failed (%d)", binding.id, status)
        }
    }
    return allRegistered
}

guard registerHotKeys() else {
    NSLog("Hangar hotkeys: one or more bindings are unavailable")
    exit(2)
}

post("helper-ready")
RunLoop.main.run()
