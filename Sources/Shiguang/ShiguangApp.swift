import SwiftUI
import AppKit
import DiaryCore

@main
struct ShiguangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model=AppModel()
    var body: some Scene {
        Window(L10n.t("拾光"),id:"main") {
            RootView().environmentObject(model)
                .environment(\.locale,Locale(identifier:model.language))
                .frame(minWidth:800,minHeight:600)
                .preferredColorScheme(model.preferences.appearance=="light" ? .light : model.preferences.appearance=="dark" ? .dark : nil)
                .task {delegate.model=model; await model.start()}
        }.defaultSize(width:1180,height:780)
        .commands {
            CommandGroup(replacing:.appInfo) {
                Button(L10n.t("关于拾光")) {AboutPanel.show()}
            }
            CommandGroup(replacing:.newItem) {Button(L10n.t("写一篇日记")) {Task {await model.newEntry()}}.keyboardShortcut("n").disabled(!model.unlocked)}
            CommandGroup(replacing:.saveItem) {Button(L10n.t("立即保存")) {Task {await model.flush()}}.keyboardShortcut("s").disabled(!model.unlocked)}
            CommandGroup(after:.textEditing) {
                Button(L10n.t("搜索日记")) {model.focusSearch=true}.keyboardShortcut("f").disabled(!model.unlocked)
                Button(L10n.t("专注写作")) {model.focusMode.toggle()}.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(!model.unlocked)
            }
            CommandGroup(replacing:.appSettings) {Button(L10n.t("设置…")) {model.showSettings=true}.keyboardShortcut(",").disabled(!model.unlocked)}
            CommandGroup(after:.appInfo) {Button(L10n.t("锁定日记")) {Task {await model.lock()}}.keyboardShortcut("l",modifiers:[.command,.shift]).disabled(!model.unlocked)}
        }
    }
}

@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    weak var model:AppModel?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {NSApp.activate(ignoringOtherApps:true); NSApp.windows.forEach {$0.delegate=self}}
    }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        guard let model,model.unlocked else {return .terminateNow}
        Task {
            if await model.flush(finishingEditing:true) {await model.lock(); sender.reply(toApplicationShouldTerminate:true)}
            else {sender.reply(toApplicationShouldTerminate:false)}
        }
        return .terminateLater
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        guard let model,model.unlocked else {return true}
        Task {if await model.flush(finishingEditing:true) {await model.lock(); sender.orderOut(nil)}}
        return false
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool {
        if !hasVisibleWindows {sender.windows.first?.makeKeyAndOrderFront(nil)}
        return true
    }
}
