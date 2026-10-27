import AppKit
import DiaryCore

@MainActor
enum AboutPanel {
    static let author="Steven Lian"
    static let email="stevenlian2981@gmail.com"

    static func show() {
        let paragraph=NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing=5
        let credits=NSMutableAttributedString(
            string:L10n.t("作者：")+author+"\n"+L10n.t("邮箱：")+email,
            attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]
        )
        let emailRange=(credits.string as NSString).range(of:email)
        credits.addAttributes([.link:URL(string:"mailto:"+email)!, .foregroundColor:NSColor.linkColor, .underlineStyle:NSUnderlineStyle.single.rawValue],range:emailRange)
        NSApp.orderFrontStandardAboutPanel(options:[
            .applicationName:L10n.t("拾光"),
            .credits:credits
        ])
    }
}
