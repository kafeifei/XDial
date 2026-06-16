#!/usr/bin/env swift
// Standalone AX inspector for XDial (fallback when embedded server isn't available)
// Build:  swiftc tools/inspector.swift -o build/xdial-inspector
// Needs:  Terminal/iTerm in System Settings > Privacy > Accessibility

import AppKit
import ApplicationServices
import Foundation

func findXDial() -> pid_t? {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kafeifei.xdial")
    return apps.first?.processIdentifier
}

func str(_ el: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
    return ref as? String
}

func dumpAX(_ el: AXUIElement, depth: Int = 0, maxDepth: Int = 15) -> [String: Any] {
    var d: [String: Any] = [:]

    if let v = str(el, kAXRoleAttribute) { d["role"] = v }
    if let v = str(el, kAXSubroleAttribute) { d["subrole"] = v }
    if let v = str(el, kAXTitleAttribute), !v.isEmpty { d["title"] = v }
    if let v = str(el, kAXDescriptionAttribute), !v.isEmpty { d["description"] = v }
    if let v = str(el, kAXRoleDescriptionAttribute), !v.isEmpty { d["roleDesc"] = v }
    if let v = str(el, kAXHelpAttribute), !v.isEmpty { d["help"] = v }
    if let v = str(el, "AXIdentifier"), !v.isEmpty { d["id"] = v }

    var valRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success, let v = valRef {
        if let s = v as? String { d["value"] = s }
        else if let n = v as? NSNumber { d["value"] = n }
        else { d["value"] = "\(v)" }
    }

    do {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXEnabledAttribute as CFString, &ref) == .success,
           let n = ref as? NSNumber, !n.boolValue { d["enabled"] = false }
    }

    var posRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
       posRef != nil, CFGetTypeID(posRef!) == AXValueGetTypeID() {
        var pt = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
        d["x"] = Int(pt.x); d["y"] = Int(pt.y)
    }
    var szRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef) == .success,
       szRef != nil, CFGetTypeID(szRef!) == AXValueGetTypeID() {
        var sz = CGSize.zero
        AXValueGetValue(szRef as! AXValue, .cgSize, &sz)
        d["w"] = Int(sz.width); d["h"] = Int(sz.height)
    }

    if depth < maxDepth {
        var chRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
           let children = chRef as? [AXUIElement], !children.isEmpty {
            d["children"] = children.map { dumpAX($0, depth: depth + 1, maxDepth: maxDepth) }
        }
    }

    return d
}

func findElement(_ root: AXUIElement, title: String, role: String? = nil, maxDepth: Int = 20) -> AXUIElement? {
    let elTitle = str(root, kAXTitleAttribute) ?? ""
    let elDesc = str(root, kAXDescriptionAttribute) ?? ""
    let elHelp = str(root, kAXHelpAttribute) ?? ""
    let elID = str(root, "AXIdentifier") ?? ""
    let elRole = str(root, kAXRoleAttribute)

    let textMatch = [elTitle, elDesc, elHelp, elID].contains { $0.contains(title) }
    let roleMatch = role == nil || elRole == role
    if textMatch && roleMatch { return root }

    if maxDepth <= 0 { return nil }
    var chRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &chRef) == .success,
          let children = chRef as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findElement(child, title: title, role: role, maxDepth: maxDepth - 1) { return found }
    }
    return nil
}

func printJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

// MARK: - Main

let args = CommandLine.arguments

if args.count < 2 {
    print("""
    XDial AX Inspector
    Usage: xdial-inspector <command> [args...]

    Commands:
      tree [depth]       Dump the full accessibility tree (default depth: 15)
      find <text>        Find elements matching text
      press <title>      Press a button by title
      value <title>      Read an element's value

    Note: Requires Terminal in System Settings > Privacy > Accessibility
    Tip:  The embedded debug server (curl localhost:19876) is easier — use this as fallback
    """)
    exit(0)
}

guard AXIsProcessTrusted() else {
    fputs("Error: This terminal needs Accessibility permission.\n", stderr)
    fputs("Go to: System Settings > Privacy & Security > Accessibility\n", stderr)
    fputs("Add your terminal app (Terminal.app or iTerm) to the list.\n", stderr)
    exit(1)
}

guard let pid = findXDial() else {
    fputs("Error: XDial is not running\n", stderr)
    exit(1)
}

let app = AXUIElementCreateApplication(pid)

switch args[1] {
case "tree":
    let depth = args.count > 2 ? Int(args[2]) ?? 15 : 15
    var result: [String: Any] = ["pid": pid]
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
       let windows = ref as? [AXUIElement] {
        result["windows"] = windows.map { dumpAX($0, maxDepth: depth) }
    }
    if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success {
        result["menuBar"] = dumpAX(ref as! AXUIElement, maxDepth: min(depth, 5))
    }
    if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &ref) == .success {
        result["extrasMenuBar"] = dumpAX(ref as! AXUIElement, maxDepth: min(depth, 5))
    }
    printJSON(result)

case "find":
    guard args.count > 2 else { fputs("Usage: xdial-inspector find <text>\n", stderr); exit(1) }
    let query = args[2]
    var results: [[String: Any]] = []

    func collect(_ el: AXUIElement, path: String, depth: Int) {
        let t = str(el, kAXTitleAttribute) ?? ""
        let d = str(el, kAXDescriptionAttribute) ?? ""
        let h = str(el, kAXHelpAttribute) ?? ""
        let i = str(el, "AXIdentifier") ?? ""
        if [t, d, h, i].contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            var info = dumpAX(el, maxDepth: 0)
            info["path"] = path
            results.append(info)
        }
        if depth > 15 { return }
        var chRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
              let children = chRef as? [AXUIElement] else { return }
        for (idx, child) in children.enumerated() {
            let r = str(child, kAXRoleAttribute) ?? "?"
            collect(child, path: "\(path)/\(r)[\(idx)]", depth: depth + 1)
        }
    }

    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
       let windows = ref as? [AXUIElement] {
        for (i, w) in windows.enumerated() {
            collect(w, path: "window[\(i)]", depth: 0)
        }
    }
    printJSON(["query": query, "count": results.count, "results": results] as [String: Any])

case "press":
    guard args.count > 2 else { fputs("Usage: xdial-inspector press <title>\n", stderr); exit(1) }
    if let el = findElement(app, title: args[2]) {
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { print("OK: pressed \"\(args[2])\"") }
        else { fputs("Error: AXPress failed (code \(r.rawValue))\n", stderr); exit(1) }
    } else {
        fputs("Error: element not found: \"\(args[2])\"\n", stderr)
        exit(1)
    }

case "value":
    guard args.count > 2 else { fputs("Usage: xdial-inspector value <title>\n", stderr); exit(1) }
    if let el = findElement(app, title: args[2]) {
        let info = dumpAX(el, maxDepth: 0)
        printJSON(info)
    } else {
        fputs("Error: element not found: \"\(args[2])\"\n", stderr)
        exit(1)
    }

default:
    fputs("Unknown command: \(args[1])\n", stderr)
    exit(1)
}
