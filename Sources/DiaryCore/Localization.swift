import Foundation

public enum L10n {
    public static var language:String {
        get {UserDefaults.standard.string(forKey:"Shiguang.interfaceLanguage")=="en" ? "en":"zh-Hans"}
        set {
            let value=newValue=="en" ? "en":"zh-Hans"
            UserDefaults.standard.set(value,forKey:"Shiguang.interfaceLanguage")
            UserDefaults.standard.set([value],forKey:"AppleLanguages")
        }
    }
    public static var locale:Locale {Locale(identifier:language)}
    private static let resources:Bundle = {
        if let url=Bundle.main.url(forResource:"Shiguang_DiaryCore",withExtension:"bundle"),let bundle=Bundle(url:url) {return bundle}
        return Bundle.module
    }()
    public static func text(_ key:String,language:String? = nil) -> String {
        guard let path=resources.path(forResource:language ?? self.language,ofType:"lproj"),let bundle=Bundle(path:path) else {return key}
        return bundle.localizedString(forKey:key,value:key,table:nil)
    }
    public static func t(_ phrase:Phrase) -> String {
        let template=text(phrase.key)
        let result=NSMutableString(string:template)
        let expression=try! NSRegularExpression(pattern:"\\{([0-9]+)\\}")
        for match in expression.matches(in:template,range:NSRange(location:0,length:(template as NSString).length)).reversed() {
            let index=Int((template as NSString).substring(with:match.range(at:1))) ?? -1
            if phrase.arguments.indices.contains(index) {result.replaceCharacters(in:match.range,with:phrase.arguments[index])}
        }
        return result as String
    }
    public struct Phrase:ExpressibleByStringLiteral,ExpressibleByStringInterpolation,Sendable {
        public let key:String
        public let arguments:[String]
        public init(stringLiteral value:String) {key=value;arguments=[]}
        public init(stringInterpolation:Interpolation) {key=stringInterpolation.key;arguments=stringInterpolation.arguments}
        public struct Interpolation:StringInterpolationProtocol,Sendable {
            var key=""
            var arguments=[String]()
            public init(literalCapacity:Int,interpolationCount:Int) {}
            public mutating func appendLiteral(_ value:String) {key += value}
            public mutating func appendInterpolation<T>(_ value:T) {key += "{\(arguments.count)}";arguments.append(String(describing:value))}
        }
    }
}
