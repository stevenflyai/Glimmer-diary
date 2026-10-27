import AppKit
import LocalAuthentication
import Security
import CoreLocation
import UserNotifications
import DiaryCore
import ImageIO

enum DeviceUnlock {
    static let service="com.shiguang.diary.device-unlock"
    static func available() -> Bool {let context=LAContext(); return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,error:nil)}
    static func enabled(_ id:UUID) -> Bool {
        let context=LAContext();context.interactionNotAllowed=true;defer{context.invalidate()}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecReturnAttributes as String:true,kSecUseAuthenticationContext as String:context]
        let result=SecItemCopyMatching(query as CFDictionary,nil)
        return result==errSecSuccess || result==errSecInteractionNotAllowed
    }
    static func enable(_ id:UUID,key:Data) throws {
        guard available() else {throw DiaryError.invalidInput(L10n.t("这台 Mac 暂时无法使用 Touch ID，请继续使用日记密码。"))}
        var error:Unmanaged<CFError>?
        guard let access=SecAccessControlCreateWithFlags(nil,kSecAttrAccessibleWhenUnlockedThisDeviceOnly,.biometryCurrentSet,&error) else {throw DiaryError.storage(L10n.t("无法创建 Touch ID 访问保护。"))}
        let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecAttrAccessControl as String:access,kSecValueData as String:key,kSecAttrLabel as String:L10n.t("拾光日记解锁")]
        disable(id)
        guard SecItemAdd(query as CFDictionary,nil)==errSecSuccess else {throw DiaryError.storage(L10n.t("无法保存设备解锁信息，请使用日记密码。"))}
    }
    static func disable(_ id:UUID) {SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString] as CFDictionary)}
    static func read(_ id:UUID) async throws -> Data {
        try await Task.detached {
            let context=LAContext(); context.localizedReason=L10n.t("解锁你的拾光日记"); context.localizedFallbackTitle=L10n.t("使用日记密码")
            defer {context.invalidate()}
            let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecReturnData as String:true,kSecUseAuthenticationContext as String:context]
            var result:CFTypeRef?
            let status=SecItemCopyMatching(query as CFDictionary,&result)
            guard status==errSecSuccess,let data=result as? Data else {throw DiaryError.storage(L10n.t("Touch ID 未完成，请使用日记密码解锁。"))}
            return data
        }.value
    }
}

@MainActor
final class LocationProvider:NSObject,@preconcurrency CLLocationManagerDelegate {
    private let manager=CLLocationManager()
    private var pending:CheckedContinuation<CLLocation,Error>?
    private var requestID:UUID?
    override init() {super.init(); manager.delegate=self; manager.desiredAccuracy=kCLLocationAccuracyKilometer}
    func locate() async throws -> CLLocation {
        guard pending==nil else {throw DiaryError.storage(L10n.t("正在获取位置，请稍候。"))}
        guard CLLocationManager.locationServicesEnabled() else {throw DiaryError.storage(L10n.t("系统定位已关闭。可以手动选择城市，或在系统设置中开启。"))}
        let id=UUID(); requestID=id
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {continuation in
                pending=continuation
                switch manager.authorizationStatus {
                case .notDetermined: manager.requestWhenInUseAuthorization()
                case .authorizedAlways,.authorizedWhenInUse: manager.requestLocation()
                default: finish(.failure(DiaryError.storage(L10n.t("未获得定位权限。可以手动选择城市，写日记不受影响。"))))
                }
                Task {try? await Task.sleep(for:.seconds(18)); if self.requestID==id {self.finish(.failure(DiaryError.storage(L10n.t("定位超时，请重试或手动选择城市。"))))}}
            }
        },onCancel:{Task {@MainActor in if self.requestID==id {self.finish(.failure(CancellationError()))}}})
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        guard pending != nil else {return}
        switch manager.authorizationStatus {case .authorizedAlways,.authorizedWhenInUse:manager.requestLocation();case .denied,.restricted:finish(.failure(DiaryError.storage(L10n.t("定位权限未开启，可以手动选择城市。"))));default:break}
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {if let position=locations.last,position.horizontalAccuracy>=0 {finish(.success(position))}}
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {finish(.failure(DiaryError.storage(L10n.t("暂时无法定位，请重试或选择城市。"))))}
    private func finish(_ result:Result<CLLocation,Error>) {let continuation=pending; pending=nil; requestID=nil; manager.stopUpdatingLocation(); continuation?.resume(with:result)}
    func city(for location:CLLocation) async -> String {
        let coarse=WeatherClient.coarse(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude)
        let place=try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude:coarse.0,longitude:coarse.1)).first
        return place?.locality ?? place?.administrativeArea ?? L10n.t("当前位置")
    }
}

enum ReminderService {
    static func configure(_ preferences:DiaryPreferences) async throws {
        let center=UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers:["daily-journal"])
        guard preferences.reminderEnabled else {return}
        let allowed=try await center.requestAuthorization(options:[.alert,.sound])
        guard allowed else {throw DiaryError.invalidInput(L10n.t("通知权限未开启，可以在系统设置中允许拾光发送提醒。"))}
        let content=UNMutableNotificationContent(); content.title=L10n.t("留一点时间给自己"); content.body=L10n.t("写下一句话，或一个值得记住的瞬间。"); content.sound = .default
        var components=DateComponents(); components.hour=preferences.reminderHour; components.minute=preferences.reminderMinute
        try await center.add(UNNotificationRequest(identifier:"daily-journal",content:content,trigger:UNCalendarNotificationTrigger(dateMatching:components,repeats:true)))
    }
}

struct ImportedPhoto {
    let id:UUID
    let preview:Data
    let size:CGSize
}

enum ImageProcessing {
    static func preview(_ data:Data) throws -> (Data,CGSize) {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1600,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else {throw DiaryError.invalidInput(L10n.t("无法读取这张图片，请选择 JPEG、PNG 或 HEIC 文件。"))}
        let bitmap=NSBitmapImageRep(cgImage:image)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw DiaryError.storage(L10n.t("图片处理失败。"))}
        return (png,CGSize(width:image.width,height:image.height))
    }
    static func sanitized(_ data:Data) throws -> Data {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw DiaryError.invalidInput(L10n.t("图片无法导出。"))}
        return png
    }
}

@MainActor
extension NSTextAttachment {
    func fitImage(maxWidth:CGFloat,maxHeight:CGFloat = 440) {
        guard let original=fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) ?? image else{return}
        let size=original.size
        guard size.width>0,size.height>0 else{return}
        let scale=min(1,maxWidth/size.width,maxHeight/size.height)
        let display=NSSize(width:size.width*scale,height:size.height*scale)
        original.size=display
        attachmentCell=NSTextAttachmentCell(imageCell:original)
        bounds=CGRect(origin:.zero,size:display)
    }
}
