import AppKit
import SwiftUI
import Darwin
import ApplicationServices

final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelHostingView: NSHostingView<VoicePanelView> {
    var measuredHeight: ((CGFloat) -> Void)?
    override func layout() {
        super.layout()
        measuredHeight?(intrinsicContentSize.height)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: ReminderPanel!
    var hosting: PanelHostingView!
    let model = VoicePanelModel()
    var process: Process?
    var input: Pipe?
    var buffer = Data()
    var knownIDs = Set<String>()
    var runtimeURL: URL?
    var clock: Timer?
    var lastStartupCheck = Date.distantPast
    var quitting = false
    var menuAnchorX: CGFloat?
    var menuAnchorBottomY: CGFloat?
    var restartPolicy = ServiceRecoveryPolicy()
    var restartWork: DispatchWorkItem?
    var stoppingForRecovery = false
    var engineStartedAt = Date.distantPast
    var lastSnapshotAt = Date.distantPast
    var healthySince: Date?
    var engineGroup: pid_t?
    var sleeping = false
    var previousApplication:NSRunningApplication?
    var outsideMouseMonitor:Any?
    var menuTrackingDepth=0
    var menuObservers:[NSObjectProtocol]=[]
    lazy var passport = PassportLink { [weak self] event in self?.send(event) }
    var approvalDiagnosticMarker = ""
    lazy var computerApprovals: ComputerUseApprovalMonitor = {
        let monitor = ComputerUseApprovalMonitor()
        monitor.emit = { [weak self] in self?.send($0) }
        monitor.report = { [weak self] state, count in
            guard let self else { return }
            if self.model.computerApprovalStatus != state { self.model.computerApprovalStatus = state }
            let marker = "\(state)|\(count)|\(self.model.computerApprovalEnabled)"
            guard marker != self.approvalDiagnosticMarker else { return }
            self.approvalDiagnosticMarker = marker
            let report: [String: Any] = ["at": Date().timeIntervalSince1970, "enabled": self.model.computerApprovalEnabled, "state": state, "visibleCards": count]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                let path = AppPaths.runtime.appendingPathComponent("computer-use-approval-state.json")
                try? data.write(to: path, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            }
        }
        return monitor
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? AppPaths.identifier).count > 1 {
            NSApp.terminate(nil); return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Codex 语音提醒")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleWindow)
        statusItem.button?.toolTip = "Codex 语音提醒 · 点此打开控制面板"
        model.action = { [weak self] in self?.send($0) }
        model.changeStartup = { [weak self] in self?.setStartup($0) }
        model.hide = { [weak self] in self?.hidePanel("manual-hide") }
        model.retry = { [weak self] in self?.manualReconnect() }
        model.setupPassport = { [weak self] in self?.passport.dictation.showSetup() }
        model.computerApprovalEnabled = UserDefaults.standard.bool(forKey: ComputerUseApprovalMonitor.preference)
        model.changeComputerApproval = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: ComputerUseApprovalMonitor.preference)
            self?.model.computerApprovalEnabled = enabled
            self?.computerApprovals.reset()
        }
        model.openApprovalAccess = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
        model.connectCodex = { [weak self] in self?.installConnection() }
        model.maximumListHeight = max(110, min(340, (NSScreen.main?.visibleFrame.height ?? 900) - 520))
        model.maximumSettingsHeight = max(160, min(540, (NSScreen.main?.visibleFrame.height ?? 900) - 190))
        model.maximumMainContentHeight=max(180,(NSScreen.main?.visibleFrame.height ?? 900)-153)
        buildWindow()
        menuObservers=[
            NotificationCenter.default.addObserver(forName:NSMenu.didBeginTrackingNotification,object:nil,queue:.main) {[weak self] _ in self?.menuTrackingDepth += 1},
            NotificationCenter.default.addObserver(forName:NSMenu.didEndTrackingNotification,object:nil,queue:.main) {[weak self] _ in guard let self else {return};self.menuTrackingDepth=max(0,self.menuTrackingDepth-1)}
        ]
        startEngine()
        refreshClock()
        refreshConnection()
        if !CommandLine.arguments.contains("--background") { showWindow() }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshClock()
            self.computerApprovals.tick(enabled: self.model.computerApprovalEnabled && self.model.enabled && self.model.connected && !self.sleeping && !self.quitting)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(frontApplicationChanged),name:NSWorkspace.didActivateApplicationNotification,object:nil)
    }

    func buildWindow() {
        // Interactive settings use ordinary AppKit activation and input focus.
        // A nonactivating key panel can strand TSM focus during Caps Lock IME
        // switching on macOS 27. Automatic reminders still only order forward.
        window = ReminderPanel(contentRect: NSRect(x: 0, y: 0, width: PanelChrome.width, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "Codex 语音提醒"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        hosting = PanelHostingView(rootView: VoicePanelView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.measuredHeight = { [weak self] height in DispatchQueue.main.async { self?.resizePanel(height) } }
        window.contentView = hosting
        window.center()
    }

    func resizePanel(_ proposed: CGFloat) {
        guard let window, proposed.isFinite, proposed > 100 else { return }
        let screen = statusItem.button?.window?.screen ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = min(ceil(proposed), visible.height - 24)
        guard abs(window.frame.height - height) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y = max(visible.minY + 12, frame.maxY - height)
        frame.size = NSSize(width: PanelChrome.width, height: height)
        window.setFrame(frame, display: true)
        positionPanel()
        window.invalidateShadow()
        recordPanelState("content-resized")
    }

    func positionPanel() {
        guard let button = statusItem.button, let barWindow = button.window else {
            if menuAnchorX == nil { window.center() }
            return
        }
        let buttonRect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
        let image = imageRect.width > 0 ? barWindow.convertToScreen(button.convert(imageRect, to: nil)) : buttonRect
        let anchor = CGRect(x: image.midX - 1, y: buttonRect.minY, width: 2, height: buttonRect.height)
        let screen = barWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let listHeight = max(110, min(340, visible.height - 520))
        let settingsHeight = max(160, min(540, visible.height - 190))
        let mainHeight=max(180,visible.height-153)
        if abs(model.maximumListHeight - listHeight) > 0.5 { model.maximumListHeight = listHeight }
        if abs(model.maximumSettingsHeight - settingsHeight) > 0.5 { model.maximumSettingsHeight = settingsHeight }
        if abs(model.maximumMainContentHeight-mainHeight)>0.5 {model.maximumMainContentHeight=mainHeight}
        if window.frame.height > visible.height - 24 {
            var frame = window.frame; frame.size.height = visible.height - 24
            window.setFrame(frame, display: true)
        }
        let placement = PanelChrome.placement(size: window.frame.size, anchor: anchor, visible: visible)
        let moved = abs(window.frame.minX - placement.origin.x) > 0.25 || abs(window.frame.minY - placement.origin.y) > 0.25
        menuAnchorX = anchor.midX
        menuAnchorBottomY = min(anchor.minY, visible.maxY)
        if moved {
            window.setFrameOrigin(placement.origin)
        }
        let arrowX = min(max(anchor.midX - window.frame.minX, 2), window.frame.width - 2)
        let arrowChanged = abs(model.panelArrowX - arrowX) > 0.25
        if arrowChanged { model.panelArrowX = arrowX }
        if arrowChanged || moved { window.invalidateShadow(); recordPanelState("anchor-adjusted") }
    }

    func startEngine() {
        computerApprovals.reset(notify: false)
        guard !quitting else { return }
        guard process?.isRunning != true else { return }
        do { try AppPaths.prepare() }
        catch { model.serviceError = error.localizedDescription; return }
        runtimeURL = AppPaths.runtime
        model.serviceError = "正在启动提醒服务…"
        model.serviceRecovering = true
        let p = Process()
        p.executableURL = AppPaths.python
        p.environment = AppPaths.environment
        p.arguments = ["-s", AppPaths.resources.appendingPathComponent("voice_engine.py").path, "--state-dir", AppPaths.runtime.path, "--codex-dir", AppPaths.codexHome.path, "--usage"]
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        p.standardInput = inputPipe; p.standardOutput = outputPipe; p.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            DispatchQueue.main.async { if let self, let p, self.process === p { self.receive(chunk) } }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        p.terminationHandler = { [weak self] stopped in
            DispatchQueue.main.async {
                guard let self, self.process === stopped, !self.quitting else { return }
                self.cleanupEngineGroup(stopped)
                if !self.stoppingForRecovery { self.scheduleRecovery("提醒服务意外停止") }
            }
        }
        do {
            try p.run(); process = p; input = inputPipe; buffer = Data()
            engineStartedAt = Date(); lastSnapshotAt = .distantPast; healthySince = nil; engineGroup = nil
        } catch { scheduleRecovery("提醒服务启动失败") }
    }

    func cleanupEngineGroup(_ stopped: Process) {
        if let group = engineGroup, group > 0, group == stopped.processIdentifier { _ = Darwin.kill(-group, SIGTERM) }
        engineGroup = nil
    }

    func scheduleRecovery(_ reason: String) {
        guard !quitting else { return }
        restartWork?.cancel()
        healthySince = nil
        guard let delay = restartPolicy.nextDelay(at: Date()) else {
            stoppingForRecovery = process?.isRunning == true
            if let old = process, old.isRunning {
                send(["action":"quit"])
                old.terminate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    if old.isRunning {
                        if self?.engineGroup == old.processIdentifier { _ = Darwin.kill(-old.processIdentifier, SIGKILL) }
                        else { _ = Darwin.kill(old.processIdentifier, SIGKILL) }
                    }
                }
            }
            model.serviceRecovering = false
            model.serviceError = "连续恢复失败，请点击「重新连接」再试。"
            updateStatusItem(); recordPanelState("service-recovery-limit")
            return
        }
        model.serviceRecovering = true
        model.serviceError = reason + "，正在自动恢复…"
        let old = process
        let wasRunning = old?.isRunning == true
        stoppingForRecovery = true
        if wasRunning, let old {
            send(["action":"quit"])
            try? input?.fileHandleForWriting.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if old.isRunning { old.terminate() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if old.isRunning {
                    if self?.engineGroup == old.processIdentifier { _ = Darwin.kill(-old.processIdentifier, SIGKILL) }
                    else { _ = Darwin.kill(old.processIdentifier, SIGKILL) }
                }
            }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.quitting else { return }
            self.restartWork = nil
            self.stoppingForRecovery = false
            if self.process?.isRunning == true { self.scheduleRecovery("提醒服务尚未停止"); return }
            self.startEngine()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, wasRunning ? 5 : 0), execute: work)
        updateStatusItem(); recordPanelState("service-recovering")
    }

    func manualReconnect() {
        guard !quitting else { return }
        restartPolicy.reset(); restartWork?.cancel(); restartWork = nil
        if process?.isRunning == true { scheduleRecovery("正在重新连接") }
        else { stoppingForRecovery = false; startEngine() }
    }

    @objc func willSleep() {
        computerApprovals.reset()
        passport.dictation.reset()
        sleeping = true
        send(["action":"prepare_sleep"])
    }
    @objc func didWake() {
        guard !quitting else { return }
        sleeping = false
        lastSnapshotAt = Date(); engineStartedAt = Date()
        if process?.isRunning == true { send(["action":"wake"]) }
        else if restartWork == nil { manualReconnect() }
    }

    func send(_ event: [String: Any]) {
        if let action = event["action"] as? String, ["ack", "ack_all", "resolve", "snooze"].contains(action) {
            do {
                let folder = AppPaths.runtime.appendingPathComponent("inbox", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
                var payload = event; payload["sentAt"] = Date().timeIntervalSince1970
                if action == "ack_all" { payload["ids"] = Array(knownIDs) }
                let data = try JSONSerialization.data(withJSONObject: payload)
                let path = folder.appendingPathComponent("panel-" + UUID().uuidString + ".json")
                try data.write(to: path, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: path.path)
            } catch { model.serviceError = "操作暂未记录，请在服务恢复后再试。" }
            return
        }
        guard let input, let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        do { try input.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { model.serviceError = "服务连接已断开，请重新连接。" }
        // A sound test started from Settings should show its acknowledgement.
        if event["action"] as? String == "test" { model.settingsOpen = false; model.speechSettingsOpen = false; model.pauseDurationOpen = false; model.usageOpen = false; model.rulesOpen = false; model.quietHoursOpen = false }
    }

    func receive(_ data: Data) {
        buffer.append(data)
        while let index = buffer.firstIndex(of: 10) {
            let line = buffer[..<index]
            buffer.removeSubrange(...index)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let command = value["passportCommand"] as? [String: Any] {
                passport.command(command)
                continue
            }
            if let error = value["error"] as? String { model.serviceError = error; continue }
            let alerts = (value["alerts"] as? [[String: Any]] ?? []).compactMap(VoiceAlert.init)
            let ids = Set(alerts.map(\.id))
            let changed = ids != knownIDs
            let finishedAll = !knownIDs.isEmpty && ids.isEmpty
            let hasNew = !ids.subtracting(knownIDs).isEmpty
            if let removed = model.alerts.first(where: { !ids.contains($0.id) }) { model.recentTitle = removed.title }
            knownIDs = ids
            if changed { model.listContentHeight = CGFloat(alerts.count) * 148 + CGFloat(max(0, alerts.count - 1)) * 9 + 14 }
            model.snapshot = value
            passport.update(value)
            model.serviceError = nil
            model.serviceRecovering = false
            lastSnapshotAt = Date()
            if healthySince == nil { healthySince = Date(); recordPanelState("service-restored") }
            if let service = value["service"] as? [String: Any], let pid = service["pid"] as? Int32,
               let group = service["processGroup"] as? Int32, pid == process?.processIdentifier, pid == group { engineGroup = group }
            if hasNew {
                if !window.isVisible && !model.devicePickerOpen { model.passportSettingsOpen=false; model.settingsOpen = false; model.speechSettingsOpen = false; model.pauseDurationOpen = false; model.usageOpen = false; model.rulesOpen = false; model.quietHoursOpen = false }
                if !window.isVisible { positionPanel() }
                window.orderFrontRegardless()
                beginOutsideMouseMonitoring()
            }
            refreshClock()
            if finishedAll && !model.passportSettingsOpen && !model.speechSettingsOpen && !model.pauseDurationOpen && !model.usageOpen && !model.rulesOpen && !model.quietHoursOpen { model.settingsOpen = false; model.devicePickerOpen = false; hidePanel("all-handled-auto") }
            if changed { recordPanelState(finishedAll ? "all-handled" : hasNew ? "new-reminder" : "pending-updated") }
        }
    }

    func refreshClock() {
        model.now = Date().timeIntervalSince1970
        statusItem.button?.image = NSImage(systemSymbolName: model.enabled ? "waveform" : "bell.slash", accessibilityDescription: model.enabled ? "语音提醒已开启" : "语音提醒已关闭")
        updateStatusItem()
        if !sleeping && !stoppingForRecovery && restartWork == nil && process?.isRunning == true {
            let reference = lastSnapshotAt == .distantPast ? engineStartedAt : lastSnapshotAt
            let limit: TimeInterval = lastSnapshotAt == .distantPast ? 30 : 20
            if Date().timeIntervalSince(reference) > limit { scheduleRecovery("提醒服务长时间未响应") }
            if let healthySince, Date().timeIntervalSince(healthySince) > 60 { restartPolicy.reset() }
        }
        if Date().timeIntervalSince(lastStartupCheck) > 30 {
            model.startupEnabled = LoginStartup.status()["enabled"] as? Bool ?? false
            lastStartupCheck = Date()
        }
        if window?.isVisible == true { positionPanel() }
    }

    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let usage = model.usage
        let percentage = model.serviceError == nil ? usage.percentage : "—"
        let suffix = model.serviceError != nil ? " · !" : model.alerts.isEmpty ? "" : " · \(model.alerts.count)"
        let title = " \(percentage)" + suffix
        if button.title != title {
            button.title = title
            if window != nil { recordPanelState("menu-updated") }
        }
        button.toolTip = "Codex 剩余用量 \(percentage) · \(usage.updateNote)\n\(model.alerts.count) 件待处理 · 点此打开控制面板"
        button.setAccessibilityLabel("Codex 语音提醒，剩余用量 \(percentage)，\(model.alerts.count) 件待处理")
    }

    func setStartup(_ enabled: Bool) {
        do {
            try LoginStartup.setEnabled(enabled)
            lastStartupCheck = .distantPast
            refreshClock()
        } catch {
            let alert = NSAlert(); alert.messageText = "未能更新登录自启"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "知道了"); alert.runModal()
        }
    }

    func refreshConnection() {
        let status = CodexConnection.run("--status")
        model.connectionConfigured = status["configured"] as? Bool ?? false
        model.connectionMessage = status["error"] as? String ?? (model.connectionConfigured ? "观察器已安装；信任状态请在 Codex 中检查" : "连接后增加审批与提问提醒")
    }
    func installConnection() {
        let alert = NSAlert()
        alert.messageText = "连接 Codex 提醒"
        alert.informativeText = "将注册5个本地观察器，用于观察提问、权限请求、工具结束、你的回复和中断。它们只传递提醒元数据，不联网、不替你作审批决定。\n\n安装后仍需你在 Codex 的 /hooks 中审阅并信任这些观察器。现有配置会备份，其他观察器与审批设置保留。"
        alert.addButton(withTitle: "安装连接"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = CodexConnection.run("--install")
        refreshConnection()
        model.connectionMessage = result["error"] as? String ?? result["message"] as? String ?? "请在 Codex 中检查连接。"
    }

    func recordPanelState(_ reason: String) {
        guard let runtimeURL else { return }
        var state: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier, "visible": window.isVisible,"keyWindow":window.isKeyWindow,"appActive":NSApp.isActive,"menuTrackingDepth":menuTrackingDepth, "pending": knownIDs.count, "reason": reason, "settingsOpen": model.settingsOpen, "menuTitle": statusItem.button?.title ?? "", "width": window.frame.width, "height": window.frame.height, "arrowX": model.panelArrowX, "arrowTipScreenX": window.frame.minX + model.panelArrowX]
        if let menuAnchorX { state["menuAnchorX"] = menuAnchorX; state["arrowAlignmentError"] = abs(window.frame.minX + model.panelArrowX - menuAnchorX) }
        if let menuAnchorBottomY { state["menuGap"] = menuAnchorBottomY - window.frame.maxY }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        try? data.write(to: runtimeURL.appendingPathComponent("panel-state.json"), options: .atomic)
    }
    func hidePanel(_ reason: String,restoreFocus:Bool=true) {
        endOutsideMouseMonitoring()
        window.endEditing(for:nil)
        window.resignKey()
        window.orderOut(nil)
        if restoreFocus && NSApp.isActive { previousApplication?.activate(options:[]) }
        previousApplication=nil
        recordPanelState(reason)
    }
    func beginOutsideMouseMonitoring() {
        guard outsideMouseMonitor==nil else {return}
        // Mouse-only and only while visible: no key capture or event storage.
        outsideMouseMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) {[weak self] _ in
            guard let self,!self.quitting,self.window.isVisible,self.menuTrackingDepth==0 else {return}
            // Input-method candidate windows can receive a click while our
            // field still owns key focus; let the input system handle those.
            if !NSApp.isActive || !self.window.isKeyWindow {self.hidePanel("outside-click",restoreFocus:false)}
        }
    }
    func endOutsideMouseMonitoring() {
        if let monitor=outsideMouseMonitor {NSEvent.removeMonitor(monitor);outsideMouseMonitor=nil}
    }
    func applicationDidResignActive(_ notification:Notification) {
        guard !quitting,window?.isVisible==true else {return}
        hidePanel("application-deactivated",restoreFocus:false)
    }
    @objc func frontApplicationChanged(_ notification:Notification) {
        guard !quitting,!NSApp.isActive,window?.isVisible==true,
              let app=notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {return}
        hidePanel("other-app-activated",restoreFocus:false)
    }
    func windowDidResignKey(_ notification:Notification) {
        guard notification.object as? NSWindow === window else {return}
        DispatchQueue.main.async {[weak self] in
            guard let self,!self.quitting,self.window.isVisible,self.menuTrackingDepth==0,self.window.attachedSheet==nil else {return}
            if !NSApp.isActive || (NSApp.keyWindow != nil && NSApp.keyWindow !== self.window) {self.hidePanel("panel-focus-lost",restoreFocus:false)}
        }
    }
    @objc func toggleWindow() { window.isVisible ? hidePanel("manual-hide") : showWindow() }
    func showWindow() {
        if let front=NSWorkspace.shared.frontmostApplication,front.processIdentifier != ProcessInfo.processInfo.processIdentifier {previousApplication=front}
        resizePanel(hosting.fittingSize.height)
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        beginOutsideMouseMonitoring()
        recordPanelState("manual-open")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel("manual-hide"); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        computerApprovals.reset()
        quitting = true
        endOutsideMouseMonitoring()
        menuObservers.forEach {NotificationCenter.default.removeObserver($0)}
        menuObservers=[]
        passport.stop()
        clock?.invalidate()
        restartWork?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        send(["action":"quit"])
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
            _ = Darwin.kill(process.processIdentifier, SIGCONT)
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning {
                if engineGroup == process.processIdentifier { _ = Darwin.kill(-process.processIdentifier, SIGKILL) }
                else { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
