import AppKit
import ApplicationServices

/// Matches real approval controls, never ordinary chat prose by itself.
enum ComputerUseApprovalCard {
    private static func normalized(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }
    static func isAllow(_ value: String) -> Bool {
        let text = normalized(value)
        return ["允许此对话", "允许本次对话", "allow for this chat", "allow this conversation"].contains { text == $0 || text.hasPrefix($0 + " ") }
    }
    static func isDeny(_ value: String) -> Bool {
        let text = normalized(value)
        return ["拒绝", "deny", "decline"].contains { text == $0 || text.hasPrefix($0 + " ") }
    }
    static func appName(texts: [String], buttons: [String]) -> String? {
        guard buttons.contains(where: isAllow), buttons.contains(where: isDeny) else { return nil }
        for text in texts where text.count <= 160 {
            for pattern in [#"^允许\s*(?:ChatGPT|Codex)\s*使用\s*(.{1,60}?)\s*[?？]$"#,
                            #"(?i)^allow\s+(?:ChatGPT|Codex)\s+to\s+use\s+(.{1,60}?)\s*\?$"#] {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
                return String(name.prefix(32))
            }
        }
        return nil
    }
}

/// Only a currently observed card is authoritative. Acknowledging a reminder
/// does not approve anything; the same visible card is not re-added every poll.
final class ComputerUseApprovalEpisodes {
    private struct Episode { let id: String; var misses: Int; var lastSeen: TimeInterval }
    private var episodes: [String: Episode] = [:]
    let makeID: () -> String
    init(makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) { self.makeID = makeID }
    func update(_ cards: [String: String], complete: Bool, now: TimeInterval) -> [[String: Any]] {
        var events = [[String: Any]]()
        for (key, name) in cards {
            if var old = episodes[key] { old.misses = 0; old.lastSeen = now; episodes[key] = old; continue }
            let item = Episode(id: "desktop-approval:" + makeID(), misses: 0, lastSeen: now)
            episodes[key] = item
            events.append(["action": "desktop_approval", "id": item.id, "active": true, "title": name])
        }
        for key in Array(episodes.keys) where cards[key] == nil {
            guard var old = episodes[key] else { continue }
            if complete { old.misses += 1; episodes[key] = old }
            if old.misses >= 2 || (!complete && now - old.lastSeen > 15) {
                events.append(["action": "desktop_approval", "id": old.id, "active": false])
                episodes.removeValue(forKey: key)
            }
        }
        return events
    }
    func clear() -> [[String: Any]] {
        let events: [[String: Any]] = episodes.values.map { ["action": "desktop_approval", "id": $0.id, "active": false] }
        episodes.removeAll()
        return events
    }
}

/// Opt-in, read-only accessibility compatibility layer. Work never runs on the
/// UI thread. It never activates Codex, clicks controls or reads edit fields.
final class ComputerUseApprovalMonitor {
    static let preference = "ComputerUseApprovalMonitorEnabled"
    var emit: ([String: Any]) -> Void = { _ in }
    var report: (String, Int) -> Void = { _, _ in }
    private let worker = DispatchQueue(label: "local.rico.CodexVoice.approval-read", qos: .utility)
    private let episodes = ComputerUseApprovalEpisodes()
    private var reading = false
    private var generation = 0
    private var wasEnabled = false
    func reset(notify: Bool = true) {
        generation += 1
        let events = episodes.clear()
        if notify { events.forEach(emit) }
    }
    func tick(enabled: Bool) {
        guard enabled else {
            if wasEnabled { reset() }
            wasEnabled = false; report("未开启", 0); return
        }
        wasEnabled = true
        guard AXIsProcessTrusted() else {
            reset(); report("请先允许本应用的辅助功能权限", 0); return
        }
        guard !reading else { return }
        // Bundle identity is fixed; do not inspect unrelated applications.
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").map(\.processIdentifier)
        guard !pids.isEmpty else { reset(); report("等待 Codex 打开", 0); return }
        reading = true; let ticket = generation
        worker.async { [weak self] in
            let result = Self.scan(pids)
            DispatchQueue.main.async {
                guard let self else { return }; self.reading = false
                guard ticket == self.generation, self.wasEnabled else { return }
                self.episodes.update(result.cards, complete: result.complete, now: Date().timeIntervalSince1970).forEach(self.emit)
                self.report(result.complete ? "已开启 · 只识别当前窗口的应用授权" : "正在等待可读取的授权界面", result.cards.count)
            }
        }
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func label(_ element: AXUIElement, valueFirst: Bool = false) -> String {
        let keys = valueFirst ? [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
        for key in keys {
            if let text = attribute(element, key) as? String, !text.isEmpty, text.count <= 160 { return text }
        }
        return ""
    }
    private static func card(_ start: AXUIElement, deadline: TimeInterval) -> String? {
        var parent = start
        for _ in 0..<5 {
            guard Date().timeIntervalSince1970 < deadline,
                  let raw = attribute(parent, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            parent = raw as! AXUIElement
            let role = attribute(parent, kAXRoleAttribute) as? String ?? ""
            if [kAXWindowRole, kAXApplicationRole, "AXWebArea"].contains(role) { return nil }
            var stack = [parent], texts = [String](), buttons = [String](), count = 0
            while let element = stack.popLast(), count < 72, Date().timeIntervalSince1970 < deadline {
                count += 1
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                if role == kAXButtonRole { buttons.append(label(element)) }
                else if role == kAXStaticTextRole { texts.append(label(element, valueFirst: true)) }
                else if [kAXTextAreaRole, kAXTextFieldRole, "AXSecureTextField"].contains(role) { continue }
                stack.append(contentsOf: children(element).suffix(72))
            }
            if let name = ComputerUseApprovalCard.appName(texts: texts, buttons: buttons) { return name }
        }
        return nil
    }
    private static func scan(_ pids: [pid_t]) -> (cards: [String: String], complete: Bool) {
        let deadline = Date().timeIntervalSince1970 + 0.45
        var found = [String: String](), complete = true, visits = 0
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { complete = false; continue }
            for window in windows.prefix(8) {
                let windowKey = "\(pid):\(CFHash(window))"
                var stack = children(window), seen = Set<CFHashCode>()
                // Later children contain the active composer and latest cards.
                while let element = stack.popLast() {
                    if visits >= 1800 || Date().timeIntervalSince1970 >= deadline { complete = false; break }
                    visits += 1
                    guard seen.insert(CFHash(element)).inserted else { continue }
                    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                    if [kAXTextAreaRole, kAXTextFieldRole, "AXSecureTextField"].contains(role) { continue }
                    if role == kAXButtonRole, ComputerUseApprovalCard.isAllow(label(element)),
                       let name = card(element, deadline: deadline) {
                        found[windowKey + ":" + name] = name
                    }
                    stack.append(contentsOf: children(element).suffix(256))
                }
            }
        }
        return (found, complete)
    }
}
