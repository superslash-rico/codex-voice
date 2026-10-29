import AppKit
import SwiftUI

enum VoiceTheme {
    static func color(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = color(0xf5f5f7, 0x1c1c1e)
    static let paper = color(0xffffff, 0x2c2c2e)
    static let ink = Color(nsColor:.labelColor)
    static let secondary = Color(nsColor:.secondaryLabelColor)
    static let line = Color(nsColor:.separatorColor).opacity(0.55)
    static let soft = color(0xeeeef2, 0x38383a)
    static let accent = color(0x007aff,0x0a84ff)
    static let green = accent
    static let greenFill = accent.opacity(0.09)
    static let success = Color(nsColor:.systemGreen)
    static let successFill = success.opacity(0.10)
    static let amber = color(0xb45309,0xffb340)
    static let warningTint = Color(nsColor:.systemOrange)
    static let amberFill = amber.opacity(0.10)
    static let danger = Color(nsColor:.systemRed)
    static let primary = accent
    static let primaryText = Color.white
    static let resultAction = accent
    static let switchOn = Color(nsColor:.systemGreen)
    static let switchOff = color(0xd1d1d6, 0x636366)
    static func font(_ size: CGFloat, medium: Bool = false) -> Font {
        .system(size:size,weight:medium ? .semibold:.regular)
    }
}

struct VoiceAlert: Identifiable {
    let id: String
    let title: String
    let detail: String
    let kind: String
    let nextAt: Double
    let count: Int
    let state: String
    let voiceEnabled: Bool
    let playLimit: Int
    let limitReached: Bool
    let recoveryPending: Bool
    init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String else { return nil }
        self.id = id; title = raw["title"] as? String ?? "当前任务"
        detail = raw["detail"] as? String ?? ""; kind = raw["kind"] as? String ?? "result"
        nextAt = raw["nextAt"] as? Double ?? 0; count = raw["count"] as? Int ?? 0
        state = raw["state"] as? String ?? "pending"
        voiceEnabled = raw["voiceEnabled"] as? Bool ?? true
        playLimit = raw["playLimit"] as? Int ?? 0
        limitReached = raw["limitReached"] as? Bool ?? false
        recoveryPending = raw["recoveryPending"] as? Bool ?? false
    }
    var badge: String { ["approval":"等待审批", "question":"等待回答", "result":"已有结果", "blocked":"需要关注", "test":"播报测试"][kind] ?? "提醒" }
    var summary: String { ["approval":"有一项审批等待你处理", "question":"有个问题需要你回答", "result":"任务已有结果，可以查看了", "blocked":"这件事需要你关注", "test":"听到后点「已接手」停止"][kind] ?? "有一条新的提醒" }
    var isResult: Bool { kind == "result" }
    var ackTitle: String { isResult ? "知道了" : "已接手" }
}

struct VoiceOutput: Identifiable {
    let id: String
    let name: String
    let transport: String
    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String, let uid = raw["uid"] as? String else { return nil }
        self.name = name; id = uid; transport = raw["transport"] as? String ?? "other"
    }
    var caption: String { ["builtIn":"Mac 内置扬声器", "bluetooth":"蓝牙音频设备", "usb":"USB 音频设备", "airplay":"AirPlay 设备", "virtual":"虚拟音频设备", "passport":"随身工牌 · 预置中文语音，不随 Mac 音色调整"][transport] ?? "音频输出设备" }
    var symbol: String { transport == "passport" ? "person.text.rectangle" : transport == "bluetooth" ? "headphones" : transport == "airplay" ? "airplay.audio" : "speaker.wave.2" }
}

final class VoicePanelModel: ObservableObject {
    @Published var snapshot: [String: Any] = [:]
    @Published var now = Date().timeIntervalSince1970
    @Published var settingsOpen = false
    @Published var presentationActive = false
    @Published var presentationSupported = false
    @Published var presentationStatus = 3
    @Published var presentationTarget = "automatic"
    @Published var passportSettingsOpen = false
    @Published var passportPetNameDraft = "Codex"
    @Published var passportPetNameDraftBaseline = "Codex"
    @Published var speechSettingsOpen = false
    @Published var pauseDurationOpen = false
    @Published var usageOpen = false
    @Published var rulesOpen = false
    @Published var quietHoursOpen = false
    @Published var panelArrowX: CGFloat = PanelChrome.width / 2
    @Published var devicePickerOpen = false
    @Published var connectionConfigured = false
    @Published var connectionMessage = "正在检查连接"
    @Published var startupEnabled = false
    @Published var computerApprovalEnabled = false
    @Published var computerApprovalStatus = "未开启"
    @Published var serviceError: String?
    @Published var serviceRecovering = false
    @Published var recentTitle: String?
    @Published var listContentHeight: CGFloat = 160
    @Published var maximumListHeight: CGFloat = 380
    @Published var maximumSettingsHeight: CGFloat = 540
    @Published var maximumMainContentHeight:CGFloat = 650
    var action: ([String: Any]) -> Void = { _ in }
    var changeStartup: (Bool) -> Void = { _ in }
    var hide: () -> Void = {}
    var retry: () -> Void = {}
    var connectCodex: () -> Void = {}
    var setupPassport: () -> Void = {}
    var changePresentation: (Bool) -> Void = { _ in }
    var changePresentationTarget: (String) -> Void = { _ in }
    var presentationDetail: String {
        guard presentationSupported else { return "连接支持演示模式的新版工牌后可用。" }
        guard presentationActive else { return "长按工牌下键1.5秒开启；先在演示软件中开始放映。" }
        return ["上下键翻页 · 提醒暂缓播报", "已暂停翻页，请返回演示软件并开始放映。", "需要输入权限；可在下方打开权限设置。", "正在等待电脑和工牌就绪…"][min(3,max(0,presentationStatus))]
    }
    var changeComputerApproval: (Bool) -> Void = { _ in }
    var openApprovalAccess: () -> Void = {}

    var alerts: [VoiceAlert] {
        let items = (snapshot["alerts"] as? [[String: Any]] ?? []).compactMap(VoiceAlert.init)
        return items.filter { !$0.isResult } + items.filter { $0.isResult }
    }
    var enabled: Bool { snapshot["enabled"] as? Bool ?? true }
    var connected: Bool { snapshot["at"] != nil && serviceError == nil }
    var mutedUntil: Double { snapshot["mutedUntil"] as? Double ?? 0 }
    var muted: Bool { mutedUntil > now }
    var pauseMinutes: Int { (snapshot["pause"] as? [String: Any])?["minutes"] as? Int ?? 15 }
    var pauseError: String { (snapshot["pause"] as? [String: Any])?["error"] as? String ?? "" }
    var passport: [String:Any] {snapshot["passport"] as? [String:Any] ?? [:]}
    var passportEnabled: Bool {passport["enabled"] as? Bool ?? false}
    var passportConnected: Bool {passportEnabled && (passport["connected"] as? Bool ?? false)}
    var passportVoiceEnabled: Bool {passport["voiceEnabled"] as? Bool ?? false}
    var passportPetName: String {passport["petName"] as? String ?? "Codex"}
    var passportPetNameSupported: Bool {passport["petNameSupported"] as? Bool ?? false}
    var passportFirmware: String {passport["firmware"] as? String ?? ""}
    var petSync:[String:Any] {passport["petSync"] as? [String:Any] ?? [:]}
    var petSyncDetail:String {petSync["detail"] as? String ?? "连接后自动同步 Codex 当前宠物"}
    var petSyncProgress:Double {Double(petSync["progress"] as? Int ?? 0)}
    var petSyncHash:String {petSync["sha"] as? String ?? ""}
    var petPreview:NSImage? {NSImage(contentsOf:AppPaths.runtime.appendingPathComponent("pet-cache/preview.png"))}
    var passportLinkError: String {(passport["error"] as? String).flatMap {$0.isEmpty ? nil : $0} ?? "确认工牌已开机、在 Mac 附近；恢复后会自动连接。"}
    var passportSettingsError: String {passport["settingsError"] as? String ?? ""}
    var computerAudioEnabled: Bool {audio["computerEnabled"] as? Bool ?? true}
    var computerAudioReady: Bool {audio["computerReady"] as? Bool ?? audioReady}
    var silentOutputs: Bool {audio["silent"] as? Bool ?? false}
    var canTestPassport: Bool {connected && enabled && passportConnected && passportVoiceEnabled && !muted && !quietActive}
    func configurePassport(_ patch:[String:Any]) {action(["action":"set_passport_settings","settings":patch])}
    var audio: [String: Any] { snapshot["audio"] as? [String: Any] ?? [:] }
    var device: String { audio["device"] as? String ?? "播报设备" }
    var audioAvailable: Bool { audio["available"] as? Bool ?? false }
    var audioReady: Bool { audio["ready"] as? Bool ?? false }
    var speaking: Bool { snapshot["speakingId"] is String }
    var eventsAvailable: Bool { (snapshot["monitor"] as? [String: Any])?["state"] as? String == "connected" }
    var usage: CodexUsage {
        CodexUsage(serviceError == nil ? snapshot["usage"] as? [String: Any] ?? [:] : ["state":"error", "message":"提醒服务已断开，请重新连接后刷新用量。"], now: now, warningThreshold: usageLowThreshold)
    }
    var usageAnnouncement: [String: Any] { snapshot["usageAnnouncement"] as? [String: Any] ?? [:] }
    var usageResetEnabled: Bool { usageAnnouncement["enabled"] as? Bool ?? true }
    var usageResetPreviewing: Bool { usageAnnouncement["previewing"] as? Bool ?? false }
    var usageResetError: String { usageAnnouncement["error"] as? String ?? "" }
    var usageLowAnnouncement: [String: Any] { snapshot["usageLowAnnouncement"] as? [String: Any] ?? [:] }
    var usageLowEnabled: Bool { usageLowAnnouncement["enabled"] as? Bool ?? true }
    var usageLowThreshold: Int { usageLowAnnouncement["threshold"] as? Int ?? 20 }
    var usageLowPreviewing: Bool { usageLowAnnouncement["previewing"] as? Bool ?? false }
    var usageLowError: String { usageLowAnnouncement["error"] as? String ?? "" }
    var followSystem: Bool { audio["followSystem"] as? Bool ?? false }
    var outputs: [VoiceOutput] { (audio["devices"] as? [[String: Any]] ?? []).compactMap(VoiceOutput.init).filter {$0.id != PassportProtocol.uid} }
    var defaultName: String { audio["defaultName"] as? String ?? "" }
    var displayDevice: String { followSystem ? "跟随系统输出" : device }
    var speech: [String: Any] { snapshot["speech"] as? [String: Any] ?? [:] }
    var voices: [SpeechVoice] { (speech["voices"] as? [[String: Any]] ?? []).compactMap(SpeechVoice.init) }
    var speechReady: Bool { speech["ready"] as? Bool ?? true }
    var previewing: Bool { speech["previewing"] as? Bool ?? false }
    var voiceName: String {
        let selected = speech["voice"] as? String ?? "Tingting"
        return voices.first(where: { $0.id == selected })?.name ?? selected
    }
    var intervalSummary: String {
        let values = speech["intervals"] as? [Int] ?? [30, 60, 180]
        return values.enumerated().map { index, value in
            let duration = value % 60 == 0 ? "\(value / 60) 分钟" : "\(value) 秒"
            return (index == 2 ? "每 " : "") + duration
        }.joined(separator: " → ")
    }
    func isSelected(_ output: VoiceOutput) -> Bool {
        if followSystem { return false }
        let uid = audio["selectedUID"] as? String ?? ""
        return uid.isEmpty ? output.name == audio["selectedDevice"] as? String : output.id == uid
    }
    func openDevicePicker() { action(["action":"refresh_audio"]); devicePickerOpen = true }
    func chooseDevice(_ output: VoiceOutput?) {
        let uid = output?.id ?? ""
        action(["action":"set_audio_device", "device":output?.name ?? "", "uid":uid.hasPrefix("name:") ? "" : uid])
        devicePickerOpen = false
    }
    var quiet: [String: Any] { snapshot["quietHours"] as? [String: Any] ?? [:] }
    var quietActive: Bool { quiet["active"] as? Bool ?? false }
    var allowQuietApproval: Bool { quiet["allow_approval"] as? Bool ?? false }
    var quietSummary: String { quiet["enabled"] as? Bool == true ? "\(quiet["start"] as? String ?? "23:00")–\(quiet["end"] as? String ?? "09:00") · 按所选日期" : "未开启 · 按本机时间执行" }
    var reminderRules: [String: Any] { snapshot["reminderRules"] as? [String: Any] ?? [:] }
    var rulesError: String { snapshot["rulesError"] as? String ?? "" }
    var canPlay: Bool { connected && enabled && audioReady && speechReady && !muted && !quietActive }
    func canPlay(_ alert: VoiceAlert) -> Bool { connected && enabled && audioReady && speechReady && !muted && (!quietActive || (alert.kind == "approval" && allowQuietApproval)) }
    var audioNote: String {
        if !computerAudioEnabled {return "电脑播报已关闭"}
        if !(audio["computerAvailable"] as? Bool ?? audioAvailable) {return "电脑扬声器未连接"}
        if !computerAudioReady {return audio["computerError"] as? String ?? "电脑扬声器暂不可用"}
        if !audioReady { return audio["error"] as? String ?? "扬声器暂时无法播报" }
        if followSystem { return speaking ? "正在播报 · 接手后停止" : "当前：" + device }
        return speaking ? "正在播报 · 接手后停止" : "已连接 · 声音从此设备播放"
    }
    var heading: (title: String, subtitle: String, icon: String, tone: Int) {
        if let error = serviceError { return (serviceRecovering ? "正在恢复提醒服务" : "提醒服务需要检查", error, "exclamationmark", 1) }
        if !connected { return ("正在连接", "准备好后，有事我会喊你", "waveform", 0) }
        if !enabled { return ("提醒已关闭", "重新开启后，只接收新的提醒", "bell.slash", 0) }
        if silentOutputs {return ("仅显示提醒","电脑和工牌的任务语音均已关闭","bell.slash",0)}
        if !audioAvailable { return ("扬声器未连接", "待处理事项会保留，连接后继续播报", "speaker.slash", 1) }
        if !audioReady { return ("扬声器暂时无法播报", audioNote, "speaker.slash", 1) }
        if let error = speech["error"] as? String, !error.isEmpty { return ("播报声音需要检查", error, "waveform", 1) }
        if muted { return ("提醒已暂停", "\(max(1, Int(ceil((mutedUntil - now) / 60)))) 分钟后恢复，待处理事项会保留", "pause", 0) }
        if quietActive { return ("定时免打扰", allowQuietApproval ? "保留待办卡片，仅审批提醒可出声" : "待办会保留，时段结束后恢复播报", "moon", 0) }
        if !alerts.isEmpty { return ("\(alerts.count) 件事需要你", "重要的事，听到后再来处理", "bell.badge", 1) }
        if !eventsAvailable { return ("等待 Codex 连接", "未读到本机任务事件，请先打开 Codex", "link", 0) }
        if !connectionConfigured { return ("完成提醒已就绪", "连接 Codex，以增加审批与提问提醒", "checkmark", 2) }
        return ("一切就绪", "有新结果或需要确认时，会及时提醒你", "checkmark", 2)
    }
    func meta(_ alert: VoiceAlert) -> String {
        if !connected { return "服务连接中 · 待处理事项已保留" }
        if alert.recoveryPending { return "等待核验任务状态 · 暂不自动播报" }
        if quietActive && !(alert.kind == "approval" && allowQuietApproval) { return "定时免打扰 · 卡片已保留" }
        if alert.state == "snoozed" {
            let seconds = max(0, Int(ceil(alert.nextAt - now)))
            let delay = seconds >= 60 ? "\(Int(ceil(Double(seconds) / 60))) 分钟" : "\(seconds) 秒"
            return "已安排稍后 · \(delay)后再提醒"
        }
        if !alert.voiceEnabled { return "此类语音已关闭 · 可手动重播" }
        if alert.limitReached { return "已播报 \(alert.count) 次 · 本条已达到次数上限" }
        if !audioReady { return "音箱暂不可用 · 恢复后继续提醒" }
        if !speechReady { return "音色暂不可用 · 请在设置中调整" }
        if muted { return "已暂停 · 恢复后继续提醒" }
        let seconds = max(0, Int(ceil(alert.nextAt - now)))
        let delay = seconds >= 60 ? "\(Int(ceil(Double(seconds) / 60))) 分钟" : "\(seconds) 秒"
        if snapshot["speakingId"] as? String == alert.id { return "正在播报 · 接手后停止" }
        if alert.count == 0 { return seconds > 0 ? "\(delay)后提醒" : "等待播报" }
        return "已提醒 \(alert.count) 次 · " + (seconds > 0 ? "\(delay)后再次提醒" : "等待播报")
    }
    func pauseOrResume() { action(["action": muted ? "unmute" : "mute"]) }
    func setPause(minutes: Int, start: Bool) { action(["action": start ? "pause" : "set_pause_duration", "minutes": minutes]) }
}

struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    enum Kind { case primary, secondary, quiet, icon }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiceTheme.font(12))
            .foregroundColor(kind == .primary ? VoiceTheme.primaryText : kind == .quiet ? VoiceTheme.secondary : VoiceTheme.ink)
            .padding(.horizontal, kind == .icon ? 8 : kind == .quiet ? 7 : 12)
            .padding(.vertical, 7)
            .background(kind == .primary ? VoiceTheme.primary : kind == .secondary ? VoiceTheme.paper : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius: 8,style:.continuous).stroke(kind == .secondary ? VoiceTheme.line : Color.clear, lineWidth: 0.7))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.72 : 1)
    }
}

struct IconAction: View {
    let symbol: String
    let label: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 16, height: 16) }
            .buttonStyle(PanelButtonStyle(kind: .icon))
            .accessibilityLabel(label).help(label).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}

private struct AcknowledgeButtonStyle: ButtonStyle {
    var isResult: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VoiceTheme.font(12, medium: true))
            .foregroundColor(VoiceTheme.primaryText)
            .frame(minWidth:76).padding(.horizontal,8).frame(height:32)
            .background(VoiceTheme.primary)
            .clipShape(Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private typealias PauseDraftState<Value> = SwiftUI.State<Value>

private struct PauseDurationView: View {
    @ObservedObject var model: VoicePanelModel
    @PauseDraftState private var minutes: String

    init(model: VoicePanelModel) {
        self.model = model
        _minutes = State(initialValue: String(model.pauseMinutes))
    }
    private var value: Int? {
        guard let value = Int(minutes.trimmingCharacters(in: .whitespaces)), (1...1440).contains(value) else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("暂停时长").font(VoiceTheme.font(17, medium: true))
                Spacer()
                IconAction(symbol: "xmark", label: "返回提醒") { model.pauseDurationOpen = false }
            }
            Text("暂停期间保留事项，到时自动恢复提醒。")
                .font(VoiceTheme.font(12)).foregroundColor(VoiceTheme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("15", text: $minutes).textFieldStyle(.plain)
                    .font(VoiceTheme.font(25, medium: true)).monospacedDigit()
                    .accessibilityLabel("自定义暂停分钟数")
                    .onSubmit { save(start: model.enabled) }
                Text("分钟").font(VoiceTheme.font(13)).foregroundColor(VoiceTheme.secondary)
            }.padding(14).background(VoiceTheme.soft).clipShape(RoundedRectangle(cornerRadius: 9))
                .disabled(!model.connected)
            HStack(spacing: 7) {
                ForEach([5, 15, 30, 60], id: \.self) { duration in
                    Button("\(duration) 分钟") { minutes = String(duration) }
                        .buttonStyle(PanelButtonStyle()).frame(maxWidth: .infinity)
                }
            }.disabled(!model.connected)
            Text(value == nil ? "请输入 1–1440 之间的整数分钟。" : "时长会保存，下次可直接使用。")
                .font(VoiceTheme.font(11)).foregroundColor(value == nil ? VoiceTheme.amber : VoiceTheme.secondary)
            if !model.pauseError.isEmpty {
                Text(model.pauseError).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.amber)
            }
            if model.muted {
                Text("仅保存不会改变当前暂停；再次暂停会从现在重新计时。")
                    .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 9) {
                Spacer()
                Button("仅保存") { save(start: false) }.buttonStyle(PanelButtonStyle())
                    .disabled(value == nil || !model.connected)
                Button("保存并暂停") { save(start: true) }.buttonStyle(PanelButtonStyle(kind: .primary))
                    .disabled(value == nil || !model.connected || !model.enabled)
            }.padding(.top, 2)
        }.padding(20)
    }
    private func save(start: Bool) {
        guard let value, model.connected, !start || model.enabled else { return }
        model.setPause(minutes: value, start: start)
        model.pauseDurationOpen = false
    }
}

struct VoicePanelView: View {
    @ObservedObject var model: VoicePanelModel
    var body: some View {
        Group {
            if model.devicePickerOpen { devicePicker }
            else if model.pauseDurationOpen { PauseDurationView(model: model) }
            else if model.usageOpen { UsageDetailView(model: model) }
            else if model.rulesOpen { ReminderRulesView(model: model) }
            else if model.quietHoursOpen { QuietHoursView(model: model) }
            else if model.speechSettingsOpen { SpeechSettingsView(model: model) }
            else if model.passportSettingsOpen { PassportSettingsView(model:model) }
            else if model.settingsOpen { settings }
            else { main }
        }
        .frame(width: PanelChrome.width)
        .padding(.top, PanelChrome.arrowHeight)
        .fixedSize(horizontal: true, vertical: true)
        .font(VoiceTheme.font(13)).foregroundColor(VoiceTheme.ink)
        .background(VoiceTheme.background)
        .clipShape(PanelBubbleShape(arrowX: model.panelArrowX))
        .overlay(PanelBubbleShape(arrowX: model.panelArrowX).stroke(VoiceTheme.line, lineWidth: 1))
        .onExitCommand {
            if model.devicePickerOpen { model.devicePickerOpen = false }
            else if model.pauseDurationOpen { model.pauseDurationOpen = false }
            else if model.usageOpen { model.usageOpen = false }
            else if model.rulesOpen { model.rulesOpen = false }
            else if model.quietHoursOpen { model.quietHoursOpen = false }
            else if model.speechSettingsOpen { model.speechSettingsOpen = false }
            else if model.passportSettingsOpen {model.passportSettingsOpen=false}
            else if model.settingsOpen { model.settingsOpen = false }
            else { model.hide() }
        }
    }
    private var main: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                Image(systemName:"waveform").font(.system(size:18,weight:.medium)).foregroundColor(.white)
                    .frame(width:36,height:36).background(VoiceTheme.accent).clipShape(RoundedRectangle(cornerRadius:10,style:.continuous))
                Text("Codex 语音提醒").font(VoiceTheme.font(15,medium:true)).tracking(-0.3)
                Spacer(minLength:8)
                enableToggle
                IconAction(symbol:"gearshape",label:"更多设置") {model.settingsOpen=true}
            }.padding(.horizontal,20).padding(.top,17).padding(.bottom,16)
            ViewThatFits(in:.vertical) {
                mainCards.fixedSize(horizontal:false,vertical:true)
                ScrollView(.vertical) {mainCards}.frame(height:model.maximumMainContentHeight)
            }.frame(maxHeight:model.maximumMainContentHeight)
            footer
        }
    }
    private var mainCards:some View {
        VStack(spacing:0) {
            deviceRow
            statusStrip
            if !model.alerts.isEmpty {
                HStack {
                    Text("待处理").font(VoiceTheme.font(12,medium:true))
                    Text("\(model.alerts.count)").font(.system(size:10,weight:.semibold,design:.rounded)).foregroundColor(VoiceTheme.secondary)
                        .padding(.horizontal,6).padding(.vertical,2).background(VoiceTheme.soft).clipShape(Capsule())
                    Spacer()
                    Text("在原聊天中继续处理").font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                }.padding(.horizontal,21).padding(.top,3).padding(.bottom,10)
                ReminderList(model:model)
            }
            UsageSummaryRow(model:model)
            PassportAccessoryCard(model:model)
        }
    }
    private var statusStrip: some View {
        let tone=model.heading.tone
        let tint=tone==1 ? VoiceTheme.amber : tone==2 ? VoiceTheme.success : VoiceTheme.accent
        return HStack(spacing:10) {
            Image(systemName:model.heading.icon).font(.system(size:14,weight:.semibold)).foregroundColor(tint)
                .frame(width:33,height:33).background(tint.opacity(0.10)).clipShape(Circle())
            VStack(alignment:.leading,spacing:3) {
                Text(model.heading.title).font(VoiceTheme.font(14,medium:true))
                Text(model.heading.subtitle).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:4)
            if model.serviceError != nil {
                Button("重连",action:model.retry).buttonStyle(PanelButtonStyle())
            } else if model.alerts.isEmpty {
                if !model.connectionConfigured && model.connected {
                    Button("连接",action:model.connectCodex).buttonStyle(PanelButtonStyle())
                } else {
                    Button {model.action(["action":"test"])} label: {
                        Image(systemName:"play.fill").font(.system(size:11)).frame(width:30,height:30)
                    }.buttonStyle(.plain).foregroundColor(VoiceTheme.accent).disabled(!model.canPlay)
                        .accessibilityLabel("试听一下").help("试听已开启的输出，点「已接手」停止")
                }
            }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:15,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:15,style:.continuous).stroke(VoiceTheme.line,lineWidth:0.6))
            .padding(.horizontal,18).padding(.bottom,12)
    }
    private var footer: some View {
        HStack(spacing:5) {
            Button(action:model.pauseOrResume) {
                Label(model.muted ? "恢复提醒" : "暂停 \(model.pauseMinutes) 分钟",systemImage:model.muted ? "play" : "pause")
            }.buttonStyle(PanelButtonStyle(kind:.quiet)).disabled(!model.enabled || !model.connected)
            Menu {
                Text("默认时长：\(model.pauseMinutes) 分钟")
                Divider()
                ForEach([5,15,30,60,120],id:\.self) { minutes in
                    Button(model.enabled ? "暂停 \(minutes) 分钟" : "设为 \(minutes) 分钟") {model.setPause(minutes:minutes,start:model.enabled)}
                }
                Divider();Button("自定义时长…") {model.pauseDurationOpen=true}
            } label: {
                Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold)).foregroundColor(VoiceTheme.secondary).frame(width:23,height:28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(!model.connected)
                .accessibilityLabel("设置暂停时长，默认 \(model.pauseMinutes) 分钟")
            Spacer(minLength:4)
            if model.alerts.count>1 {
                Button("全部已接手") {model.action(["action":"ack_all"])}.buttonStyle(PanelButtonStyle(kind:.quiet)).foregroundColor(VoiceTheme.accent)
            }
            Button(action:model.hide) {Label("收起面板",systemImage:"chevron.up").padding(.horizontal,2)}
                .buttonStyle(PanelButtonStyle(kind:.primary)).accessibilityLabel("收起面板")
        }.padding(.horizontal,16).padding(.vertical,10)
            .overlay(alignment:.top) {VoiceTheme.line.frame(height:0.6).padding(.horizontal,18)}
    }
    private var enableToggle: some View {
        Toggle("启用语音提醒", isOn: Binding(get: { model.enabled }, set: { model.action(["action":"set_enabled", "enabled":$0]) }))
            .toggleStyle(PersistentSwitchStyle()).labelsHidden().disabled(!model.connected)
            .help("关闭立即停喊，重新开启只接收新事项")
    }
    private var deviceRow: some View {
        Button(action:model.openDevicePicker) {
            HStack(spacing:11) {
                Image(systemName:model.computerAudioEnabled && model.computerAudioReady ? "speaker.wave.2":"speaker.slash")
                    .font(.system(size:18)).foregroundColor(model.computerAudioEnabled && model.computerAudioReady ? VoiceTheme.accent:VoiceTheme.secondary).frame(width:27)
                VStack(alignment:.leading,spacing:4) {
                    Text(model.displayDevice).font(VoiceTheme.font(13,medium:true)).lineLimit(1)
                    Text(model.audioNote).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).lineLimit(2)
                }
                Spacer(minLength:5)
                Image(systemName:"chevron.up.chevron.down").font(.system(size:11,weight:.medium)).foregroundColor(VoiceTheme.secondary)
            }.padding(.horizontal,14).padding(.vertical,12).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                .background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(VoiceTheme.line,lineWidth:0.6))
        }.buttonStyle(.plain).accessibilityLabel("选择播报设备，当前：\(model.displayDevice)").help("打开电脑播报与扬声器设置")
            .padding(.horizontal,18).padding(.bottom,12)
    }
    private func settingRow<Content: View>(_ title: String, _ caption: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(VoiceTheme.font(13, medium: true))
                Text(caption).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 5)
            control()
        }.padding(13)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("提醒设置").font(VoiceTheme.font(17, medium: true))
                Spacer()
                IconAction(symbol: "xmark", label: "返回提醒") { model.settingsOpen = false }
            }.padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
            Text("声音").font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).padding(.bottom, 8)
            VStack(spacing: 0) {
                settingRow(model.displayDevice, model.audioNote) {
                    HStack(spacing: 7) {
                        Button("切换", action: model.openDevicePicker).buttonStyle(PanelButtonStyle())
                        Button("试听") { model.action(["action":"test"]) }.buttonStyle(PanelButtonStyle()).disabled(!model.canPlay)
                            .help("创建一条测试提醒，点「已接手」停止")
                    }
                }
                VoiceTheme.line.frame(height: 1)
                settingRow("声音与规则", model.voiceName + "\n" + model.intervalSummary) {
                    Button("调整") { model.speechSettingsOpen = true }.buttonStyle(PanelButtonStyle()).disabled(!model.connected)
                }
            }.background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1))
            VStack(spacing: 0) {
                settingRow("按类型设置提醒", "分别设置完成、审批、提问和异常的播报") {
                    Button("设置") { model.rulesOpen = true }.buttonStyle(PanelButtonStyle()).disabled(!model.connected)
                }
                VoiceTheme.line.frame(height: 1)
                settingRow("定时免打扰", model.quietSummary) {
                    Button("设置") { model.quietHoursOpen = true }.buttonStyle(PanelButtonStyle()).disabled(!model.connected)
                }
            }.background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1)).padding(.top, 12)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Computer Use 授权提醒").font(VoiceTheme.font(13, medium: true))
                    Spacer()
                    Toggle("识别 Computer Use 授权卡片", isOn: Binding(get: { model.computerApprovalEnabled }, set: model.changeComputerApproval))
                        .toggleStyle(PersistentSwitchStyle()).labelsHidden()
                }
                Text("通过辅助功能识别 Codex 当前窗口中的应用授权卡片，仅用于提醒；审批仍由你处理。默认关闭。")
                    .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(model.computerApprovalStatus).font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                    Spacer()
                    Button("输入与识别权限", action: model.openApprovalAccess).buttonStyle(PanelButtonStyle())
                }
            }.padding(13).background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1)).padding(.top, 12)
            settingRow("AI Passport", "独立管理连接、配件播报与屏保昵称") {
                Button("设置") {model.passportSettingsOpen=true}.buttonStyle(PanelButtonStyle())
            }.padding(.top,12)
            Text("启动与运行").font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).padding(.top, 20).padding(.bottom, 8)
            VStack(spacing: 0) {
                settingRow("登录后自动启动", "后台安静运行，需要时再出现") {
                    Toggle("登录后自动启动", isOn: Binding(get: { model.startupEnabled }, set: model.changeStartup)).toggleStyle(PersistentSwitchStyle()).labelsHidden()
                }
                VoiceTheme.line.frame(height: 1)
                settingRow("启用语音提醒", "关闭后不积压旧提醒") { enableToggle }
            }.background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1))
            Text("全部接手后自动收起；有新提醒时再出现。")
                .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).padding(.top, 16)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Codex 连接").font(VoiceTheme.font(13, medium: true))
                    Spacer()
                    Button(model.connectionConfigured ? "重新安装连接" : "连接 Codex", action: model.connectCodex).buttonStyle(PanelButtonStyle())
                }
                Text(model.connectionMessage).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(13).background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1)).padding(.top, 16)
                }.padding(.bottom, 2)
            }.frame(height: model.maximumSettingsHeight)
            HStack {
                Circle().fill(model.connected ? VoiceTheme.green : VoiceTheme.amber).frame(width: 5, height: 5)
                Text(model.connected ? "服务正常 · 自动恢复已开启" : model.serviceRecovering ? "服务正在自动恢复" : "提醒服务未连接").font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary)
                Spacer()
                Button("退出应用") { NSApp.terminate(nil) }.buttonStyle(PanelButtonStyle(kind: .quiet))
            }.padding(.top, 18)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 19)
    }
    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("声音输出").font(VoiceTheme.font(17, medium: true))
                Spacer()
                IconAction(symbol: "xmark", label: "返回") { model.devicePickerOpen = false }
            }.padding(.bottom, 6)
            Text("控制电脑播报，并选择扬声器")
                .font(VoiceTheme.font(12)).foregroundColor(VoiceTheme.secondary).padding(.bottom, 18)
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:4) {
                    Text("电脑播报").font(VoiceTheme.font(13,medium:true))
                    Text("关闭后保留任务卡片，AI Passport 可独立播报。")
                        .font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Spacer(minLength:4)
                Toggle("电脑播报",isOn:Binding(get:{model.computerAudioEnabled},set:{model.action(["action":"set_computer_audio_enabled","enabled":$0])}))
                    .toggleStyle(PersistentSwitchStyle()).labelsHidden().disabled(!model.connected)
            }.padding(13).background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:14,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:14,style:.continuous).stroke(VoiceTheme.line,lineWidth:0.6)).padding(.bottom,12)
            VStack(spacing: 5) {
                outputRow("跟随系统输出", caption: model.defaultName.isEmpty ? "使用 macOS 当前的输出设备" : "当前：" + model.defaultName, symbol: "speaker.wave.2", selected: model.followSystem) { model.chooseDevice(nil) }
                VoiceTheme.line.frame(height: 1).padding(.vertical, 5)
                if model.outputs.count > 5 { ScrollView { outputChoices }.frame(height: 320) }
                else { outputChoices }
                if !(model.audio["computerAvailable"] as? Bool ?? model.audioAvailable) && !model.followSystem {
                    HStack {
                        Image(systemName: "speaker.slash").frame(width: 22)
                        Text(model.device + " · 未连接").font(VoiceTheme.font(12))
                        Spacer()
                        Image(systemName: "checkmark")
                    }.foregroundColor(VoiceTheme.secondary).padding(12)
                }
            }.padding(6).background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiceTheme.line, lineWidth: 1))
            Text("未出现的蓝牙或 AirPlay 设备，请先在 macOS 中连接。")
                .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            HStack {
                Text("选择会自动保存").font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary)
                Spacer()
                Button { model.action(["action":"refresh_audio"]) } label: { Label("刷新设备", systemImage: "arrow.clockwise") }
                    .buttonStyle(PanelButtonStyle(kind: .quiet))
            }.padding(.top, 12)
        }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 19)
    }
    private var outputChoices: some View {
        VStack(spacing: 5) {
            ForEach(model.outputs) { output in
                outputRow(output.name, caption: output.caption, symbol: output.symbol, selected: model.isSelected(output)) { model.chooseDevice(output) }
            }
        }
    }
    private func outputRow(_ title: String, caption: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).frame(width: 23)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(VoiceTheme.font(13, medium: true)).fixedSize(horizontal: false, vertical: true)
                    Text(caption).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary)
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").font(.system(size: 13, weight: .medium)).accessibilityHidden(true) }
            }.foregroundColor(selected ? VoiceTheme.green : VoiceTheme.ink).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? VoiceTheme.greenFill : Color.clear).clipShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(selected ? "已选择" : "未选择")
    }
}

private struct ReminderList: View {
    @ObservedObject var model: VoicePanelModel
    var body: some View {
        ScrollView(.vertical, showsIndicators: model.listContentHeight > model.maximumListHeight) {
            VStack(spacing: 9) {
                ForEach(model.alerts) { alert in ReminderCard(alert: alert, model: model) }
            }.padding(.horizontal, 18).padding(.bottom, 12)
                .background(GeometryReader { geometry in Color.clear.preference(key: ListHeightKey.self, value: geometry.size.height) })
        }
        .frame(height: min(model.listContentHeight, model.maximumListHeight))
        .onPreferenceChange(ListHeightKey.self) { if $0 > 1 && abs(model.listContentHeight - $0) > 0.5 { model.listContentHeight = $0 } }
    }
}

private struct ReminderCard: View {
    let alert:VoiceAlert
    @ObservedObject var model:VoicePanelModel
    private var tint:Color {
        switch alert.kind {case "result":return VoiceTheme.success;case "blocked":return VoiceTheme.danger;case "approval":return VoiceTheme.amber;default:return VoiceTheme.accent}
    }
    private var symbol:String {
        ["result":"checkmark.circle.fill","approval":"hand.raised.fill","question":"questionmark.bubble.fill","blocked":"exclamationmark.triangle.fill","test":"speaker.wave.2.fill"][alert.kind] ?? "bell.fill"
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:8) {
                Label(alert.badge,systemImage:symbol).font(VoiceTheme.font(10,medium:true)).foregroundColor(tint)
                    .padding(.horizontal,8).padding(.vertical,4).background(tint.opacity(0.09)).clipShape(Capsule())
                Spacer(minLength:4)
                Text(model.meta(alert)).font(VoiceTheme.font(10)).monospacedDigit().foregroundColor(VoiceTheme.secondary).lineLimit(1).help(model.meta(alert))
            }
            VStack(alignment:.leading,spacing:5) {
                Text(alert.title).font(VoiceTheme.font(14,medium:true)).lineLimit(2).fixedSize(horizontal:false,vertical:true).help(alert.title)
                Text(alert.summary).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).lineLimit(2)
                    .help(alert.detail.isEmpty ? alert.summary:alert.detail)
            }
            HStack(spacing:5) {
                Menu {
                    ForEach([5,15,30],id:\.self) {minutes in Button("\(minutes) 分钟") {model.action(["action":"snooze","id":alert.id,"seconds":minutes*60])}}
                } label: {
                    HStack(spacing:4) {Image(systemName:"clock");Text("稍后");Image(systemName:"chevron.down").font(.system(size:8))}
                        .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).padding(.horizontal,7).padding(.vertical,6)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("选择稍后提醒的时间")
                IconAction(symbol:"speaker.wave.2",label:"再次播报「\(alert.title)」",disabled:!model.canPlay(alert)) {model.action(["action":"replay","id":alert.id])}
                Spacer(minLength:5)
                Button(alert.ackTitle) {model.action(["action":"ack","id":alert.id])}
                    .buttonStyle(AcknowledgeButtonStyle(isResult:alert.isResult)).accessibilityIdentifier("ack-"+alert.id)
                    .help(alert.kind=="approval" ? "停止这条提醒，审批仍在原聊天处理":"停止这条提醒")
            }
        }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:16,style:.continuous))
            .overlay(RoundedRectangle(cornerRadius:16,style:.continuous).stroke(VoiceTheme.line,lineWidth:0.6))
            .accessibilityElement(children:.contain)
    }
}
