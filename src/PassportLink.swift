import Foundation
import CoreBluetooth
import AppKit
import ApplicationServices

final class PassportLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "EA37F001-4E2B-47EF-9501-6D79B932A001")
    static let rxID = CBUUID(string: "EA37F002-4E2B-47EF-9501-6D79B932A001")
    static let txID = CBUUID(string: "EA37F003-4E2B-47EF-9501-6D79B932A001")
    static let voiceID = CBUUID(string: "EA37F004-4E2B-47EF-9501-6D79B932A001")
    static let assetID = CBUUID(string: "EA37F005-4E2B-47EF-9501-6D79B932A001")
    let dictation = PassportDictation()
    let presenter = PassportPresenter()
    var presentationChanged: (Bool, Bool, Int, String) -> Void = { _,_,_,_ in }
    private var lastPresentationLease = Date.distantPast
    private var presentationDiagnosticMarker = ""
    private var presentationPosted = 0
    private var presentationLastRequest: [String:Any] = [:]

    func presentationContext() -> PresentationContext {
        let fresh = Date().timeIntervalSince1970 - (snapshot["at"] as? Double ?? 0) < 8
        return PresentationContext(connected: enabled && ready && fresh,
            quietAcknowledged: (snapshot["presentation"] as? [String:Any])?["active"] as? Bool == true,
            permission: AXIsProcessTrusted() && CGPreflightPostEventAccess(),
            frontBundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, inputIdle:dictation.activeID == nil)
    }
    func refreshPresentation() {
        let context = presentationContext()
        if presenter.enabled && !context.connected { presenter.setEnabled(false, context: context) }
        if presenter.enabled && Date().timeIntervalSince(lastPresentationLease) >= 2 {
            sendAction(["action":"presentation_mode", "active":true]); lastPresentationLease = Date()
        }
        presentationChanged(presenter.enabled, presenter.supported, presenter.status(context), presenter.target.rawValue)
        var report: [String:Any] = ["active":presenter.enabled, "supported":presenter.supported,
            "status":presenter.status(context), "target":presenter.target.rawValue,
            "keyPairsPosted":presentationPosted, "lastRequest":presentationLastRequest]
        if let marker = try? JSONSerialization.data(withJSONObject:report, options:.sortedKeys).base64EncodedString(), marker != presentationDiagnosticMarker {
            presentationDiagnosticMarker = marker
            report["at"] = Date().timeIntervalSince1970
            if let data = try? JSONSerialization.data(withJSONObject:report, options:.sortedKeys) {
                let path = AppPaths.runtime.appendingPathComponent("passport-presentation.json")
                try? data.write(to:path, options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:path.path)
            }
        }
    }
    func configurePresentation(enabled value: Bool? = nil, target: String? = nil) {
        if let target, let choice = PresentationTarget(rawValue: target) {
            presenter.target = choice
            UserDefaults.standard.set(target, forKey:"PassportPresentationTarget")
        }
        if let value { presenter.setEnabled(value, context:presentationContext()) }
        refreshPresentation(); sendState()
    }
    func endPresentation() {
        presenter.setEnabled(false, context:presentationContext())
        refreshPresentation(); sendState()
    }
    var voiceSupported = false
    var voiceSubscribed = false
    let epoch = PassportProtocol.makeEpoch()
    let sendAction: ([String: Any]) -> Void
    var central: CBCentralManager?
    var peer: CBPeripheral?
    var rx: CBCharacteristic?
    var assetCharacteristic:CBCharacteristic?
    var petSupported=false
    lazy var petSync:PassportPetSync = {
        let sync=PassportPetSync()
        sync.send={ [weak self] in self?.send($0) }
        sync.write={ [weak self] data in
            guard let self,self.fragments.isEmpty,!self.writing,let peer=self.peer,peer.state == .connected,
                  let chr=self.assetCharacteristic,peer.canSendWriteWithoutResponse else {return false}
            peer.writeValue(data,for:chr,type:.withoutResponse);return true
        }
        sync.report={ [weak self] value in var event=value;event["kind"]="pet";self?.feedback(event) }
        return sync
    }()
    var enabled = false
    var ready = false
    var audioReady = false
    var receiveBuffer = Data()
    var fragments: [Data] = []
    var writing = false
    var snapshot: [String: Any] = [:]
    var lastFrame = Date.distantPast
    var lastState = Date.distantPast
    var nextConnect = Date.distantPast
    var connectStarted = Date.distantPast
    var lastFeedback = Date.distantPast
    var scanResults: [UUID: CBPeripheral] = [:]
    var scanning = false
    var pending: [String: (String, String, Int, Date)] = [:]
    var completed: [String: [String: Any]] = [:]
    var volume = 60
    var firmware = ""
    var petNameSupported = false
    var timer: Timer?

    init(sendAction: @escaping ([String: Any]) -> Void) {
        self.sendAction = sendAction
        super.init()
        presenter.target = PresentationTarget(rawValue:UserDefaults.standard.string(forKey:"PassportPresentationTarget") ?? "") ?? .automatic
        presenter.changed = { [weak self] in
            guard let self else { return }
            self.sendAction(["action":"presentation_mode", "active":self.presenter.enabled])
            self.lastPresentationLease = Date()
            self.refreshPresentation()
        }
        dictation.send = { [weak self] object in
            guard let self else { return }
            var frame = object; frame["epoch"] = self.epoch; self.send(frame)
        }
        dictation.busyChanged = { [weak self] active in self?.feedback(["kind":"dictation","active":active]) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func feedback(_ event: [String: Any]) { sendAction(["action": "passport_feedback", "event": event]) }
    func linkStatus(_ error: String = "") {
        let fresh = Date().timeIntervalSince1970 - (snapshot["at"] as? Double ?? 0) < 8
        feedback(["kind": "link", "connected": ready && audioReady && fresh,
                  "volume": volume, "error": error,"firmware":firmware,"petNameSupported":petNameSupported])
        lastFeedback = Date()
    }
    func update(_ value: [String: Any]) {
        snapshot = value
        let wanted = (value["passport"] as? [String:Any])?["enabled"] as? Bool == true
        if wanted != enabled {
            enabled = wanted
            if enabled {
                if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
                nextConnect = .distantPast
            } else {
                stop()
            }
        }
        guard enabled else { return }
        refreshPresentation()
        updatePet()
        reconcileActions()
        if ready && Date().timeIntervalSince(lastState) >= 1 { sendState() }
    }
    func stop() {
        presenter.reset()
        refreshPresentation()
        dictation.reset()
        central?.stopScan()
        scanning = false
        if let peer { central?.cancelPeripheralConnection(peer) }
        ready = false; audioReady = false; fragments = []; writing = false; pending = [:]
        updatePet()
        linkStatus()
    }
    func tick() {
        refreshPresentation()
        updatePet();petSync.tick()
        guard enabled, let central else { return }
        if Date().timeIntervalSince1970 - (snapshot["at"] as? Double ?? 0) > 8 {
            if ready {
                var offline = PassportProtocol.state(snapshot, epoch: epoch)
                offline["enabled"] = false; offline["monitor"] = false
                offline["alerts"] = []; offline["total"] = 0; offline["running"] = 0
                send(offline)
                linkStatus("电脑提醒服务暂未更新，已暂停工牌播报")
            }
            return
        }
        if ready && Date().timeIntervalSince(lastFrame) > 12 {
            linkStatus("工牌连接超时，正在重连")
            if let peer { central.cancelPeripheralConnection(peer) }
            ready = false
        }
        if let peer, peer.state == .connecting, Date().timeIntervalSince(connectStarted) > 12 {
            central.cancelPeripheralConnection(peer)
        }
        if ready {
            if Date().timeIntervalSince(lastState) > 2 { sendState() }
            if Date().timeIntervalSince(lastFeedback) > 2 { linkStatus(audioReady ? "" : "工牌音频未就绪") }
        } else if peer == nil, central.state == .poweredOn, Date() >= nextConnect, !scanning {
            scan()
        }
        for (id, value) in Array(pending) where value.3 < Date() {
            finishAction(id, ok: false, message: "尚未同步，请重试")
        }
    }
    func updatePet() {
        let urgent=(snapshot["alerts"] as? [[String:Any]] ?? []).contains { ["approval","question","blocked"].contains($0["kind"] as? String ?? "") }
        let fresh=Date().timeIntervalSince1970-(snapshot["at"] as? Double ?? 0)<8
        petSync.unsupportedReason = petSupported ? "蓝牙图片通道尚未发现，正在等待连接刷新" : (firmware.hasPrefix("0.3.") || firmware.hasPrefix("0.4.")) ? "工牌图片存储未就绪，正在检查" : "更新工牌后即可自动同步宠物形象"
        petSync.maximumPacket=min(244,peer?.maximumWriteValueLength(for:.withoutResponse) ?? 244)
        petSync.update(enabled:enabled,connected:ready && fresh,supported:petSupported && assetCharacteristic != nil,
                       blocked:presenter.enabled || dictation.activeID != nil || snapshot["speakingId"] is String || urgent,epoch:epoch)
    }
    func scan() {
        guard enabled, let central, central.state == .poweredOn else { return }
        scanning = true; scanResults = [:]
        central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        linkStatus("正在寻找工牌；首次连接请核对屏幕配对码")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.enabled, self.scanning else { return }
            self.central?.stopScan(); self.scanning = false
            let saved = UserDefaults.standard.string(forKey: "PassportPeripheral")
            let choices = Array(self.scanResults.values)
            let chosen = choices.first { $0.identifier.uuidString == saved } ?? (choices.count == 1 ? choices.first : nil)
            guard let chosen else {
                self.nextConnect = Date().addingTimeInterval(5)
                self.linkStatus(choices.count > 1 ? "发现多张工牌，请只开启需要连接的一张" : "尚未找到工牌，请确认工牌已开机")
                return
            }
            self.peer = chosen; chosen.delegate = self; self.connectStarted = Date()
            self.central?.connect(chosen, options: nil)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            ready = false
            linkStatus(central.state == .unauthorized ? "请在系统设置中允许本应用使用蓝牙" : "请打开 Mac 蓝牙")
        } else if enabled { nextConnect = .distantPast }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        scanResults[peripheral.identifier] = peripheral
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral)
    }
    func disconnected(_ peripheral: CBPeripheral) {
        guard peer?.identifier == peripheral.identifier else { return }
        presenter.reset(); refreshPresentation()
        dictation.reset(); voiceSupported = false; voiceSubscribed = false
        ready = false; audioReady = false; peer = nil; rx = nil; writing = false;assetCharacteristic=nil;petSupported=false
        fragments = []; receiveBuffer = Data(); pending = [:]
        nextConnect = Date().addingTimeInterval(3)
        linkStatus(enabled ? "工牌已断开，正在重连" : "")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            central?.cancelPeripheralConnection(peripheral); return
        }
        peripheral.discoverCharacteristics([Self.rxID, Self.txID, Self.voiceID, Self.assetID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { central?.cancelPeripheralConnection(peripheral); return }
        rx = service.characteristics?.first { $0.uuid == Self.rxID }
        assetCharacteristic=service.characteristics?.first {$0.uuid == Self.assetID}
        guard rx != nil, let tx = service.characteristics?.first(where: { $0.uuid == Self.txID }) else { return }
        if let voice = service.characteristics?.first(where: { $0.uuid == Self.voiceID }) {
            peripheral.setNotifyValue(true, for: voice)
        }
        peripheral.setNotifyValue(true, for: tx)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            linkStatus("蓝牙配对未完成，请核对工牌上的六位配对码"); return
        }
        if characteristic.uuid == Self.voiceID { voiceSubscribed = true; return }
        send(["v": 1, "type": "hello", "epoch": epoch])
    }
    func sendState() {
        guard ready else { return }
        var state = PassportProtocol.state(snapshot, epoch: epoch)
        state.merge(presenter.state(presentationContext(), now:Date().timeIntervalSince1970)) { _,new in new }
        send(state)
        lastState = Date()
    }
    func send(_ object: [String: Any]) {
        guard let peer, let rx, peer.state == .connected,
              let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count < 4096 else { return }
        let data = encoded + Data([10])
        let size = max(1, peer.maximumWriteValueLength(for: .withResponse))
        // At most one small state plus a few control messages may be outstanding.
        guard fragments.count + (data.count + size - 1) / size <= 128 else {
            central?.cancelPeripheralConnection(peer); return
        }
        for start in stride(from: 0, to: data.count, by: size) {
            fragments.append(data.subdata(in: start..<min(data.count, start + size)))
        }
        _ = rx
        drain()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral:CBPeripheral) {petSync.pump()}
    func drain() {
        guard !writing, let peer, let rx, !fragments.isEmpty else { return }
        writing = true
        peer.writeValue(fragments.removeFirst(), for: rx, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writing = false
        if error != nil { central?.cancelPeripheralConnection(peripheral); return }
        drain()
        if !writing && fragments.isEmpty {petSync.pump()}
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == Self.voiceID {
            lastFrame = Date(); dictation.audio(data); return
        }
        receiveBuffer.append(data)
        guard receiveBuffer.count < 2048 else { receiveBuffer = Data(); return }
        while let end = receiveBuffer.firstIndex(of: 10) {
            let line = receiveBuffer[..<end]; receiveBuffer.removeSubrange(...end)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { received(object) }
        }
    }
    func received(_ object: [String: Any]) {
        guard object["v"] as? Int == 1 else { return }
        lastFrame = Date()
        switch object["type"] as? String {
        case "hello":
            ready = true; audioReady = object["audio"] as? Bool == true
            voiceSupported = object["voice"] as? Bool == true
            volume = object["volume"] as? Int ?? 60
            firmware = object["firmware"] as? String ?? ""
            presenter.hello(supported:object["presenter"] as? Bool == true, session:object["presenterSession"] as? String ?? "")
            refreshPresentation()
            petNameSupported = object["petNameSupported"] as? Bool ?? false
            petSupported = object["petSync"] as? Bool == true && object["petFormat"] as? Int == 1
            petSync.hello(sha:object["petSha"] as? String ?? "")
            if let peer { UserDefaults.standard.set(peer.identifier.uuidString, forKey: "PassportPeripheral") }
            linkStatus(audioReady ? "" : "工牌音频未就绪")
            sendState()
        case "presenter":
            var accepted = false
            if dictation.activeID == nil {
                accepted = presenter.receive(object, epoch:epoch, context:presentationContext(), now:Date().timeIntervalSince1970) {
                    PresentationKeyboard.send(next:$0, target:$1)
                }
            }
            let op = object["op"] as? String ?? ""
            if accepted && ["previous","next"].contains(op) { presentationPosted += 1 }
            presentationLastRequest = ["op":["previous","next","enable","disable"].contains(op) ? op:"invalid",
                "accepted":accepted, "at":Date().timeIntervalSince1970]
            refreshPresentation(); sendState()
        case "pet_ack":
            updatePet();petSync.receive(object)
        case "cue":
            guard ready, object["epoch"] as? String == epoch,
                  let kind = object["kind"] as? String, ["ready","complete","attention"].contains(kind) else { return }
            let diagnostic:[String:Any] = ["at":Date().timeIntervalSince1970,"kind":kind,
                "ok":object["ok"] as? Bool ?? false,"volume":object["volume"] as? Int ?? -1,
                "feedGapUs":object["feedGapUs"] as? Int ?? -1]
            if let data = try? JSONSerialization.data(withJSONObject:diagnostic,options:.sortedKeys) {
                let url = AppPaths.runtime.appendingPathComponent("passport-cue-diagnostic.json")
                try? data.write(to:url,options:.atomic)
                try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            }
        case "voice":
            guard ready, !presenter.enabled, voiceSupported, voiceSubscribed, object["epoch"] as? String == epoch else { return }
            dictation.receive(object)
        case "pong": break
        case "audio":
            guard ready, object["epoch"] as? String == epoch else { return }
            feedback(["kind": "audio", "id": object["id"] as? String ?? "",
                      "phase": object["phase"] as? String ?? "failed"])
        case "action":
            guard ready, !presenter.enabled, object["epoch"] as? String == epoch,
                  Date().timeIntervalSince1970 - (snapshot["at"] as? Double ?? 0) < 8,
                  let id = object["id"] as? String, id.count <= 40,
                  let action = object["action"] as? String else { return }
            if let result = completed[id] { send(result); return }
            if pending[id] != nil { return }
            let alerts = snapshot["alerts"] as? [[String: Any]] ?? []
            let token = object["alertId"] as? String ?? ""
            let alert = alerts.first { PassportProtocol.token($0["id"] as? String ?? "") == token }
            var command: [String: Any] = ["action": action]
            if ["ack", "snooze", "replay"].contains(action) {
                guard let original = alert?["id"] as? String else {
                    finishAction(id, ok: false, message: "提醒已更新"); sendState(); return
                }
                if action == "ack", let thread = alert?["thread"] as? String,
                   UUID(uuidString:thread) != nil, let url = URL(string:"codex://threads/"+thread) {
                    guard NSWorkspace.shared.open(url) else {
                        finishAction(id,ok:false,message:"无法打开电脑中的任务"); return
                    }
                }
                command["id"] = original
                if action == "snooze" { command["seconds"] = 300 }
            } else if action == "pause" { command["minutes"] = 15 }
            else { finishAction(id, ok: false, message: "不支持此操作"); return }
            pending[id] = (action, alert?["id"] as? String ?? "", alert?["count"] as? Int ?? 0, Date().addingTimeInterval(6))
            sendAction(command)
        default: break
        }
    }
    func reconcileActions() {
        let alerts = snapshot["alerts"] as? [[String: Any]] ?? []
        for (id, value) in Array(pending) {
            let alert = alerts.first { $0["id"] as? String == value.1 }
            let ok = value.0 == "ack" ? alert == nil :
                value.0 == "snooze" ? alert?["state"] as? String == "snoozed" :
                value.0 == "pause" ? (snapshot["mutedUntil"] as? Double ?? 0) > Date().timeIntervalSince1970 :
                (alert?["count"] as? Int ?? 0) > value.2 || snapshot["speakingId"] as? String == value.1
            if ok { finishAction(id, ok: true, message: value.0 == "ack" ? "已接手" : "已同步") }
        }
    }
    func finishAction(_ id: String, ok: Bool, message: String) {
        pending.removeValue(forKey: id)
        let result: [String: Any] = ["v": 1, "type": "action_result", "epoch": epoch,
                                     "id": id, "ok": ok, "message": message]
        if completed.count > 64 { completed.removeAll() }
        completed[id] = result
        send(result)
    }
    func command(_ command: [String: Any]) {
        guard let id = command["id"] as? String else { return }
        if command["op"] as? String == "stop" {
            send(["v": 1, "type": "stop", "epoch": epoch, "id": id]); return
        }
        guard ready, !presenter.enabled, audioReady, dictation.activeID == nil, command["op"] as? String == "play" else {
            feedback(["kind": "audio", "id": id, "phase": "failed"]); return
        }
        send(["v": 1, "type": "play", "epoch": epoch, "id": id,
              "alertId": PassportProtocol.token(command["alertId"] as? String ?? ""),
              "phrase": command["phrase"] as? String ?? "test"])
    }
}
