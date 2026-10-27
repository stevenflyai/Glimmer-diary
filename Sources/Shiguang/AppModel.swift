import Foundation
import SwiftUI
import AppKit
import DiaryCore
import CoreLocation
import UniformTypeIdentifiers

enum DiaryScope:Hashable {case all,calendar,memories,favorites,trash,notebook(String)}

@MainActor
final class AppModel:ObservableObject {
    @Published var language=L10n.language
    @Published var unlocked=false
    @Published var hasVault=false
    @Published var busy=false
    @Published var error:String?
    @Published var notice:String?
    @Published var recoveryToShow:String?
    @Published var recoveryConfirmed=false
    @Published var entry:DiaryEntry?
    @Published var summaries:[EntrySummary]=[]
    @Published var preferences=DiaryPreferences()
    @Published var scope:DiaryScope = .all
    @Published var search=""
    @Published var searchIDs:Set<UUID>?
    @Published var tagFilter=""
    @Published var moodFilter=""
    @Published var calendarDate=Date()
    @Published var focusMode=false
    @Published var focusSearch=false
    @Published var showSettings=false
    @Published var showWeather=false
    @Published var showVersions=false
    @Published var showExport=false
    @Published var photoPreview:NSImage?
    @Published var editorRefresh=UUID()
    @Published var saveStatus=""
    @Published var saveFailed=false
    @Published var importing=false
    @Published var weatherBusy=false
    @Published var backingUp=false
    @Published var lastBackup:Date?
    @Published var backupPath=""
    @Published var touchIDEnabled=false
    @Published var retryAfter:Date?
    @Published var versions:[EntryVersion]=[]
    let editor=EditorController()
    let store:VaultStore
    let support:URL
    let location=LocationProvider()
    private var initialized=false
    private var vaultID:UUID?
    private var editorSerializationFailed=false
    private var dirty=false
    private var serial:UInt64=0
    private var session=UUID()
    private var autosave:Task<Void,Never>?
    private var searchTask:Task<Void,Never>?
    private var weatherTask:Task<Void,Never>?
    private var saveOperation:Task<Bool,Never>?
    private var saveOperationID:UUID?
    private var failedAttempts=0
    private var pendingCipher:Data?
    private var lastActivity=Date()
    private var timer:Timer?
    private var eventMonitor:Any?
    private var observers:[NSObjectProtocol]=[]
    private var weatherCache:(Double,Double,WeatherSnapshot)?

    init(supportOverride:URL? = nil) {
        if let supportOverride {support=supportOverride}
        else if let directory=ProcessInfo.processInfo.environment["SHIGUANG_DATA_DIR"] {support=URL(fileURLWithPath:directory,isDirectory:true)}
        else {support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Shiguang",isDirectory:true)}
        store=VaultStore(root:support.appendingPathComponent("Vault",isDirectory:true))
    }
    func setLanguage(_ value:String) {
        L10n.language=value;language=L10n.language
        if !saveFailed {
            saveStatus=dirty ? L10n.t("正在加密保存…"):L10n.t("已在本机加密保存")
        }
        if unlocked,preferences.reminderEnabled {Task{await configureReminder()}}
        NSApp.windows.filter{$0.identifier?.rawValue=="main"}.forEach{$0.title=L10n.t("拾光")}
    }
    var filtered:[EntrySummary] {
        summaries.filter {item in
            switch scope {
            case .trash:guard item.deletedAt != nil else {return false}
            default:guard item.deletedAt==nil else {return false}
            }
            switch scope {
            case .favorites:if !item.favorite{return false}
            case .notebook(let name):if item.notebook != name{return false}
            case .calendar:if !Calendar.current.isDate(item.date,inSameDayAs:calendarDate){return false}
            case .memories:
                let calendar=Calendar.current
                if calendar.component(.year,from:item.date)>=calendar.component(.year,from:Date()) || calendar.component(.month,from:item.date) != calendar.component(.month,from:Date()) || calendar.component(.day,from:item.date) != calendar.component(.day,from:Date()) {return false}
            default:break
            }
            if !search.isEmpty,let searchIDs,!searchIDs.contains(item.id) {return false}
            if !tagFilter.isEmpty && !item.tags.contains(tagFilter) {return false}
            if !moodFilter.isEmpty && item.mood != moodFilter {return false}
            return true
        }
    }
    var scopeTitle:String {
        switch scope {case .all:return L10n.t("全部日记");case .calendar:return L10n.t("日历");case .memories:return L10n.t("往年今日");case .favorites:return L10n.t("收藏");case .trash:return L10n.t("最近删除");case .notebook(let name):return name}
    }
    var allTags:[String] {Array(Set(summaries.flatMap(\.tags))).sorted()}
    func start() async {
        guard !initialized else {return}; initialized=true
        hasVault=await store.exists(); vaultID=try? await store.vaultID()
        if let vaultID {touchIDEnabled=DeviceUnlock.enabled(vaultID)}
        eventMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown,.mouseMoved,.scrollWheel]) {[weak self] event in self?.lastActivity=Date(); return event}
        timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true) {[weak self] _ in Task {@MainActor in guard let self,self.unlocked else {return}; if Date().timeIntervalSince(self.lastActivity)>=Double(self.preferences.idleMinutes)*60 {await self.lock()}}}
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) {[weak self] _ in Task {@MainActor in await self?.lock()}})
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.screensDidSleepNotification,object:nil,queue:.main) {[weak self] _ in Task {@MainActor in await self?.lock()}})
        observers.append(DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.apple.screenIsLocked"),object:nil,queue:.main) {[weak self] _ in Task {@MainActor in await self?.lock()}})
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) {[weak self] _ in Task {@MainActor in guard let self,self.preferences.lockOnDeactivate else {return}; await self.lock()}})
        observers.append(NotificationCenter.default.addObserver(forName:.editorSerializationFailed,object:nil,queue:.main) {[weak self] _ in MainActor.assumeIsolated {self?.editorSerializationFailed=true;self?.saveFailed=true;self?.saveStatus=L10n.t("正文转换失败，请撤销最近一次操作后重试。");self?.error=L10n.t("正文转换失败，当前编辑器中的内容尚未保存。请保持窗口打开，撤销最近一次操作后重试。")}})
        #if DEBUG
        if CommandLine.arguments.contains("--ui-test"),ProcessInfo.processInfo.environment["SHIGUANG_DATA_DIR"] != nil {
            do {
                if !hasVault {
                    _=try await store.create(password:"shiguang-disposable-ui-fixture")
                    var settings=DiaryPreferences();settings.autoBackup=false;try await store.savePreferences(settings)
                    for (index,title) in ["把日子过慢一点（测试日记）","雨天，适合读书","往年今日的一页"].enumerated() {
                        var item=DiaryEntry(date:Calendar.current.date(byAdding:index==2 ? .year:.day,value:index==2 ? -1:-index,to:Date())!)
                        item.title=title;item.text="午后出门走了一小圈。风里已经有了秋天的味道，路边的树叶也开始变黄。\n\n今天没有什么特别的大事，却有几个想留下来的瞬间：一杯刚好的咖啡，一段喜欢的音乐，还有回家路上的晚霞。\n\n这是用于检查应用功能的测试内容。"
                        item.mood="平静";item.tags=["日常","测试"]
                        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=10;paragraph.paragraphSpacing=12
                        let text=NSAttributedString(string:item.text,attributes:[.font:NSFont(name:"Songti SC",size:18) ?? NSFont.systemFont(ofSize:18),.paragraphStyle:paragraph,.foregroundColor:NSColor.labelColor])
                        item.richText=try text.data(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
                        item.weather=WeatherSnapshot(city:"示例城市",temperature:18,code:3,observedAt:item.date,source:"手动示例",manual:true)
                        try await store.save(item)
                    }
                } else {try await store.unlock(password:"shiguang-disposable-ui-fixture")}
                await loadUnlocked();hasVault=true
                if CommandLine.arguments.contains("--format-checks") {
                    do {try await FormattingChecks.run(root:support);await store.lock();exit(0)}
                    catch {print("FAIL · Formatting checks: \(error)");exit(1)}
                }
                if CommandLine.arguments.contains("--ime-checks") {
                    do {try await EditorIMEChecks.run(root:support);await store.lock();exit(0)}
                    catch {print("FAIL · IME checks: \(error)");exit(1)}
                }
                if CommandLine.arguments.contains("--export-checks") {
                    do {try await IntegrationChecks.run(store:store,root:support);await store.lock();exit(0)}
                    catch {print("FAIL · Export checks: \(error)");exit(1)}
                }
            } catch {self.error=error.localizedDescription}
        }
        #endif
    }
    func create(password:String) async {
        guard !busy else {return}; busy=true; error=nil
        do {recoveryToShow=try await store.create(password:password); recoveryConfirmed=false; hasVault=true; await loadUnlocked(reveal:false)} catch {self.error=error.localizedDescription}
        busy=false
    }
    func finishRecoverySetup() {recoveryToShow=nil; recoveryConfirmed=false; unlocked=true; lastActivity=Date()}
    func unlock(password:String) async {
        guard !busy,retryAfter.map({$0>Date()}) != true else {return}; busy=true; error=nil
        do {try await store.unlock(password:password); failedAttempts=0; retryAfter=nil; await loadUnlocked()}
        catch {failedAttempts+=1; retryAfter=Date().addingTimeInterval(min(30,Double(max(0,failedAttempts-2))*3)); self.error=error.localizedDescription}
        busy=false
    }
    func recover(key:String,password:String) async {
        guard !busy else {return}; busy=true; error=nil
        do {try await store.recover(recovery:key,newPassword:password); if let vaultID {DeviceUnlock.disable(vaultID)}; await loadUnlocked(); notice=L10n.t("已恢复访问并更新密码。请使用新密码重新设置 Touch ID。")}
        catch {self.error=error.localizedDescription}; busy=false
    }
    func unlockWithTouchID() async {
        guard !busy,let vaultID else {return}; busy=true; error=nil
        do {let key=try await DeviceUnlock.read(vaultID); try await store.unlock(deviceKey:key); await loadUnlocked()}
        catch {self.error=error.localizedDescription}; busy=false
    }
    private func loadUnlocked(reveal:Bool = true) async {
        do {
            session=UUID(); preferences=try await store.preferences(); vaultID=try await store.vaultID()
            touchIDEnabled=vaultID.map(DeviceUnlock.enabled) ?? false
            if let pending=pendingCipher ?? (try? Data(contentsOf:support.appendingPathComponent("pending.enc"))) {
                do {
                    let recovered=try await store.restorePending(pending); try await store.save(recovered)
                    pendingCipher=nil; try? FileManager.default.removeItem(at:support.appendingPathComponent("pending.enc")); notice=L10n.t("已恢复上次未完成保存的日记。")
                } catch {notice=L10n.t("有一份未保存缓冲暂时无法恢复，已保留原文件。已保存的日记仍可正常访问。")}
            }
            summaries=try await store.list()
            if let data=try await store.setting("lastBackup"),let date=try? JSONDecoder().decode(Date.self,from:data) {lastBackup=date}
            let folder=try await backupFolder(); backupPath=folder.path
            scope = .all; search=""; searchIDs=nil; dirty=false; editorSerializationFailed=false; saveFailed=false; saveStatus=L10n.t("已在本机加密保存")
            let id=preferences.lastEntry.flatMap {id in summaries.first(where:{$0.id==id && $0.deletedAt==nil})?.id} ?? summaries.first(where:{$0.deletedAt==nil})?.id
            entry=try await id.flatMapAsync {try await store.entry($0)}
            editorRefresh=UUID(); unlocked=reveal; lastActivity=Date()
        } catch {self.error=error.localizedDescription; await store.lock(); unlocked=false}
    }
    func lock() async {
        guard unlocked || recoveryToShow != nil else {return}
        editor.commitComposition()
        guard !editorSerializationFailed else {error=L10n.t("当前正文尚未保存。请撤销最近一次操作后重试锁定。");return}
        busy=true; unlocked=false; session=UUID(); weatherTask?.cancel(); searchTask?.cancel(); autosave?.cancel()
        showSettings=false;showWeather=false;showVersions=false;showExport=false;photoPreview=nil;recoveryToShow=nil
        let current=entry
        let saved=await flush(allowLocked:true)
        if !saved,let current {
            do {pendingCipher=try await store.protectPending(current); if let pendingCipher {try? VaultEncryption.atomicWrite(pendingCipher,to:support.appendingPathComponent("pending.enc"))}}
            catch {self.error=L10n.t("暂时无法锁定保存中的日记，请保持应用运行并重试。");unlocked=true;busy=false;return}
        }
        await store.lock(); entry=nil; summaries=[];versions=[];preferences=DiaryPreferences();search="";searchIDs=nil;dirty=false;weatherCache=nil;editor.textView=nil
        notice=saved ? nil:L10n.t("有一篇日记等待恢复保存，解锁后将自动重试。"); busy=false
    }
    func changed(_ update:(inout DiaryEntry)->Void) {
        guard unlocked,var item=entry else {return}; update(&item);item.updatedAt=Date();entry=item;dirty=true;serial+=1;saveFailed=false;saveStatus=L10n.t("保存中…")
        autosave?.cancel(); autosave=Task {try? await Task.sleep(for:.seconds(1)); guard !Task.isCancelled else {return}; _=await flush()}
    }
    func editorChanged(_ data:Data,text:String,attachments:[UUID]) {editorSerializationFailed=false;changed {$0.richText=data;$0.text=text;$0.attachmentIDs=attachments}}
    @discardableResult func flush(allowLocked:Bool = false,finishingEditing:Bool = false) async -> Bool {
        // A save only persists committed text. Ending composition is reserved for leaving the editor.
        if finishingEditing {editor.commitComposition()}
        guard !editorSerializationFailed else {return false}
        if let operation=saveOperation {
            let result=await operation.value
            if !result {return false}
            if saveOperation != nil {await Task.yield()}
            if !dirty {return true}
        }
        guard unlocked || allowLocked else {return true}
        guard dirty,let snapshot=entry else {return !saveFailed}
        if snapshot.isEmpty && !summaries.contains(where:{$0.id==snapshot.id}) {dirty=false;saveStatus=L10n.t("写下第一个字时自动保存");return true}
        let generation=serial; let id=UUID(); saveOperationID=id
        let operation=Task {() -> Bool in
            do {
                try await store.save(snapshot)
                if entry?.id==snapshot.id && serial==generation {dirty=false;saveFailed=false;saveStatus=L10n.t("已在本机加密保存")}
                if unlocked {summaries=try await store.list()}
                return true
            } catch {saveFailed=true;saveStatus=error.localizedDescription;self.error=error.localizedDescription;return false}
        }
        saveOperation=operation; let result=await operation.value
        if saveOperationID==id {saveOperation=nil;saveOperationID=nil}
        if result && dirty {return await flush(allowLocked:allowLocked)}
        if result && unlocked {Task {await autoBackupIfNeeded()}}
        return result
    }
    func select(_ id:UUID) async {
        guard unlocked,await flush(finishingEditing:true),unlocked else {return}
        let token=session
        do {let loaded=try await store.entry(id);guard unlocked,token==session else{return};entry=loaded;editorRefresh=UUID();preferences.lastEntry=id;try await store.savePreferences(preferences);saveStatus=L10n.t("已在本机加密保存");dirty=false;notice=nil}
        catch {self.error=error.localizedDescription}
    }
    func newEntry() async {
        guard unlocked,await flush(finishingEditing:true),unlocked else {return}
        let notebook:String;if case .notebook(let name)=scope {notebook=name}else{notebook=preferences.notebooks.first ?? L10n.t("生活碎片")}
        let date=scope == .calendar ? calendarDate:Date()
        entry=DiaryEntry(date:date,notebook:notebook);editorRefresh=UUID();dirty=false;saveStatus=L10n.t("写下第一个字时自动保存");scope = .all;search="";searchIDs=nil
        if preferences.weatherEnabled && Calendar.current.isDateInToday(date) {requestCurrentWeather()}
    }
    func chooseScope(_ value:DiaryScope) async {
        guard unlocked,await flush(finishingEditing:true),unlocked else {return}; scope=value; tagFilter="";moodFilter=""
        if let id=filtered.first?.id {await select(id)} else {entry=nil;editorRefresh=UUID()}
    }
    func performSearch() {
        searchTask?.cancel(); let text=search; let token=session
        if text.isEmpty {searchIDs=nil;return}
        searchTask=Task {try? await Task.sleep(for:.milliseconds(180));guard !Task.isCancelled else{return};do{let results=try await store.list(search:text);guard token==session,search==text else{return};searchIDs=Set(results.map(\.id))}catch{if unlocked {self.error=error.localizedDescription}}}
    }
    func deleteSelected(restore:Bool = false,permanent:Bool = false) async {
        guard let id=entry?.id,await flush(finishingEditing:true) else {return}
        let token=session
        do {if permanent {try await store.purge(id)}else{try await store.trash(id,restore:restore)};let updated=try await store.list();guard unlocked,token==session else{return};summaries=updated;entry=nil;if let next=filtered.first {await select(next.id)}}catch{self.error=error.localizedDescription}
    }
    func loadVersions() async {guard unlocked,let id=entry?.id,await flush() else{return};let token=session;do{let loaded=try await store.versions(id);guard unlocked,token==session,entry?.id==id else{return};versions=loaded;showVersions=true}catch{if unlocked{self.error=error.localizedDescription}}}
    func restoreVersion(_ version:EntryVersion) async {
        guard unlocked,await flush(finishingEditing:true) else{return};let token=session
        do {var old=version.entry;old.updatedAt=Date();old.deletedAt=nil;try await store.save(old,forceVersion:true);let updated=try await store.list();guard unlocked,token==session else{return};entry=old;editorRefresh=UUID();summaries=updated;showVersions=false;notice=L10n.t("已恢复历史版本，恢复前的内容也已保留。")}catch{self.error=error.localizedDescription}
    }
    func updatePreferences() {
        guard unlocked else{return};let value=preferences
        Task {do{try await store.savePreferences(value)}catch{if unlocked{self.error=error.localizedDescription}}}
    }
    func configureReminder() async {
        do {try await ReminderService.configure(preferences);updatePreferences()}
        catch {preferences.reminderEnabled=false;updatePreferences();self.error=error.localizedDescription}
    }
    func setTouchID(_ enabled:Bool) async {
        guard let vaultID else{return}
        do {if enabled {let key=try await store.deviceKey();try DeviceUnlock.enable(vaultID,key:key)}else{DeviceUnlock.disable(vaultID)};touchIDEnabled=enabled}
        catch {touchIDEnabled=false;self.error=error.localizedDescription}
    }
    func importPhotos(_ urls:[URL]) {
        Task {
            do {
                guard urls.count<=20 else {throw DiaryError.invalidInput(L10n.t("每次最多插入 20 张照片，请分批添加。"))}
                var all=[Data]()
                for url in urls {
                    let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
                    let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size<=50*1024*1024 else{throw DiaryError.invalidInput(L10n.t("单张图片不能超过 50 MB。"))}
                    all.append(try Data(contentsOf:url))
                }
                await importPhotos(all)
            }catch{self.error=error.localizedDescription}
        }
    }
    func importPhotos(_ data:[Data]) async {
        guard unlocked,!importing,let id=entry?.id else{return};let token=session;importing=true
        defer {importing=false}
        do {
            var photos=[ImportedPhoto]()
            for item in data {
                let (preview,size)=try await Task.detached {try ImageProcessing.preview(item)}.value
                let attachment=try await store.addAttachment(item);photos.append(ImportedPhoto(id:attachment,preview:preview,size:size))
            }
            guard token==session,entry?.id==id,unlocked else{return}
            editor.insert(photos)
        }catch{if unlocked {self.error=error.localizedDescription}}
    }
    func requestCurrentWeather() {
        guard unlocked,let id=entry?.id,let date=entry?.date,Calendar.current.isDateInToday(date) else {notice=L10n.t("补写过去的日记时，请手动填写当时的天气。");return}
        weatherTask?.cancel();let token=session;weatherBusy=true
        weatherTask=Task {
            defer {weatherBusy=false}
            do {
                let position=try await location.locate()
                let point=WeatherClient.coarse(latitude:position.coordinate.latitude,longitude:position.coordinate.longitude)
                let snapshot:WeatherSnapshot
                if let cached=weatherCache,cached.0==point.0,cached.1==point.1,Date().timeIntervalSince(cached.2.fetchedAt)<1800 {snapshot=cached.2}
                else {let city=await location.city(for:position);snapshot=try await WeatherClient.fetch(latitude:point.0,longitude:point.1,city:city);weatherCache=(point.0,point.1,snapshot)}
                guard token==session,entry?.id==id,entry?.date==date,!Task.isCancelled else{return}
                changed {$0.weather=snapshot;$0.weatherDismissed=false}
            }catch{if token==session,unlocked,!Task.isCancelled {notice=error.localizedDescription}}
        }
    }
    func setWeather(city:WeatherCity) async {
        guard let id=entry?.id,let date=entry?.date,Calendar.current.isDateInToday(date) else{error=L10n.t("过去日期请使用手动填写，不能用当前天气代替。");return}
        let token=session;weatherBusy=true;defer {weatherBusy=false}
        do {let result=try await WeatherClient.fetch(latitude:city.latitude,longitude:city.longitude,city:city.name);guard token==session,entry?.id==id,entry?.date==date else{return};changed {$0.weather=result;$0.weatherDismissed=false};showWeather=false}catch{self.error=error.localizedDescription}
    }
    func backupFolder() async throws -> URL {
        if let data=try await store.setting("backupBookmark") {var stale=false;return try URL(resolvingBookmarkData:data,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale)}
        return support.appendingPathComponent("Backups",isDirectory:true)
    }
    func chooseBackupFolder() async {
        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L10n.t("选择备份位置");panel.message=L10n.t("建议选择外置磁盘。若选择云盘文件夹，外部服务会同步加密备份。")
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {let data=try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil);try await store.saveSetting(data,key:"backupBookmark");backupPath=url.path;notice=L10n.t("备份位置已更新。")}catch{self.error=error.localizedDescription}
    }
    func backupNow() async {
        guard unlocked,!backingUp,await flush() else{return};backingUp=true
        let token=session
        defer {backingUp=false}
        do {
            let folder=try await backupFolder();let access=folder.startAccessingSecurityScopedResource();defer {if access{folder.stopAccessingSecurityScopedResource()}}
            let result=try await store.backup(to:folder);try await store.trimBackups(in:folder,keeping:preferences.backupRetention)
            let finished=Date();try await store.saveSetting(JSONEncoder().encode(finished),key:"lastBackup")
            if unlocked,token==session {lastBackup=finished;backupPath=folder.path;notice=L10n.t("加密备份已校验并保存：")+result.lastPathComponent}
        }catch{if unlocked{self.error=L10n.t("备份未完成：")+error.localizedDescription}}
    }
    private func autoBackupIfNeeded() async {
        guard unlocked,preferences.autoBackup,!backingUp,!summaries.isEmpty,lastBackup.map({!Calendar.current.isDateInToday($0)}) ?? true else{return}
        await backupNow()
    }
    func chooseRestore() -> URL? {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(exportedAs:"com.shiguang.backup",conformingTo:.package)];panel.canChooseDirectories=false;panel.treatsFilePackagesAsDirectories=false;panel.prompt=L10n.t("选择加密备份");return panel.runModal() == .OK ? panel.url:nil
    }
    func restore(from url:URL,password:String,recovery:Bool) async {
        guard !busy else{return};if unlocked {guard await flush(finishingEditing:true) else{return}};busy=true
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()};busy=false}
        do {let previous=try await store.restoreBackup(from:url,password:password,recovery:recovery);hasVault=true;showSettings=false;await loadUnlocked();notice=previous==nil ? L10n.t("已验证并恢复加密备份。"):L10n.t("已恢复备份。恢复前的保险库已保留在应用数据目录。")}
        catch {self.error=error.localizedDescription;hasVault=await store.exists();if !(await store.isUnlocked()){unlocked=false}}
    }
}

extension Optional {
    func flatMapAsync<T>(_ transform:(Wrapped) async throws -> T?) async rethrows -> T? {if let value=self{return try await transform(value)};return nil}
}
