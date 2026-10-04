import AppKit
import ApplicationServices
import Carbon
import Darwin

@_silgen_name("GetProcessForPID")
@discardableResult
func legacyGetProcessForPID(
    _ pid: pid_t,
    _ psn: UnsafeMutablePointer<ProcessSerialNumber>
) -> OSStatus

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
guard let skyLight = dlopen(skyLightPath, RTLD_LAZY) else {
    fail("cannot load SkyLight")
}
typealias SetFrontWindow = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
) -> CGError
typealias PostEventRecord = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
) -> CGError
typealias MainConnection = @convention(c) () -> UInt32
typealias SetSpaceFront = @convention(c) (
    UInt32, UInt64, ProcessSerialNumber
) -> CGError
guard let setFrontSymbol = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
      let postEventSymbol = dlsym(skyLight, "SLPSPostEventRecordTo"),
      let connectionSymbol = dlsym(skyLight, "CGSMainConnectionID"),
      let setSpaceFrontSymbol = dlsym(skyLight, "SLSSpaceSetFrontPSN") else {
    fail("required SkyLight symbols are unavailable")
}
let setFrontWindow = unsafeBitCast(setFrontSymbol, to: SetFrontWindow.self)
let postEventRecord = unsafeBitCast(postEventSymbol, to: PostEventRecord.self)
let mainConnection = unsafeBitCast(connectionSymbol, to: MainConnection.self)
let setSpaceFront = unsafeBitCast(setSpaceFrontSymbol, to: SetSpaceFront.self)

guard CommandLine.arguments.count >= 3,
      (CommandLine.arguments.count - 3).isMultiple(of: 2),
      let pid = pid_t(CommandLine.arguments[1]),
      let parsedWindowID = UInt32(CommandLine.arguments[2]) else {
    fail("usage: leanmac-window-focus <pid> <window-id> [restore-space-id restore-pid]...")
}

var psn = ProcessSerialNumber()
guard legacyGetProcessForPID(pid, &psn) == noErr else {
    fail("cannot resolve process \(pid)")
}

var windowID = CGWindowID(parsedWindowID)
let frontError = setFrontWindow(&psn, windowID, 0x200) // user-generated, selected window only
guard frontError == .success else {
    fail("front-window failed: \(frontError.rawValue)")
}

// A down-only WindowServer event makes this exact window key without clicking
// its content. The record layout follows the same CGSEvent record AltTab uses.
var record = [UInt8](repeating: 0, count: 0x100)
record[0x04] = 0xf8
record[0x08] = 0x01
record[0x3a] = 0x10
var offContentPoint = CGPoint(x: 300_000, y: 300_000)
withUnsafeBytes(of: &windowID) { source in
    record.withUnsafeMutableBytes { destination in
        destination.baseAddress!.advanced(by: 0x3c)
            .copyMemory(from: source.baseAddress!, byteCount: source.count)
    }
}
withUnsafeBytes(of: &offContentPoint) { source in
    record.withUnsafeMutableBytes { destination in
        destination.baseAddress!.advanced(by: 0x20)
            .copyMemory(from: source.baseAddress!, byteCount: source.count)
    }
}
let keyError = record.withUnsafeMutableBufferPointer {
    postEventRecord(&psn, $0.baseAddress!)
}
guard keyError == .success else {
    fail("make-key failed: \(keyError.rawValue)")
}

let connection = mainConnection()
if CommandLine.arguments.count > 3 {
    for index in stride(from: 3, to: CommandLine.arguments.count, by: 2) {
        guard let spaceID = UInt64(CommandLine.arguments[index]),
              let restorePID = pid_t(CommandLine.arguments[index + 1]) else {
            fail("invalid restore pair")
        }
        var restorePSN = ProcessSerialNumber()
        guard legacyGetProcessForPID(restorePID, &restorePSN) == noErr else {
            fail("cannot resolve restore process \(restorePID)")
        }
        let error = setSpaceFront(connection, spaceID, restorePSN)
        guard error == .success else {
            fail("restore-space failed: \(error.rawValue)")
        }
    }
}
