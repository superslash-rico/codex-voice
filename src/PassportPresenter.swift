import AppKit
import ApplicationServices

enum PresentationTarget: String, CaseIterable {
    case automatic, powerpoint, keynote, wps
    var name: String {
        switch self {
        case .automatic: return "自动识别"
        case .powerpoint: return "PowerPoint"
        case .keynote: return "Keynote"
        case .wps: return "WPS"
        }
    }
    var code: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func application(_ bundle: String?) -> Self? {
        switch bundle {
        case "com.microsoft.Powerpoint": return .powerpoint
        case "com.apple.iWork.Keynote": return .keynote
        case "com.kingsoft.wpsoffice.mac": return .wps
        default: return nil
        }
    }
}

struct PresentationContext {
    var connected = false
    var quietAcknowledged = false
    var permission = false
    var frontBundle: String?
    var inputIdle = true
}

/// Session and sequence checks are independent of the keyboard event sender.
/// There is no retry queue: a late/repeated request must never turn another page.
final class PassportPresenter {
    private(set) var enabled = false
    private(set) var session = ""
    private(set) var supported = false
    private var lastSequence = 0
    private var lastStep = -Double.infinity
    private var leases: [String: Double] = [:]
    var target: PresentationTarget = .automatic
    var changed: () -> Void = {}

    func hello(supported: Bool, session: String) {
        let valid = session.count == 16 && session.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        if self.session != session || !supported || !valid { reset() }
        self.supported = supported && valid
        self.session = self.supported ? session : ""
    }
    func reset() {
        let wasEnabled = enabled
        enabled = false; supported = false; session = ""; lastSequence = 0; lastStep = -.infinity
        leases = [:]
        if wasEnabled { changed() }
    }
    @discardableResult func setEnabled(_ value: Bool, context: PresentationContext) -> Bool {
        guard !value || (supported && context.connected && context.inputIdle) else { return false }
        if enabled != value { enabled = value; changed() }
        return true
    }
    func matchingTarget(_ context: PresentationContext) -> PresentationTarget? {
        guard let front = PresentationTarget.application(context.frontBundle), target == .automatic || target == front else { return nil }
        return front
    }
    /// Codes are shared with the firmware: ready, wrong focus, permissions, preparing.
    func status(_ context: PresentationContext) -> Int {
        if !context.connected || !context.quietAcknowledged || !context.inputIdle { return 3 }
        if !context.permission { return 2 }
        return matchingTarget(context) == nil ? 1 : 0
    }
    func state(_ context: PresentationContext, now: Double) -> [String: Any] {
        leases = leases.filter { now - $0.value >= 0 && now - $0.value <= 2.5 }
        while leases.count >= 16, let oldest = leases.min(by: { $0.value < $1.value })?.key { leases.removeValue(forKey:oldest) }
        let lease = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
        leases[lease] = now
        return ["presenterSupported": true, "presenter": enabled, "presenterLease": lease,
         "presenterReady": enabled && status(context) == 0,
         "presenterStatus": status(context),
         "presenterTarget": (matchingTarget(context) ?? target).code]
    }
    /// The sequence is consumed before validation of focus/permissions, so it cannot
    /// be replayed later after the user switches applications or grants access.
    @discardableResult func receive(_ frame: [String: Any], epoch: String, context: PresentationContext,
                                   now: Double, sendKey: (Bool, PresentationTarget) -> Bool) -> Bool {
        guard supported, context.connected, frame["epoch"] as? String == epoch,
              frame["session"] as? String == session,
              let lease = frame["lease"] as? String, let issued = leases[lease], now >= issued, now - issued <= 2.5,
              let sequence = frame["seq"] as? NSNumber, CFGetTypeID(sequence) != CFBooleanGetTypeID(),
              sequence.doubleValue == Double(sequence.intValue), (1...Int(Int32.max)).contains(sequence.intValue),
              sequence.intValue > lastSequence, let op = frame["op"] as? String,
              ["enable", "disable", "previous", "next"].contains(op) else { return false }
        lastSequence = sequence.intValue
        if op == "enable" || op == "disable" { return setEnabled(op == "enable", context: context) }
        guard enabled, status(context) == 0, now - lastStep >= 0.12, let app = matchingTarget(context) else { return false }
        lastStep = now
        return sendKey(op == "next", app)
    }
}

enum PresentationKeyboard {
    /// Recheck the foreground application immediately before posting a complete
    /// key pair. No activation, clipboard, text-field access or global key listener.
    static func send(next: Bool, target: PresentationTarget) -> Bool {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(),
              PresentationTarget.application(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) == target,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: next ? 124 : 123, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: next ? 124 : 123, keyDown: false) else { return false }
        down.flags = []; up.flags = []
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true // Event delivery is not a claim that the slide changed.
    }
}
