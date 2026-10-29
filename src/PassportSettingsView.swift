import AppKit
import SwiftUI

struct PassportProductImage: View {
    var width: CGFloat = 44
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource:"AIPassport",withExtension:"png"), let image = NSImage(contentsOf:url) {
                Image(nsImage:image).resizable().scaledToFit()
            } else { Image(systemName:"person.text.rectangle").resizable().scaledToFit().padding(5) }
        }.frame(width:width,height:width*1.52).accessibilityHidden(true)
    }
}
struct PassportAccessoryCard: View {
    @ObservedObject var model: VoicePanelModel
    var body: some View {
        Button { model.passportSettingsOpen = true } label: {
            HStack(spacing:13) {
                PassportProductImage(width:34)
                VStack(alignment:.leading,spacing:5) {
                    HStack(spacing:7) {
                        Text("AI Passport").font(VoiceTheme.font(13,medium:true))
                        Circle().fill(model.passportConnected ? VoiceTheme.success : VoiceTheme.secondary.opacity(0.4)).frame(width:5,height:5)
                        Text(model.passportConnected ? "已连接" : model.passportEnabled ? "未连接" : "可选配件")
                            .font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                    }
                    Text(model.presentationActive ? "演示模式 · 提醒暂缓播报" : model.passportEnabled ? "\(model.passportPetName) · \(model.passportVoiceEnabled ? "播报已开启" : "仅同步屏幕")" : "把任务提醒带在身边")
                        .font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary)
                }
                Spacer(minLength:4)
                Text("设置").font(VoiceTheme.font(11,medium:true)).foregroundColor(VoiceTheme.green)
                Image(systemName:"chevron.right").font(.system(size:10,weight:.medium)).foregroundColor(VoiceTheme.secondary)
            }.padding(.horizontal,14).padding(.vertical,10).frame(maxWidth:.infinity,alignment:.leading)
                .background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:15,style:.continuous))
                .overlay(RoundedRectangle(cornerRadius:15,style:.continuous).stroke(VoiceTheme.line,lineWidth:0.6))
        }.buttonStyle(.plain).accessibilityLabel("AI Passport 设置，\(model.passportConnected ? "已连接" : model.passportEnabled ? "等待连接" : "可选配件")")
            .padding(.horizontal,18).padding(.bottom,12)
    }
}
struct PassportSettingsView: View {
    @ObservedObject var model: VoicePanelModel
    private func row<Content: View>(_ title:String,_ caption:String,@ViewBuilder control:()->Content) -> some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(VoiceTheme.font(13,medium:true))
                if !caption.isEmpty { Text(caption).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal:false,vertical:true) }
            }
            Spacer(minLength:5); control()
        }.padding(13)
    }
    private func group<Content:View>(@ViewBuilder content:()->Content) -> some View {
        VStack(spacing:0,content:content).background(VoiceTheme.paper).clipShape(RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).stroke(VoiceTheme.line,lineWidth:1))
    }
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("AI Passport").font(VoiceTheme.font(17,medium:true))
                Spacer(); IconAction(symbol:"xmark",label:"返回提醒") { model.passportSettingsOpen = false }
            }.padding(.horizontal,20).padding(.top,16).padding(.bottom,14)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    HStack(spacing:17) {
                        PassportProductImage(width:58)
                        VStack(alignment:.leading,spacing:5) {
                            Text("AI Passport").font(VoiceTheme.font(20,medium:true))
                            Text(model.passportPetName).font(VoiceTheme.font(13,medium:true)).foregroundColor(VoiceTheme.ink)
                            Label(model.passportConnected ? "已连接" : model.passportEnabled ? "等待连接" : "可选配件",systemImage:model.passportConnected ? "checkmark.circle.fill":"antenna.radiowaves.left.and.right")
                                .font(VoiceTheme.font(10,medium:true)).foregroundColor(model.passportConnected ? VoiceTheme.success:VoiceTheme.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,4)
                    group {
                        row("启用 AI Passport","同步任务、剩余额度和屏保，使用按住听写。") {
                            Toggle("启用 AI Passport",isOn:Binding(get:{model.passportEnabled},set:{model.configurePassport(["enabled":$0])}))
                                .toggleStyle(PersistentSwitchStyle()).labelsHidden().disabled(!model.connected)
                        }
                        if model.passportEnabled {
                            VoiceTheme.line.frame(height:1)
                            row("连接状态",model.passportConnected ? "蓝牙已连接，信息会自动同步。" : model.passportLinkError) {
                                Image(systemName:model.passportConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                                    .foregroundColor(model.passportConnected ? VoiceTheme.success : VoiceTheme.secondary)
                            }
                        }
                    }
                    if model.passportEnabled {
                        Text("演示翻页").font(VoiceTheme.font(11,medium:true)).foregroundColor(VoiceTheme.secondary)
                        group {
                            row("演示模式",model.presentationDetail) {
                                Toggle("演示模式",isOn:Binding(get:{model.presentationActive},set:model.changePresentation))
                                    .toggleStyle(PersistentSwitchStyle()).labelsHidden()
                                    .disabled(!model.connected || !model.passportConnected || !model.presentationSupported)
                            }
                            VoiceTheme.line.frame(height:1)
                            row("演示软件","仅控制前台演示软件；切到其他应用时暂停。") {
                                Picker("演示软件",selection:Binding(get:{model.presentationTarget},set:model.changePresentationTarget)) {
                                    ForEach(PresentationTarget.allCases,id:\.rawValue) { choice in Text(choice.name).tag(choice.rawValue) }
                                }.labelsHidden().frame(width:112)
                            }
                            Text("上键上一步，下键下一步；长按下键退出。演示时听写暂停、确认键不跳转任务，新的提醒保留待处理。")
                                .font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                                .fixedSize(horizontal:false,vertical:true).padding(.horizontal,13).padding(.bottom,13)
                        }
                    }
                    Text("提醒声音").font(VoiceTheme.font(11,medium:true)).foregroundColor(VoiceTheme.secondary)
                    group {
                        row("电脑播报","从电脑选择的扬声器或耳机播报。") {
                            Toggle("电脑播报",isOn:Binding(get:{model.computerAudioEnabled},set:{model.action(["action":"set_computer_audio_enabled","enabled":$0])}))
                                .toggleStyle(PersistentSwitchStyle()).labelsHidden().disabled(!model.connected)
                        }
                        VoiceTheme.line.frame(height:1)
                        row("AI Passport 播报","可与电脑同时开启；关闭后仍显示任务、可用听写。") {
                            Toggle("AI Passport 播报",isOn:Binding(get:{model.passportVoiceEnabled},set:{model.configurePassport(["voiceEnabled":$0])}))
                                .toggleStyle(PersistentSwitchStyle()).labelsHidden().disabled(!model.connected || !model.passportEnabled)
                        }
                        if model.passportEnabled {
                            VoiceTheme.line.frame(height:1)
                            row("试听 AI Passport","按工牌确认键或点已接手，结束测试提醒。") {
                                Button("试听") { model.passportSettingsOpen=false;model.action(["action":"test","target":"passport"]) }
                                    .buttonStyle(PanelButtonStyle()).disabled(!model.canTestPassport)
                            }
                        }
                    }
                    if model.passportEnabled {
                        Text("屏保伙伴").font(VoiceTheme.font(11,medium:true)).foregroundColor(VoiceTheme.secondary)
                        group {
                            HStack(spacing:12) {
                                if let image=model.petPreview ?? Bundle.main.url(forResource:"PetNOMI",withExtension:"png").flatMap(NSImage.init(contentsOf:)) {
                                    Image(nsImage:image).resizable().scaledToFit().frame(width:49,height:54).accessibilityHidden(true)
                                }
                                VStack(alignment:.leading,spacing:3) {
                                    Text("自动跟随 Codex").font(VoiceTheme.font(13,medium:true))
                                    Text(model.petSyncDetail).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.secondary).fixedSize(horizontal:false,vertical:true)
                                    if model.petSync["state"] as? String == "transferring" || model.petSync["state"] as? String == "paused" {
                                        ProgressView(value:model.petSyncProgress,total:100).tint(VoiceTheme.green)
                                    }
                                }; Spacer()
                            }.padding(13)
                            VoiceTheme.line.frame(height:1)
                            VStack(alignment:.leading,spacing:8) {
                                Text("工牌上的宠物昵称").font(VoiceTheme.font(12,medium:true))
                                HStack(spacing:8) {
                                    TextField("Codex",text:$model.passportPetNameDraft).textFieldStyle(.roundedBorder)
                                        .font(VoiceTheme.font(13)).accessibilityLabel("工牌宠物昵称")
                                    Button("保存") { model.configurePassport(["petName":model.passportPetNameDraft]) }
                                        .buttonStyle(PanelButtonStyle()).disabled(!model.connected || model.passportPetNameDraft == model.passportPetName)
                                }
                                Text("只用于工牌显示，最多8个字。\(model.passportPetNameSupported ? "连接后自动应用。" : "更新工牌后应用昵称。")")
                                    .font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                            }.padding(13)
                        }
                        group {
                            row("按住听写","长按确认讲话，单音开始、双音完成；由你发送文字。") {
                                Button("设置",action:model.setupPassport).buttonStyle(PanelButtonStyle())
                            }
                        }
                    }
                    if !model.passportSettingsError.isEmpty {
                        Text(model.passportSettingsError).font(VoiceTheme.font(11)).foregroundColor(VoiceTheme.amber)
                    }
                    if model.passportEnabled && !model.passportFirmware.isEmpty {
                        Text("固件 \(model.passportFirmware)").font(VoiceTheme.font(10)).foregroundColor(VoiceTheme.secondary)
                    }
                }.padding(.horizontal,20).padding(.bottom,20)
            }.frame(maxHeight:model.maximumSettingsHeight)
        }.onAppear {model.passportPetNameDraft=model.passportPetName;model.passportPetNameDraftBaseline=model.passportPetName}
            .onChange(of:model.passportPetName) {name in
                if model.passportPetNameDraft==model.passportPetNameDraftBaseline {model.passportPetNameDraft=name}
                model.passportPetNameDraftBaseline=name
            }
    }
}
