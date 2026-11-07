import AppKit

// Window, frontmost-app and mouse helper for scripted running-app checks. See scripts/app-check/lib.sh.
let args = CommandLine.arguments

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            "usage: wintool winid <pid> | front | click|rclick <x> <y> | move <x> <y> | scroll <x> <y> <dy>\n"
                .utf8))
    exit(1)
}

func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else { usage() }
    return value
}

func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

func moveMouse(to point: CGPoint, button: CGMouseButton = .left) {
    post(
        CGEvent(
            mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
            mouseButton: button))
}

guard args.count > 1 else { usage() }
switch args[1] {
case "winid":
    guard args.count > 2, let pid = Int32(args[2]) else { usage() }
    let list =
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list
    where window[kCGWindowOwnerPID as String] as? Int32 == pid
        && window[kCGWindowLayer as String] as? Int == 0
    {
        guard let number = window[kCGWindowNumber as String] as? Int,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { continue }
        let title = window[kCGWindowName as String] as? String ?? ""
        print(
            number, Int(frame.minX), Int(frame.minY), Int(frame.width), Int(frame.height), title)
    }
case "front":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
case "click", "rclick":
    let point = CGPoint(x: number(2), y: number(3))
    let left = args[1] == "click"
    let button: CGMouseButton = left ? .left : .right
    moveMouse(to: point, button: button)
    usleep(80_000)
    post(
        CGEvent(
            mouseEventSource: nil, mouseType: left ? .leftMouseDown : .rightMouseDown,
            mouseCursorPosition: point, mouseButton: button))
    usleep(50_000)
    post(
        CGEvent(
            mouseEventSource: nil, mouseType: left ? .leftMouseUp : .rightMouseUp,
            mouseCursorPosition: point, mouseButton: button))
case "move":
    moveMouse(to: CGPoint(x: number(2), y: number(3)))
case "scroll":
    let lines = Int32(number(4))
    moveMouse(to: CGPoint(x: number(2), y: number(3)))
    usleep(50_000)
    for _ in 0..<10 {
        post(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
                wheel3: 0))
        usleep(20_000)
    }
default:
    usage()
}
