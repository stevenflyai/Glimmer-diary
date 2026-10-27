import Foundation

public struct WeatherCity: Decodable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let country: String?
    public let admin1: String?
    public var label: String { [name,admin1,country].compactMap {$0}.reduce(into:[String]()) { if !$0.contains($1) {$0.append($1)} }.joined(separator:" · ") }
}
public enum WeatherClient {
    public static func coarse(latitude:Double,longitude:Double) -> (Double,Double) { ((latitude*20).rounded()/20,(longitude*20).rounded()/20) }
    public static func fetch(latitude:Double,longitude:Double,city:String) async throws -> WeatherSnapshot {
        let (lat,lon)=coarse(latitude:latitude,longitude:longitude)
        guard (-90...90).contains(lat),(-180...180).contains(lon) else {throw DiaryError.invalidInput(L10n.t("位置无效。"))}
        var url=URLComponents(string:"https://api.open-meteo.com/v1/forecast")!
        url.queryItems=[.init(name:"latitude",value:String(lat)),.init(name:"longitude",value:String(lon)),.init(name:"current",value:"temperature_2m,weather_code"),.init(name:"timezone",value:"auto"),.init(name:"timeformat",value:"unixtime"),.init(name:"forecast_days",value:"1")]
        struct Response:Decodable {struct Current:Decodable {var time:Double;var temperature_2m:Double;var weather_code:Int};var current:Current;var timezone:String}
        let response:Response=try await request(url.url!)
        return WeatherSnapshot(city:city,temperature:response.current.temperature_2m,code:response.current.weather_code,observedAt:Date(timeIntervalSince1970:response.current.time),timeZone:response.timezone)
    }
    public static func search(_ name:String) async throws -> [WeatherCity] {
        guard name.trimmingCharacters(in:.whitespacesAndNewlines).count>=2 else {return []}
        var url=URLComponents(string:"https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems=[.init(name:"name",value:name),.init(name:"count",value:"8"),.init(name:"language",value:L10n.language=="en" ? "en":"zh"),.init(name:"format",value:"json")]
        struct Response:Decodable {var results:[WeatherCity]?}
        let result:Response=try await request(url.url!); return result.results ?? []
    }
    private static func request<T:Decodable>(_ url:URL) async throws -> T {
        let config=URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest=15; config.timeoutIntervalForResource=25; config.urlCache=nil; config.httpCookieStorage=nil
        let session=URLSession(configuration:config); defer {session.finishTasksAndInvalidate()}
        let (data,response)=try await session.data(from:url)
        guard let http=response as? HTTPURLResponse,http.statusCode==200,data.count<2_000_000 else {throw DiaryError.storage(L10n.t("天气服务暂不可用，请稍后重试。"))}
        return try JSONDecoder().decode(T.self,from:data)
    }
}
