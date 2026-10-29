import AppKit
import SwiftUI

enum StartupError:Error {case failed(String)}

@main struct RenderVoiceInterface {
    @MainActor static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let arguments=CommandLine.arguments
        let folder=URL(fileURLWithPath:arguments[arguments.firstIndex(of:"--output")!+1],isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let variants=["ready","tasks","many","low","offline","dark","usage","passport","settings","fresh","presenter","presenter-paused"]
        for variant in variants {
            let model=VoicePanelModel(),now=Date().timeIntervalSince1970
            model.connectionConfigured=true;model.startupEnabled=true;model.presentationSupported=true
            model.maximumListHeight=260;model.maximumSettingsHeight=480
            model.snapshot=[
                "at":now,"enabled":true,"alerts":[],"monitor":["state":"connected"],
                "audio":["device":"MacBook Pro 扬声器","available":true,"ready":true,"followSystem":true,"computerEnabled":true,"computerAvailable":true,"computerReady":true,"defaultName":"MacBook Pro 扬声器"],
                "speech":["voice":"Tingting","ready":true,"intervals":[30,60,180],"voices":[["id":"Tingting","name":"Tingting · 普通话","language":"zh_CN"]]],
                "passport":["enabled":true,"connected":true,"voiceEnabled":true,"petName":"Codex","firmware":"0.4.0-presenter","petNameSupported":true,"petSync":["state":"synced","detail":"已同步 · 自动跟随 Codex","sha":"preview"]],
                "usage":["state":"ready","remainingPercent":93,"fetchedAt":now,"lastAttemptAt":now-20,"planType":"pro","windows":[["id":"primary","remainingPercent":93,"windowMinutes":300,"resetsAt":now+12600],["id":"secondary","remainingPercent":98,"windowMinutes":10080,"resetsAt":now+360000]]]
            ]
            if variant=="tasks" || variant=="many" {
                model.snapshot["alerts"]=[
                    ["id":"preview-approval","kind":"approval","title":"网站更新与发布","detail":"需要确认下一步操作","nextAt":now+75,"count":1,"state":"pending"],
                    ["id":"preview-result","kind":"result","title":"本周工作周报已整理完成","nextAt":now+120,"count":1,"state":"pending"]
                ];model.listContentHeight=300
                if variant=="tasks" {model.snapshot["alerts"]=Array((model.snapshot["alerts"] as! [[String:Any]]).prefix(1));model.listContentHeight=160}
            }
            if variant=="low" {var usage=model.snapshot["usage"] as! [String:Any];usage["remainingPercent"]=12;usage["windows"]=[["id":"primary","remainingPercent":12,"windowMinutes":300,"resetsAt":now+12600],["id":"secondary","remainingPercent":62,"windowMinutes":10080,"resetsAt":now+360000]];model.snapshot["usage"]=usage}
            if variant=="offline" {model.snapshot["usage"]=["state":"stale","remainingPercent":93,"fetchedAt":now-240,"message":"用量数据已过期，等待重新同步。"];var badge=model.snapshot["passport"] as! [String:Any];badge["connected"]=false;model.snapshot["passport"]=badge}
            if variant=="fresh" {model.presentationSupported=false;model.passportSettingsOpen=true;model.snapshot["passport"]=["enabled":true,"connected":false,"voiceEnabled":false,"petName":"Codex","petNameSupported":true]}
            if variant=="usage" {model.usageOpen=true}
            if variant=="passport" {model.passportSettingsOpen=true}
            if variant=="settings" {model.settingsOpen=true}
            if variant.hasPrefix("presenter") {
                model.passportSettingsOpen=true;model.presentationSupported=true;model.presentationActive=true
                model.presentationStatus=variant=="presenter" ? 0:1
            }
            let dark=variant=="dark"
            app.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
            let base=AnyView(VoicePanelView(model:model))
            let content=base.environment(\.colorScheme,dark ? .dark:.light).environment(\.locale,Locale(identifier:"zh_CN"))
            // AppKit hosting also draws native menus and scroll views, which
            // ImageRenderer intentionally omits from a SwiftUI-only snapshot.
            let host=NSHostingView(rootView:content)
            host.sizingOptions=[.intrinsicContentSize]
            let window=NSWindow(contentRect:NSRect(x:-5000,y:-5000,width:PanelChrome.width,height:900),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
            window.contentView=host
            host.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width:PanelChrome.width,height:host.fittingSize.height))
            window.orderFrontRegardless()
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width:PanelChrome.width,height:host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw StartupError.failed("Native UI render failed")}
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let data=bitmap.representation(using:.png,properties:[:]) else {throw StartupError.failed("PNG render failed")}
            try data.write(to:folder.appendingPathComponent(variant+".png"))
            print("\(variant): \(Int(host.bounds.width)) x \(Int(host.bounds.height)) pt")
            window.orderOut(nil);window.close()
        }
    }
}
