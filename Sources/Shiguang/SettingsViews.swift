import SwiftUI
import AppKit
import DiaryCore

struct SettingsView:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var page="安全"
    @ViewState private var oldPassword=""
    @ViewState private var newPassword=""
    @ViewState private var repeatedPassword=""
    @ViewState private var changing=false
    @ViewState private var restoreURL:URL?
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack{Text(L10n.t("安心地记录")).font(.custom("Songti SC",size:28));Spacer();Button(L10n.t("完成")){dismiss()}.keyboardShortcut(.cancelAction)}
            LanguagePicker()
            Picker(L10n.t("设置分类"),selection:$page){ForEach(["安全","写作","天气","备份","提醒"],id:\.self){Text(L10n.text($0)).tag($0)}}.pickerStyle(.segmented)
            ScrollView {
                VStack(alignment:.leading,spacing:22) {
                    switch page {
                    case "安全":security
                    case "写作":writing
                    case "天气":weather
                    case "备份":backups
                    default:reminders
                    }
                }.padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.padding(28).frame(width:660,height:620).background(JournalTheme.paper)
        .onChange(of:model.preferences){_,_ in model.updatePreferences()}
        .sheet(item:Binding(get:{restoreURL.map(BackupSelection.init)},set:{restoreURL=$0?.url})){RestoreBackupView(url:$0.url)}
        .onDisappear{oldPassword="";newPassword="";repeatedPassword=""}
    }
    private var security:some View {
        Group {
            Toggle(L10n.t("使用 Touch ID 解锁这台 Mac"),isOn:Binding(get:{model.touchIDEnabled},set:{value in Task{await model.setTouchID(value)}})).disabled(changing)
            Text(L10n.t("指纹验证直接保护设备解锁密钥。取消或无法验证时，仍可使用日记密码。")).font(.caption).foregroundStyle(JournalTheme.muted)
            Picker(L10n.t("闲置后自动锁定"),selection:$model.preferences.idleMinutes){Text(L10n.t("1 分钟")).tag(1);Text(L10n.t("5 分钟")).tag(5);Text(L10n.t("15 分钟")).tag(15);Text(L10n.t("30 分钟")).tag(30)}
            Toggle(L10n.t("切换到其他应用时立即锁定"),isOn:$model.preferences.lockOnDeactivate)
            Text(L10n.t("锁屏或睡眠时始终锁定。手动锁定：⌘⇧L。")).font(.caption).foregroundStyle(JournalTheme.muted)
            Divider();Text(L10n.t("修改日记密码")).font(.headline)
            SecureField(L10n.t("当前密码"),text:$oldPassword).textFieldStyle(.roundedBorder)
            SecureField(L10n.t("新密码，至少 10 个字符"),text:$newPassword).textFieldStyle(.roundedBorder)
            SecureField(L10n.t("再次输入新密码"),text:$repeatedPassword).textFieldStyle(.roundedBorder)
            PasswordSetupFeedback(password:newPassword,confirmation:repeatedPassword)
            HStack {
                Button(L10n.t("更新密码")) {
                    let current=oldPassword;let new=newPassword;changing=true
                    Task {do{try await model.store.changePassword(current:current,new:new);oldPassword="";newPassword="";repeatedPassword="";model.notice=L10n.t("日记密码已更新。旧备份可能仍需要旧密码或对应恢复密钥。")}catch{model.error=error.localizedDescription};changing=false}
                }.disabled(changing || oldPassword.isEmpty || newPassword.count<10 || newPassword != repeatedPassword)
                if changing{ProgressView().controlSize(.small)}
            }
            Divider();Text(L10n.t("恢复密钥")).font(.headline)
            Text(L10n.t("重新生成会替换当前保险库的恢复密钥。已有备份保持原样，仍使用当时的密码或恢复密钥。")).font(.caption).foregroundStyle(JournalTheme.muted)
            Button(L10n.t("使用上方当前密码重新生成恢复密钥")) {
                let password=oldPassword;changing=true
                Task {do{let key=try await model.store.regenerateRecovery(password:password);oldPassword="";model.showSettings=false;model.recoveryConfirmed=false;model.recoveryToShow=key}catch{model.error=error.localizedDescription};changing=false}
            }.disabled(oldPassword.isEmpty || changing)
        }
    }
    private var writing:some View {
        Group {
            Picker(L10n.t("外观"),selection:$model.preferences.appearance){Text(L10n.t("跟随系统")).tag("system");Text(L10n.t("温暖纸面")).tag("light");Text(L10n.t("深色")).tag("dark")}
            Toggle(L10n.t("使用宋体书写"),isOn:$model.preferences.serif)
            HStack{Text(L10n.t("正文字号"));Slider(value:$model.preferences.fontSize,in:14...26,step:1);Text("\(Int(model.preferences.fontSize)) pt").monospacedDigit().frame(width:48)}
            HStack{Text(L10n.t("段落行距"));Slider(value:$model.preferences.lineSpacing,in:4...18,step:1);Text("\(Int(model.preferences.lineSpacing)) pt").monospacedDigit().frame(width:48)}
            Text(L10n.t("把日子过慢一点。\n\n一杯刚好的咖啡，一段喜欢的音乐，还有回家路上的晚霞。")).font(.custom(model.preferences.serif ? "Songti SC":"PingFang SC",size:model.preferences.fontSize)).lineSpacing(model.preferences.lineSpacing).padding(24).frame(maxWidth:.infinity,alignment:.leading).background(JournalTheme.list,in:RoundedRectangle(cornerRadius:8))
            Text(L10n.t("所有字体来自系统，离线也可以使用。")).font(.caption).foregroundStyle(JournalTheme.muted)
        }
    }
    private var weather:some View {
        Group {
            Toggle(L10n.t("新建今天的日记时自动添加天气"),isOn:$model.preferences.weatherEnabled)
            Text(L10n.t("仅在前台写日记或手动刷新时请求定位。系统会征求定位授权，不在后台追踪。")).font(.callout)
            Label(L10n.t("近似位置查询，日记只保存城市"),systemImage:"location.circle").font(.headline)
            Text(L10n.t("定位结果先降低到约 5 公里网格。Open-Meteo 接收近似坐标和网络 IP；Apple 地名解析接收近似坐标用于识别城市。日记不保存精确坐标。")).foregroundStyle(JournalTheme.muted)
            Text(L10n.t("回看旧日记不刷新天气。拒绝定位、没有网络或天气服务不可用时，仍可正常书写，也可以手动填写天气。")).foregroundStyle(JournalTheme.muted)
            Link(L10n.t("Open-Meteo · 数据来源与隐私说明"),destination:URL(string:"https://open-meteo.com/en/terms")!)
            Link(L10n.t("天气数据许可 CC BY 4.0"),destination:URL(string:"https://creativecommons.org/licenses/by/4.0/")!)
            Text(L10n.t("天气来自气象模型，可能与街道实况不同。免费接口适用于符合其条款的非商业使用。")).font(.caption).foregroundStyle(JournalTheme.muted)
        }
    }
    private var backups:some View {
        Group {
            Toggle(L10n.t("有修改的使用日自动加密备份"),isOn:$model.preferences.autoBackup)
            Picker(L10n.t("保留成功备份"),selection:$model.preferences.backupRetention){Text(L10n.t("最近 7 份")).tag(7);Text(L10n.t("最近 30 份")).tag(30);Text(L10n.t("最近 90 份")).tag(90)}
            Text(L10n.t("备份位置")).font(.headline);Text(model.backupPath).font(.caption).textSelection(.enabled).foregroundStyle(JournalTheme.muted)
            Text(L10n.t("应用数据目录中的备份可恢复误操作。要防止硬盘损坏，请另选外置盘等独立位置。")).font(.callout).foregroundStyle(JournalTheme.muted)
            HStack {Button(L10n.t("更改位置…")){Task{await model.chooseBackupFolder()}};Button(L10n.t("在 Finder 中查看")){NSWorkspace.shared.open(URL(fileURLWithPath:model.backupPath))}.disabled(model.backupPath.isEmpty)}
            Divider()
            if let date=model.lastBackup {Label(L10n.t("最近成功：")+date.journalDateTime,systemImage:"checkmark.shield")}else{Text(L10n.t("还没有成功备份。"))}
            HStack{Button(L10n.t("立即加密备份")){Task{await model.backupNow()}}.buttonStyle(.borderedProminent).disabled(model.backingUp);Button(L10n.t("从备份恢复…")){restoreURL=model.chooseRestore()}.disabled(model.backingUp);if model.backingUp{ProgressView().controlSize(.small)}}
            Divider();Text(L10n.t("数据带走")).font(.headline)
            Text(L10n.t("在日记右上角的更多菜单中导出 PDF 或 Markdown。普通导出会生成可读文件，它们不再受保险库保护。")).font(.callout).foregroundStyle(JournalTheme.muted)
            Text(L10n.t("应用版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.1") · 数据格式 1\n本机加密日记，不上传正文，不内置 AI 或云同步。")).font(.caption).foregroundStyle(JournalTheme.muted)
        }
    }
    private var reminders:some View {
        Group {
            Toggle(L10n.t("每天提醒我留一点时间写日记"),isOn:$model.preferences.reminderEnabled).onChange(of:model.preferences.reminderEnabled){_,_ in Task{await model.configureReminder()}}
            HStack {Picker(L10n.t("小时"),selection:$model.preferences.reminderHour){ForEach(0..<24,id:\.self){Text(String(format:"%02d",$0)).tag($0)}};Picker(L10n.t("分钟"),selection:$model.preferences.reminderMinute){ForEach(0..<60,id:\.self){Text(String(format:"%02d",$0)).tag($0)}}}.disabled(!model.preferences.reminderEnabled)
            Button(L10n.t("保存提醒时间")){Task{await model.configureReminder()}}.disabled(!model.preferences.reminderEnabled)
            Text(L10n.t("提醒只显示通用文案，不显示日记标题、内容或心情。关闭提醒不会影响日记和备份。")).foregroundStyle(JournalTheme.muted)
        }
    }
}

struct RestoreBackupView:View {
    let url:URL
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var password=""
    @ViewState private var useRecovery=false
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Label(L10n.t("恢复加密备份"),systemImage:"archivebox").font(.title2)
            Text(url.lastPathComponent).font(.caption).textSelection(.enabled)
            Text(L10n.t("先验证备份，再恢复文字、照片和设置。当前保险库会保留为一个加密副本，不会直接丢弃。"))
            Toggle(L10n.t("使用恢复密钥"),isOn:$useRecovery)
            SecureField(useRecovery ? L10n.t("备份对应的恢复密钥"):L10n.t("备份对应的密码"),text:$password).textFieldStyle(.roundedBorder)
            Text(L10n.t("如果备份生成后改过密码，请使用备份当时的密码或恢复密钥。")).font(.caption).foregroundStyle(JournalTheme.muted)
            HStack{Button(L10n.t("取消")){password="";dismiss()};Spacer();if model.busy{ProgressView().controlSize(.small)};Button(L10n.t("验证并恢复")){let value=password;password="";Task{await model.restore(from:url,password:value,recovery:useRecovery);if model.error==nil{dismiss()}}}.buttonStyle(.borderedProminent).disabled(password.isEmpty || model.busy)}
        }.padding(28).frame(width:490).background(JournalTheme.paper).onDisappear{password=""}
    }
}

struct WeatherView:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var cityQuery=""
    @ViewState private var cities:[WeatherCity]=[]
    @ViewState private var searching=false
    @ViewState private var manualCity=""
    @ViewState private var temperature=20.0
    @ViewState private var code=0
    @ViewState private var observed=Date()
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack{Text(L10n.t("这一刻的天气")).font(.custom("Songti SC",size:27));Spacer();Button(L10n.t("完成")){dismiss()}}
            if let weather=model.entry?.weather {
                HStack{Label("\(weather.city) · \(weather.condition) \(Int(weather.temperature.rounded()))°C",systemImage:weather.symbol).font(.headline);Spacer();Button(L10n.t("移除"),role:.destructive){model.changed{$0.weather=nil;$0.weatherDismissed=true};dismiss()}}
                Text(L10n.t("数据时间：")+weather.journalTimestamp+L10n.t("\n来源：")+weather.source+(weather.manual ? L10n.t("（手动填写）"):L10n.t(" · 气象模型数据"))).font(.caption).foregroundStyle(JournalTheme.muted)
            }
            Text(L10n.t("当前位置查询会请求系统定位，将近似坐标发给 Open-Meteo，并由 Apple 解析城市；日记只保存城市和天气。")).font(.caption).foregroundStyle(JournalTheme.muted)
            HStack{Button{model.requestCurrentWeather()}label:{Label(L10n.t("获取当前位置天气"),systemImage:"location")}.disabled(model.weatherBusy || !Calendar.current.isDateInToday(model.entry?.date ?? .distantPast));if model.weatherBusy{ProgressView().controlSize(.small)}}
            Divider();Text(L10n.t("或搜索城市")).font(.headline)
            HStack{TextField(L10n.t("例如：杭州 / Hangzhou"),text:$cityQuery).textFieldStyle(.roundedBorder).onSubmit{searchCities()};Button(L10n.t("搜索")){searchCities()}.disabled(searching || cityQuery.count<2)}
            if searching{ProgressView().controlSize(.small)}
            ForEach(cities.prefix(5)){city in Button(city.label){Task{await model.setWeather(city:city)}}.buttonStyle(.link).disabled(model.weatherBusy)}
            Divider();Text(L10n.t("手动记录当时天气")).font(.headline)
            HStack{TextField(L10n.t("城市（可留空）"),text:$manualCity).textFieldStyle(.roundedBorder);TextField(L10n.t("气温"),value:$temperature,format:.number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).frame(width:70);Text("°C");Picker(L10n.t("天气"),selection:$code){Text(L10n.t("晴")).tag(0);Text(L10n.t("多云")).tag(3);Text(L10n.t("小雨")).tag(61);Text(L10n.t("雪")).tag(71);Text(L10n.t("雾")).tag(45);Text(L10n.t("雷雨")).tag(95)}.labelsHidden()}
            DatePicker(L10n.t("天气时间"),selection:$observed)
            Button(L10n.t("保存手动天气")){model.changed{$0.weather=WeatherSnapshot(city:manualCity.isEmpty ? L10n.t("未填写城市"):manualCity,temperature:temperature,code:code,observedAt:observed,source:L10n.t("手动"),manual:true);$0.weatherDismissed=false};dismiss()}.disabled(!temperature.isFinite || !(-100...70).contains(temperature))
            HStack{Link("Open-Meteo",destination:URL(string:"https://open-meteo.com/")!);Text("·");Link("CC BY 4.0",destination:URL(string:"https://creativecommons.org/licenses/by/4.0/")!)}.font(.caption)
        }.padding(28).frame(width:560).background(JournalTheme.paper)
        .onAppear{observed=model.entry?.date ?? Date();if let weather=model.entry?.weather{manualCity=weather.city;temperature=weather.temperature;code=weather.code;observed=weather.observedAt}}
    }
    private func searchCities(){guard !searching else{return};searching=true;Task{do{cities=try await WeatherClient.search(cityQuery);if cities.isEmpty{model.notice=L10n.t("没有找到城市，可以试试拼音或英文名，也可以手动填写。")}}catch{model.error=error.localizedDescription};searching=false}}
}

struct VersionsView:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selected:UUID?
    var body:some View {
        VStack(alignment:.leading,spacing:18){
            HStack{Text(L10n.t("历史版本")).font(.title2);Spacer();Button(L10n.t("完成")){dismiss()}}
            Text(L10n.t("按编辑批次保留最近 30 天的版本。恢复前会先保留当前内容。")).font(.caption).foregroundStyle(JournalTheme.muted)
            HSplitView {
                List(model.versions,selection:$selected){version in VStack(alignment:.leading){Text(version.savedAt.journalDateTime);Text(String(version.entry.text.prefix(60))).font(.caption).foregroundStyle(.secondary).lineLimit(2)}.tag(version.id)}.frame(width:210)
                if let version=model.versions.first(where:{$0.id==selected}) {ScrollView{VStack(alignment:.leading,spacing:16){Text(version.entry.displayTitle).font(.title2);Text(version.entry.text).textSelection(.enabled);Button(L10n.t("恢复这个版本")){Task{await model.restoreVersion(version)}}.buttonStyle(.borderedProminent)}.padding(16).frame(maxWidth:.infinity,alignment:.leading)}}else{Text(model.versions.isEmpty ? L10n.t("还没有历史版本"):L10n.t("选择一个版本查看")).foregroundStyle(.secondary).frame(maxWidth:.infinity,maxHeight:.infinity)}
            }
        }.padding(24).frame(width:740,height:530).background(JournalTheme.paper).onAppear{selected=model.versions.first?.id}
    }
}
