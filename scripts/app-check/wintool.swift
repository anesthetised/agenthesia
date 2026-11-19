import AppKit

// Window, frontmost-app and mouse helper for scripted running-app checks. See scripts/app-check/lib.sh.
let args = CommandLine.arguments

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            ("usage: wintool winid <pid> | front | click|rclick <x> <y> | drag <x> <y> <x2> <y2> | move <x> <y>"
                + " | scroll <x> <y> <lines> [events] [interval-ms] | gesture <x> <y> <points> <events> [interval-ms]\n")
                .utf8))
    exit(1)
}

func number(_ index: Int) -> Double {
    guard index < args.count, let value = Double(args[index]) else { usage() }
    return value
}

func post(_ event: CGEvent?) { event?.post(tap: .cghidEventTap) }

/// With `WINTOOL_TARGET` set to a process identifier, `scroll` and `gesture` exit with status 2 as soon as the frontmost
/// window under the pointer is not that process's, checking every 100 ms, so a burst never reaches another app.
let target = ProcessInfo.processInfo.environment["WINTOOL_TARGET"].flatMap { Int32($0) }

func checkTarget(at point: CGPoint, lastCheck: inout UInt64) {
    guard let target else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now - lastCheck >= 100_000_000 else { return }
    lastCheck = now
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let front = list.first { window in
        guard window[kCGWindowLayer as String] as? Int == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return false }
        return frame.contains(point)
    }
    guard front?[kCGWindowOwnerPID as String] as? Int32 == target else {
        FileHandle.standardError.write(Data("ABORT: process \(target)'s window is no longer under the pointer\n".utf8))
        exit(2)
    }
}

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
case "drag":
    let from = CGPoint(x: number(2), y: number(3))
    let to = CGPoint(x: number(4), y: number(5))
    moveMouse(to: from)
    usleep(80_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
    for step in 1...20 {
        usleep(15_000)
        let t = Double(step) / 20
        let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
    }
    usleep(50_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
case "move":
    moveMouse(to: CGPoint(x: number(2), y: number(3)))
case "scroll":
    // A mouse wheel: events of `lines` lines without phases, 10 events 20 ms apart unless given. Positive is up.
    let lines = Int32(number(4))
    let events = args.count > 5 ? Int(number(5)) : 10
    let interval = useconds_t(args.count > 6 ? number(6) * 1000 : 20_000)
    let point = CGPoint(x: number(2), y: number(3))
    moveMouse(to: point)
    usleep(50_000)
    var lastCheck: UInt64 = 0
    for _ in 0..<events {
        checkTarget(at: point, lastCheck: &lastCheck)
        post(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0,
                wheel3: 0))
        usleep(interval)
    }
case "gesture":
    // A trackpad drag without momentum: `events` continuous events of `points` points with the phases of a gesture
    // (began, changed, ended), 8 ms apart unless given. Positive is up.
    let points = Int32(number(4))
    let events = Int(number(5))
    let interval = useconds_t(args.count > 6 ? number(6) * 1000 : 8_000)
    let point = CGPoint(x: number(2), y: number(3))
    moveMouse(to: point)
    usleep(50_000)
    var lastCheck: UInt64 = 0
    for index in 0...events {
        // Not before the last event, which ends the gesture.
        if index < events { checkTarget(at: point, lastCheck: &lastCheck) }
        let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: index < events ? points : 0,
            wheel2: 0, wheel3: 0)
        // kCGScrollPhaseBegan, Changed and Ended.
        event?.setIntegerValueField(.scrollWheelEventScrollPhase, value: index == 0 ? 1 : index < events ? 2 : 4)
        post(event)
        usleep(interval)
    }
default:
    usage()
}
