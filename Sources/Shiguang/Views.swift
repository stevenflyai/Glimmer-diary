import SwiftUI
import AppKit
import DiaryCore

// Use the back-deployable property wrapper, without requiring the SDK 27 State macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

enum JournalTheme {
    static func color(_ light:String,_ dark:String) -> Color {
        Color(nsColor:NSColor(name:nil) {appearance in
            let hex=appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? dark:light
            let number=Int(hex,radix:16) ?? 0
            return NSColor(srgbRed:Double((number>>16)&255)/255,green:Double((number>>8)&255)/255,blue:Double(number&255)/255,alpha:1)
        })
    }
    static let paper=color("F7F3EB","20251F")
    static let sidebar=color("EDE9DF","181D19")
    static let list=color("F2EFE7","1C221D")
    static let ink=color("293B32","E9E8DF")
    static let muted=color("667168","ACB5AA")
    static let accent=color("365B46","A4C6AA")
    static let selection=color("DEE6D9","314133")
}

struct RootView:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        Group {
            if model.recoveryToShow != nil {RecoveryKeyView()}
            else if model.unlocked {JournalWindow()}
            else {UnlockView()}
        }
        .background(JournalTheme.paper).foregroundStyle(JournalTheme.ink).tint(JournalTheme.accent)
        .alert(L10n.t("拾光"),isPresented:Binding(get:{model.error != nil},set:{if !$0{model.error=nil}})) {Button(L10n.t("知道了"),role:.cancel){model.error=nil}} message:{Text(model.error ?? "")}
    }
}

struct UnlockView:View {
    @EnvironmentObject var model:AppModel
    @ViewState private var password=""
    @ViewState private var confirm=""
    @ViewState private var recovery=""
    @ViewState private var recoveryMode=false
    @ViewState private var backup:URL?
    @FocusState private var focus:Bool
    var body:some View {
        VStack(spacing:0) {
            Image(systemName:"book.closed.fill").font(.system(size:48,weight:.light)).foregroundStyle(JournalTheme.accent).padding(.bottom,22).accessibilityHidden(true)
            Text(L10n.t("拾光")).font(.custom("Songti SC",size:36)).tracking(model.language=="en" ? 1:7)
            Text(L10n.t("把生活，轻轻收好。")).foregroundStyle(JournalTheme.muted).padding(.top,8).padding(.bottom,32)
            if recoveryMode {
                Text(L10n.t("使用恢复密钥")).font(.headline).padding(.bottom,10)
                TextField(L10n.t("完整恢复密钥"),text:$recovery).textFieldStyle(.roundedBorder).privacySensitive()
                SecureField(L10n.t("设置新的日记密码（至少 10 字符）"),text:$password).textFieldStyle(.roundedBorder).padding(.top,8)
                SecureField(L10n.t("再次输入新密码"),text:$confirm).textFieldStyle(.roundedBorder).padding(.top,8)
                PasswordSetupFeedback(password:password,confirmation:confirm).padding(.top,10)
                Button(L10n.t("恢复访问并更新密码")) {Task{await model.recover(key:recovery,password:password);password="";confirm="";recovery=""}}.buttonStyle(.borderedProminent).controlSize(.large).padding(.top,16).disabled(model.busy || password.count<10 || password != confirm || recovery.isEmpty)
                Button(L10n.t("返回密码解锁")){recoveryMode=false;password="";confirm="";recovery=""}.buttonStyle(.link).padding(.top,16)
            } else {
                if !model.hasVault {Text(L10n.t("创建你的私人日记")).font(.headline).padding(.bottom,12)}
                SecureField(model.hasVault ? L10n.t("日记密码"):L10n.t("设置密码，至少 10 个字符"),text:$password).textFieldStyle(.roundedBorder).controlSize(.large).focused($focus).onSubmit{submit()}
                if !model.hasVault {
                    SecureField(L10n.t("再次输入密码"),text:$confirm).textFieldStyle(.roundedBorder).controlSize(.large).padding(.top,8).onSubmit{submit()}
                    PasswordSetupFeedback(password:password,confirmation:confirm).padding(.top,10)
                }
                TimelineView(.periodic(from:Date(),by:1)) {context in
                    let wait=max(0,Int(ceil((model.retryAfter ?? .distantPast).timeIntervalSince(context.date))))
                    Button(wait>0 ? L10n.t("请在 \(wait) 秒后重试") : model.hasVault ? L10n.t("解锁日记"):L10n.t("创建加密日记")) {submit()}
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth:.infinity).padding(.top,16)
                        .disabled(model.busy || wait>0 || password.isEmpty || (!model.hasVault && (password.count<10 || confirm != password)))
                }
                if model.hasVault {
                    if model.touchIDEnabled {Button{Task{await model.unlockWithTouchID()}}label:{Label(L10n.t("使用 Touch ID"),systemImage:"touchid")}.buttonStyle(.plain).padding(.top,18).disabled(model.busy)}
                    Button(L10n.t("使用恢复密钥")){recoveryMode=true;password=""}.buttonStyle(.link).padding(.top,18)
                } else {Text(L10n.t("无须注册账号。密码和恢复密钥由你保管。")).font(.caption).foregroundStyle(JournalTheme.muted).padding(.top,18)}
            }
            if model.busy {ProgressView().controlSize(.small).padding(.top,16)}
            if let notice=model.notice {Text(notice).font(.caption).foregroundStyle(JournalTheme.muted).multilineTextAlignment(.center).padding(.top,18)}
            LanguagePicker().padding(.top,24)
            Button(L10n.t("从加密备份恢复…")){backup=model.chooseRestore()}.buttonStyle(.link).padding(.top,30).disabled(model.busy)
        }.frame(width:340).frame(maxWidth:.infinity,maxHeight:.infinity).padding(40)
        .task {focus=true}
        .sheet(item:Binding(get:{backup.map(BackupSelection.init)},set:{backup=$0?.url})) {selection in RestoreBackupView(url:selection.url)}
        .onDisappear {password="";confirm="";recovery=""}
    }
    private func submit() {
        guard !password.isEmpty,!model.busy else{return}
        if !model.hasVault && (password.count<10 || password != confirm){return}
        let value=password;password="";confirm=""
        Task {if model.hasVault {await model.unlock(password:value)}else{await model.create(password:value)}}
    }
}

struct PasswordSetupFeedback:View {
    @EnvironmentObject var model:AppModel
    let password:String
    let confirmation:String
    private var simplePassword:Bool {password.allSatisfy(\.isNumber) || Set(password).count==1}
    var body:some View {
        let _=model.language
        VStack(alignment:.leading,spacing:6) {
            if password.isEmpty {
                Label(L10n.t("至少 10 个字符，推荐使用一段独特的长短语。"),systemImage:"info.circle").foregroundStyle(JournalTheme.muted)
            } else if password.count<10 {
                Label(L10n.t("密码太短：当前 \(password.count) 个字符，至少需要 10 个。"),systemImage:"exclamationmark.circle").foregroundStyle(.red)
            } else if simplePassword {
                Label(L10n.t("密码容易被猜到，建议避免纯数字或重复同一个字符。"),systemImage:"exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label(L10n.t("已达到密码的最低长度要求。"),systemImage:"checkmark.circle").foregroundStyle(JournalTheme.accent)
            }
            if !password.isEmpty || !confirmation.isEmpty {
                if confirmation.isEmpty {
                    Label(L10n.t("请再次输入密码以确认。"),systemImage:"info.circle").foregroundStyle(JournalTheme.muted)
                } else if password != confirmation {
                    Label(L10n.t("两次输入的密码不一致，请检查。"),systemImage:"exclamationmark.circle").foregroundStyle(.red)
                } else {
                    Label(L10n.t("两次输入的密码一致。"),systemImage:"checkmark.circle").foregroundStyle(JournalTheme.accent)
                }
            }
        }.font(.caption).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
        .accessibilityElement(children:.combine)
    }
}

struct RecoveryKeyView:View {
    @EnvironmentObject var model:AppModel
    @ViewState private var check=""
    @ViewState private var copied=false
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Label(L10n.t("先把恢复密钥收好"),systemImage:"key.horizontal").font(.title2)
            Text(L10n.t("忘记密码时，你可以用它在本机恢复访问。它和密码一样重要，请放在与这台 Mac 分开的安全位置。"))
            Text(model.recoveryToShow ?? "").font(.system(size:18,design:.monospaced)).textSelection(.enabled).padding(20).frame(maxWidth:.infinity,alignment:.leading).background(JournalTheme.list,in:RoundedRectangle(cornerRadius:8)).privacySensitive()
            HStack {
                Button(copied ? L10n.t("已复制（45 秒后清除）"):L10n.t("复制密钥")) {
                    guard let value=model.recoveryToShow else{return}
                    NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string);copied=true
                    Task {try? await Task.sleep(for:.seconds(45));if NSPasteboard.general.string(forType:.string)==value{NSPasteboard.general.clearContents()}}
                }
                Button(L10n.t("保存为文件…")) {saveKey()}
            }
            Text(L10n.t("如果密码、恢复密钥和可用的设备解锁途径全部丢失，旧日记将无法恢复。")).font(.callout).foregroundStyle(JournalTheme.muted)
            TextField(L10n.t("核对密钥最后 8 位"),text:$check).textFieldStyle(.roundedBorder).frame(width:230)
            Toggle(L10n.t("我已在应用之外妥善保存恢复密钥"),isOn:$model.recoveryConfirmed)
            Button(L10n.t("开始记录")) {check="";model.finishRecoverySetup()}.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.recoveryConfirmed || check.uppercased() != String((model.recoveryToShow ?? "").suffix(8)))
        }.frame(maxWidth:570).padding(40).frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func saveKey() {
        let panel=NSSavePanel();panel.nameFieldStringValue=L10n.t("拾光恢复密钥.txt");panel.allowedContentTypes=[.plainText];panel.message=L10n.t("此文件可以解锁日记，请存放在安全位置，避免与保险库一起丢失。")
        if panel.runModal() == .OK,let url=panel.url,let key=model.recoveryToShow {do{try VaultEncryption.atomicWrite(Data((L10n.t("拾光恢复密钥\n\n")+key+L10n.t("\n\n请妥善保管，不要发送给他人。\n")).utf8),to:url)}catch{model.error=error.localizedDescription}}
    }
}

struct JournalWindow:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        VStack(spacing:0) {
            HSplitView {
                if !model.focusMode {
                    SidebarView().frame(minWidth:164,idealWidth:176,maxWidth:184)
                    EntryListView().frame(minWidth:220,idealWidth:248,maxWidth:268)
                }
                EditorPane().frame(minWidth:380,maxWidth:.infinity,maxHeight:.infinity)
            }
            if let notice=model.notice {
                HStack {Image(systemName:"info.circle");Text(notice).lineLimit(3);Spacer();Button{model.notice=nil}label:{Image(systemName:"xmark")}.buttonStyle(.plain).accessibilityLabel(L10n.t("关闭提示"))}.font(.caption).foregroundStyle(JournalTheme.muted).padding(.horizontal,16).padding(.vertical,8).background(JournalTheme.sidebar)
            }
        }
        .sheet(isPresented:$model.showSettings){SettingsView()}
        .sheet(isPresented:$model.showWeather){WeatherView()}
        .sheet(isPresented:$model.showVersions){VersionsView()}
        .sheet(isPresented:$model.showExport){ExportView()}
        .sheet(isPresented:Binding(get:{model.photoPreview != nil},set:{if !$0{model.photoPreview=nil}})) {
            VStack {HStack{Text(L10n.t("照片预览")).font(.headline);Spacer();Button(L10n.t("完成")){model.photoPreview=nil}};if let image=model.photoPreview {Image(nsImage:image).resizable().scaledToFit().frame(maxWidth:900,maxHeight:650)}}.padding(24).frame(minWidth:500,minHeight:350)
        }
    }
}

struct SidebarView:View {
    @EnvironmentObject var model:AppModel
    @ViewState private var newNotebook=false
    @ViewState private var notebookName=""
    var body:some View {
        VStack(alignment:.leading,spacing:24) {
            Button{Task{await model.newEntry()}}label:{Label(L10n.t("写一篇日记"),systemImage:"plus").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).controlSize(.large)
            VStack(spacing:5) {row(L10n.t("全部日记"),"book.pages",.all);row(L10n.t("日历"),"calendar",.calendar);row(L10n.t("往年今日"),"clock.arrow.circlepath",.memories);row(L10n.t("收藏"),"star",.favorites)}
            VStack(alignment:.leading,spacing:6) {
                HStack{Text(L10n.t("我的日记本")).font(.caption).foregroundStyle(JournalTheme.muted);Spacer();Button{newNotebook=true}label:{Image(systemName:"plus")}.buttonStyle(.plain).accessibilityLabel(L10n.t("添加日记本"))}.padding(.horizontal,8)
                ForEach(preferencesNotebooks,id:\.self){name in row(name,"book.closed",.notebook(name))}
            }
            Spacer()
            row(L10n.t("最近删除"),"trash",.trash)
            VStack(alignment:.leading,spacing:14){Label(L10n.t("本机加密保存"),systemImage:"internaldrive").font(.caption).foregroundStyle(JournalTheme.muted);HStack{Button{model.showSettings=true}label:{Label(L10n.t("设置"),systemImage:"slider.horizontal.3")}.buttonStyle(.plain);Spacer();Button{Task{await model.lock()}}label:{Image(systemName:"lock")}.buttonStyle(.plain).help(L10n.t("锁定日记 ⌘⇧L")).accessibilityLabel(L10n.t("锁定日记"))}}
        }.padding(14).padding(.top,10).frame(maxHeight:.infinity).background(JournalTheme.sidebar)
        .alert(L10n.t("新建日记本"),isPresented:$newNotebook){TextField(L10n.t("日记本名称"),text:$notebookName);Button(L10n.t("创建")){let value=notebookName.trimmingCharacters(in:.whitespacesAndNewlines);if !value.isEmpty && !model.preferences.notebooks.contains(value){model.preferences.notebooks.append(value);model.updatePreferences()};notebookName=""};Button(L10n.t("取消"),role:.cancel){notebookName=""}}
    }
    var preferencesNotebooks:[String]{model.preferences.notebooks}
    private func row(_ title:String,_ symbol:String,_ value:DiaryScope) -> some View {
        Button{Task{await model.chooseScope(value)}}label:{Label(title,systemImage:symbol).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,9).padding(.vertical,8).background(model.scope==value ? JournalTheme.selection:Color.clear,in:RoundedRectangle(cornerRadius:6))}.buttonStyle(.plain).foregroundStyle(model.scope==value ? JournalTheme.accent:JournalTheme.ink)
    }
}

struct EntryListView:View {
    @EnvironmentObject var model:AppModel
    @FocusState private var searchFocused:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Text(model.scopeTitle).font(.title3.weight(.semibold));Spacer();Menu{Picker(L10n.t("标签"),selection:$model.tagFilter){Text(L10n.t("全部标签")).tag("");ForEach(model.allTags,id:\.self){Text($0).tag($0)}};Picker(L10n.t("心情"),selection:$model.moodFilter){Text(L10n.t("全部心情")).tag("");ForEach(["平静","愉快","放松","低落","疲惫","充实"],id:\.self){Text(L10n.text($0)).tag($0)}}}label:{Image(systemName:"line.3.horizontal.decrease")}.menuStyle(.borderlessButton).frame(width:20).accessibilityLabel(L10n.t("筛选标签和心情"))}
            HStack{Image(systemName:"magnifyingglass").foregroundStyle(JournalTheme.muted);TextField(L10n.t("搜索日记"),text:$model.search).textFieldStyle(.plain).focused($searchFocused);if !model.search.isEmpty{Button{model.search=""}label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).accessibilityLabel(L10n.t("清除搜索"))}}.padding(8).background(JournalTheme.paper,in:RoundedRectangle(cornerRadius:6))
            if model.scope == .calendar {MiniCalendar()}
            if !model.tagFilter.isEmpty || !model.moodFilter.isEmpty {HStack{Text([model.tagFilter,L10n.text(model.moodFilter)].filter{!$0.isEmpty}.joined(separator:" · ")).font(.caption);Spacer();Button(L10n.t("清除")){model.tagFilter="";model.moodFilter=""}.buttonStyle(.link)}}
            ScrollView {
                LazyVStack(alignment:.leading,spacing:6) {
                    ForEach(model.filtered){item in
                        Button{Task{await model.select(item.id)}}label:{
                            VStack(alignment:.leading,spacing:8){
                                HStack{Text(item.date,format:.dateTime.month(.twoDigits).day(.twoDigits).weekday(.abbreviated));Spacer();if item.favorite{Image(systemName:"star.fill")}}.font(.caption).foregroundStyle(JournalTheme.muted)
                                Text(item.title).font(.system(size:14,weight:.medium)).lineLimit(2)
                                if !item.preview.isEmpty{Text(item.preview).font(.system(size:12)).foregroundStyle(JournalTheme.muted).lineLimit(2).lineSpacing(3)}
                                HStack(spacing:7){if item.hasPhotos{Image(systemName:"photo")};if let weather=item.weather{Image(systemName:weather.symbol);Text("\(Int(weather.temperature.rounded()))°")};if !item.mood.isEmpty{Text(L10n.text(item.mood))}}.font(.caption).foregroundStyle(JournalTheme.muted)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(model.entry?.id==item.id ? JournalTheme.selection:Color.clear,in:RoundedRectangle(cornerRadius:7))
                        }.buttonStyle(.plain)
                    }
                    if model.filtered.isEmpty {Text(model.scope == .memories ? L10n.t("往年的今天还没有记录。\n从今天的一小段开始。") : model.scope == .trash ? L10n.t("最近删除是空的。") : L10n.t("这里还没有日记。")) .font(.callout).foregroundStyle(JournalTheme.muted).padding(.top,24).frame(maxWidth:.infinity)}
                }
            }
            Text(L10n.t("\(model.filtered.count) 篇日记")+(model.scope == .trash ? L10n.t(" · 30 天后自动清理"):"")).font(.caption).foregroundStyle(JournalTheme.muted)
        }.padding(14).padding(.top,10).background(JournalTheme.list)
        .onChange(of:model.search){_,_ in model.performSearch()}
        .onChange(of:model.focusSearch){_,value in if value{searchFocused=true;model.focusSearch=false}}
    }
}

struct MiniCalendar:View {
    @EnvironmentObject var model:AppModel
    @ViewState private var month=Date()
    private let columns=Array(repeating:GridItem(.flexible(),spacing:2),count:7)
    private var start:Date{Calendar.current.date(from:Calendar.current.dateComponents([.year,.month],from:month))!}
    private var count:Int{Calendar.current.range(of:.day,in:.month,for:month)!.count}
    private var offset:Int{(Calendar.current.component(.weekday,from:start)+5)%7}
    var body:some View {
        VStack(spacing:9){
            HStack{Button{month=Calendar.current.date(byAdding:.month,value:-1,to:month)!}label:{Image(systemName:"chevron.left")}.accessibilityLabel(L10n.t("上个月"));Spacer();Text(month,format:.dateTime.year().month()).font(.caption);Spacer();Button{month=Calendar.current.date(byAdding:.month,value:1,to:month)!}label:{Image(systemName:"chevron.right")}.accessibilityLabel(L10n.t("下个月"))}.buttonStyle(.plain)
            LazyVGrid(columns:columns,spacing:4){ForEach(["一","二","三","四","五","六","日"],id:\.self){Text(L10n.text($0)).font(.caption2).foregroundStyle(JournalTheme.muted)};ForEach((0..<offset).map{"blank-\($0)"},id:\.self){_ in Color.clear.frame(height:24)};ForEach(1...count,id:\.self){day in
                let date=Calendar.current.date(byAdding:.day,value:day-1,to:start)!
                let hasEntry=model.summaries.contains {$0.deletedAt==nil && Calendar.current.isDate($0.date,inSameDayAs:date)}
                Button{model.calendarDate=date;Task{await model.chooseScope(.calendar)}}label:{VStack(spacing:1){Text("\(day)").font(.caption);Circle().fill(hasEntry ? JournalTheme.accent:Color.clear).frame(width:3,height:3)}.frame(maxWidth:.infinity).padding(.vertical,3).background(Calendar.current.isDate(date,inSameDayAs:model.calendarDate) ? JournalTheme.selection:Color.clear,in:RoundedRectangle(cornerRadius:4))}.buttonStyle(.plain).accessibilityLabel(L10n.t("\(day) 日，")+(hasEntry ? L10n.t("有日记"):L10n.t("没有日记")))
            }}
        }.padding(.vertical,7)
    }
}

struct EditorPane:View {
    @EnvironmentObject var model:AppModel
    @ViewState private var tags=""
    @ViewState private var deletePrompt=false
    @ViewState private var proposedDate:Date?
    @ViewState private var datePrompt=false
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:15) {
                if let item=model.entry {Text(item.notebook).font(.caption).foregroundStyle(JournalTheme.muted)}
                Spacer()
                if model.entry != nil && model.scope != .trash {
                    Button{model.editor.choosePhotos()}label:{Image(systemName:"photo.badge.plus")}.help(L10n.t("插入图片")).accessibilityLabel(L10n.t("插入图片")).disabled(model.importing)
                    Button{model.changed{$0.favorite.toggle()}}label:{Image(systemName:model.entry?.favorite==true ? "star.fill":"star")}.help(L10n.t("收藏日记")).accessibilityLabel(L10n.t("收藏日记"))
                    Menu{Button(L10n.t("查看历史版本…")){Task{await model.loadVersions()}};Button(L10n.t("导出日记…")){model.showExport=true};Menu(L10n.t("移动到日记本")){ForEach(model.preferences.notebooks,id:\.self){name in Button(name){model.changed{$0.notebook=name}}}};Divider();Button(L10n.t("移到最近删除"),role:.destructive){deletePrompt=true}}label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:22).accessibilityLabel(L10n.t("更多日记操作"))
                }
                Button{model.focusMode.toggle()}label:{Image(systemName:model.focusMode ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right")}.help(L10n.t("专注写作")).accessibilityLabel(model.focusMode ? L10n.t("退出专注"):L10n.t("专注写作"))
                Button{Task{await model.lock()}}label:{Image(systemName:"lock")}.help(L10n.t("锁定日记 ⌘⇧L")).accessibilityLabel(L10n.t("锁定日记"))
            }.buttonStyle(.plain).padding(.horizontal,24).padding(.vertical,16)
            Divider()
            if let entry=model.entry {
                VStack(alignment:.leading,spacing:13) {
                    HStack {
                        DatePicker(L10n.t("日记日期"),selection:Binding(get:{model.entry?.date ?? Date()},set:{value in if let weather=model.entry?.weather,!Calendar.current.isDate(value,inSameDayAs:weather.observedAt){proposedDate=value;datePrompt=true}else{model.changed{$0.date=value}}}),displayedComponents:[.date]).labelsHidden().datePickerStyle(.field).fixedSize()
                        Spacer()
                        if model.weatherBusy{ProgressView().controlSize(.small)}
                        Button{model.showWeather=true}label:{if let weather=entry.weather{Label("\(weather.city) · \(weather.condition) \(Int(weather.temperature.rounded()))°",systemImage:weather.symbol)}else{Label(L10n.t("添加天气"),systemImage:"cloud.sun")}}.buttonStyle(.plain).font(.caption).foregroundStyle(JournalTheme.muted)
                    }
                    if let weather=entry.weather {Text(L10n.t("记录时天气 · ")+weather.journalTimestamp+(weather.manual ? L10n.t(" · 手动填写"):" · "+weather.source)).font(.caption2).foregroundStyle(JournalTheme.muted)}
                    TextField(L10n.t("给这一天起个名字"),text:Binding(get:{model.entry?.title ?? ""},set:{value in model.changed{$0.title=value}})).font(.custom("Songti SC",size:29)).textFieldStyle(.plain).accessibilityLabel(L10n.t("日记标题"))
                    if model.scope != .trash {
                        EditorFormattingToolbar(controller:model.editor)
                        if model.importing {Text(L10n.t("正在加密导入图片…")).font(.caption).foregroundStyle(JournalTheme.muted)}
                    }
                }.padding(.horizontal,30).padding(.top,24).padding(.bottom,12).frame(maxWidth:820)
                if model.scope == .trash {
                    ScrollView{Text(entry.text).font(.system(size:18)).lineSpacing(10).frame(maxWidth:.infinity,alignment:.leading).padding(30)}
                    HStack{Text(L10n.t("将在删除 30 天后清理")).font(.caption);Spacer();Button(L10n.t("恢复日记")){Task{await model.deleteSelected(restore:true)}};Button(L10n.t("永久删除…"),role:.destructive){deletePrompt=true}}.padding(24)
                } else {
                    ZStack(alignment:.topLeading) {
                        RichEditor(data:entry.richText,refresh:model.editorRefresh,preferences:model.preferences,controller:model.editor,changed:{model.editorChanged($0,text:$1,attachments:$2)},importFiles:{model.importPhotos($0)},importData:{data in Task{await model.importPhotos([data])}},preview:{model.photoPreview=$0})
                        if entry.text.isEmpty {Text(L10n.t("从一句话、一张照片，或一个小小的瞬间开始。")).font(.custom(model.preferences.serif ? "Songti SC":"PingFang SC",size:model.preferences.fontSize)).foregroundStyle(JournalTheme.muted.opacity(0.75)).padding(.leading,35).padding(.top,18).allowsHitTesting(false)}
                    }.frame(maxWidth:820).frame(maxHeight:.infinity)
                    VStack(spacing:13) {
                        HStack {
                            Picker(L10n.t("心情"),selection:Binding(get:{model.entry?.mood ?? ""},set:{value in model.changed{$0.mood=value}})){Text(L10n.t("心情可留空")).tag("");ForEach(["平静","愉快","放松","低落","疲惫","充实"],id:\.self){Text(L10n.text($0)).tag($0)}}.labelsHidden().fixedSize()
                            TextField(L10n.t("标签，以逗号分隔"),text:$tags).textFieldStyle(.plain).font(.caption).onChange(of:tags){_,value in let values=value.components(separatedBy:CharacterSet(charactersIn:",，")).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty};if values != model.entry?.tags{model.changed{$0.tags=Array(NSOrderedSet(array:values)) as? [String] ?? values}}}
                        }
                        HStack(spacing:6) {Image(systemName:model.saveFailed ? "exclamationmark.triangle":"lock.shield");Text(model.saveStatus);Spacer();Text(L10n.t("\(entry.text.filter{!$0.isWhitespace && $0 != "\u{fffc}"}.count) 字"));if model.saveFailed{Button(L10n.t("重试")){Task{await model.flush()}}}}.font(.caption).foregroundStyle(model.saveFailed ? Color.red:JournalTheme.muted)
                    }.padding(.horizontal,30).padding(.top,12).padding(.bottom,20).frame(maxWidth:820)
                }
            } else {
                VStack(spacing:18){Image(systemName:"leaf").font(.system(size:36,weight:.ultraLight)).foregroundStyle(JournalTheme.accent);Text(model.scope == .memories ? L10n.t("明年今天，会多一页回忆。"):L10n.t("给今天留一页")).font(.custom("Songti SC",size:27));Text(L10n.t("从一句话开始，慢慢收好你的日常。")).foregroundStyle(JournalTheme.muted);Button(L10n.t("写一篇日记")){Task{await model.newEntry()}}.buttonStyle(.borderedProminent)}.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).background(JournalTheme.paper)
        .onChange(of:model.editorRefresh,initial:true){_,_ in model.editor.linkDraft=nil;tags=model.entry?.tags.joined(separator:", ") ?? ""}
        .confirmationDialog(model.scope == .trash ? L10n.t("永久删除这篇日记？现有备份中的副本不会被删除。"):L10n.t("将这篇日记移到最近删除？30 天内可以恢复。"),isPresented:$deletePrompt){Button(model.scope == .trash ? L10n.t("永久删除"):L10n.t("移到最近删除"),role:.destructive){Task{await model.deleteSelected(permanent:model.scope == .trash)}};Button(L10n.t("取消"),role:.cancel){}}
        .confirmationDialog(L10n.t("新日期与已有天气时间不同"),isPresented:$datePrompt){Button(L10n.t("清除原天气并更改日期")){if let proposedDate{model.changed{$0.date=proposedDate;$0.weather=nil;$0.weatherDismissed=true}}};Button(L10n.t("保留原天气并标明记录时间")){if let proposedDate{model.changed{$0.date=proposedDate}}};Button(L10n.t("取消"),role:.cancel){}}
    }
}

struct BackupSelection:Identifiable {let url:URL;var id:URL{url}}

extension Date {
    var journalDateTime:String {
        let formatter=DateFormatter();formatter.locale=L10n.locale;formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd HHmm")
        return formatter.string(from:self)
    }
}

extension WeatherSnapshot {
    var journalTimestamp:String {
        let formatter=DateFormatter();formatter.locale=L10n.locale;formatter.timeZone=TimeZone(identifier:timeZone);formatter.setLocalizedDateFormatFromTemplate("yyyyMMMd HHmm z")
        return formatter.string(from:observedAt)
    }
}

struct LanguagePicker:View {
    @EnvironmentObject var model:AppModel
    var body:some View {
        Picker("Language / 语言",selection:Binding(get:{model.language},set:{model.setLanguage($0)})) {
            Text("简体中文").tag("zh-Hans")
            Text("English").tag("en")
        }.fixedSize()
    }
}
