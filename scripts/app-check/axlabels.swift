import AppKit

// Prints role, screen position, description and help of every accessibility element of a process that has
// either one: axlabels <pid> [max-x]. See scripts/app-check/lib.sh.
let args = CommandLine.arguments
guard args.count > 1, let pid = pid_t(args[1]) else {
    FileHandle.standardError.write(Data("usage: axlabels <pid> [max-x]\n".utf8))
    exit(1)
}
let maxX = args.count > 2 ? Double(args[2]) ?? 10000 : 10000

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ object: AnyObject?) -> String? {
    if let string = object as? String { return string }
    if let attributed = object as? NSAttributedString { return attributed.string }
    return nil
}

func walk(_ element: AXUIElement, _ depth: Int) {
    guard depth < 25 else { return }
    var position = CGPoint.zero
    if let raw = attribute(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
        AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &position)
    }
    let role = string(attribute(element, kAXRoleAttribute)) ?? ""
    let description =
        string(attribute(element, kAXDescriptionAttribute))
        ?? string(attribute(element, "AXAttributedDescription")) ?? ""
    let help = string(attribute(element, kAXHelpAttribute)) ?? ""
    if position.x < maxX, !(description.isEmpty && help.isEmpty) {
        print("\(role) @\(Int(position.x)),\(Int(position.y)) d=\(description) h=\(help)")
    }
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        walk(child, depth + 1)
    }
}

walk(AXUIElementCreateApplication(pid), 0)
