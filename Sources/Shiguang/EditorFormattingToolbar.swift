import SwiftUI
import AppKit
import DiaryCore

struct EditorFormattingToolbar:View {
    @ObservedObject var controller:EditorController
    @EnvironmentObject var model:AppModel
    private struct ColorRequest:Identifiable {
        let id=UUID()
        let selection:EditorController.Selection
        let background:Bool
    }
    @ViewState private var colorRequest:ColorRequest?
    var body:some View {
        let _=model.language
        HStack(spacing:13) {
            button("bold","加粗 ⌘B","bold")
            button("italic","斜体 ⌘I","italic")
            button("underline","下划线 ⌘U","underline")
            button("strikethrough","删除线","strikethrough")
            Button{controller.beginLink()}label:{Image(systemName:"link")}.help(L10n.t("超链接 ⌘K；⌘ 单击打开链接")).accessibilityLabel(L10n.t("超链接"))
            Button{openColor(background:false)}label:{Image(systemName:"textformat.alt")}.help(L10n.t("字体颜色")).accessibilityLabel(L10n.t("字体颜色"))
            Button{openColor(background:true)}label:{Image(systemName:"highlighter")}.help(L10n.t("背景颜色")).accessibilityLabel(L10n.t("背景颜色"))
            Menu {
                Menu(L10n.t("字体")) {
                    Button(L10n.t("宋体")){controller.font(family:"Songti SC")}
                    Button(L10n.t("苹方")){controller.font(family:"PingFang SC")}
                    Button("Helvetica"){controller.font(family:"Helvetica")}
                    Button("Georgia"){controller.font(family:"Georgia")}
                    Button("Menlo"){controller.font(family:"Menlo")}
                }
                Menu(L10n.t("字号")){ForEach([14,16,18,20,24,28,32],id:\.self){size in Button("\(size) pt"){controller.font(size:CGFloat(size))}}}
                Divider()
                Button(L10n.t("列表")){controller.format("list")}
                Button(L10n.t("引用")){controller.format("quote")}
                Button(L10n.t("分隔线")){controller.format("separator")}
                Divider()
                Button(L10n.t("清除文字格式")){controller.format("clear")}
            }label:{Image(systemName:"ellipsis.circle")}.menuStyle(.borderlessButton).frame(width:22).help(L10n.t("更多文字格式")).accessibilityLabel(L10n.t("更多文字格式"))
            Spacer(minLength:0)
        }.buttonStyle(.plain).foregroundStyle(JournalTheme.muted)
        .popover(item:$colorRequest) {request in
            EditorColorPicker(background:request.background){color in
                controller.color(color,background:request.background,selection:request.selection);colorRequest=nil
            }.environmentObject(model)
        }
        .sheet(item:$controller.linkDraft){draft in EditorLinkSheet(controller:controller,draft:draft)}
    }
    private func openColor(background:Bool) {
        guard let selection=controller.selection() else{return}
        colorRequest=ColorRequest(selection:selection,background:background)
    }
    private func button(_ symbol:String,_ title:String,_ action:String) -> some View {
        Button{controller.format(action)}label:{Image(systemName:symbol)}.help(L10n.text(title)).accessibilityLabel(L10n.text(title))
    }
}

struct EditorColorPicker:View {
    let background:Bool
    let apply:(NSColor?)->Void
    @EnvironmentObject var model:AppModel
    @ViewState private var custom=Color(red:0.2,green:0.4,blue:0.3)
    private let colors:[(String,NSColor)] = [
        ("墨绿",NSColor(srgbRed:0.17,green:0.36,blue:0.27,alpha:1)),
        ("蓝色",NSColor(srgbRed:0.16,green:0.37,blue:0.69,alpha:1)),
        ("红色",NSColor(srgbRed:0.72,green:0.22,blue:0.23,alpha:1)),
        ("紫色",NSColor(srgbRed:0.49,green:0.29,blue:0.65,alpha:1)),
        ("浅黄",NSColor(srgbRed:1,green:0.89,blue:0.52,alpha:1)),
        ("浅绿",NSColor(srgbRed:0.75,green:0.87,blue:0.71,alpha:1)),
        ("浅粉",NSColor(srgbRed:0.98,green:0.77,blue:0.80,alpha:1)),
        ("浅蓝",NSColor(srgbRed:0.73,green:0.85,blue:0.97,alpha:1))
    ]
    var body:some View {
        let _=model.language
        VStack(alignment:.leading,spacing:16) {
            Text(background ? L10n.t("背景颜色"):L10n.t("字体颜色")).font(.headline)
            HStack(spacing:10){ForEach(colors,id:\.0){name,color in
                Button{apply(color)}label:{Circle().fill(Color(nsColor:color)).frame(width:23,height:23).overlay(Circle().strokeBorder(.gray.opacity(0.3)))}.buttonStyle(.plain).help(L10n.text(name)).accessibilityLabel(L10n.text(name))
            }}
            ColorPicker(L10n.t("自定义颜色"),selection:$custom,supportsOpacity:false)
            HStack {
                Button(background ? L10n.t("清除背景颜色"):L10n.t("默认字体颜色")){apply(nil)}
                Spacer()
                Button(L10n.t("应用")){apply(NSColor(custom))}.buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(width:300)
    }
}

struct EditorLinkSheet:View {
    @ObservedObject var controller:EditorController
    @EnvironmentObject var model:AppModel
    @ViewState var draft:EditorController.LinkDraft
    @Environment(\.dismiss) private var dismiss
    @ViewState private var failure=false
    var body:some View {
        let _=model.language
        VStack(alignment:.leading,spacing:18) {
            Text(L10n.t("超链接")).font(.title2)
            TextField(L10n.t("显示文字"),text:$draft.title).textFieldStyle(.roundedBorder)
            TextField(L10n.t("链接地址"),text:$draft.address).textFieldStyle(.roundedBorder)
            Text(L10n.t("支持网页和邮箱链接，例如 https://example.com 或 mailto:name@example.com。⌘ 单击正文中的链接可打开。")).font(.caption).foregroundStyle(JournalTheme.muted)
            if !draft.address.isEmpty && EditorController.safeURL(draft.address)==nil {
                Text(L10n.t("请输入有效的 http、https 或 mailto 地址。")).font(.caption).foregroundStyle(.red)
            }
            if failure {Text(L10n.t("日记内容已变化，请关闭后重新选择文字。")).font(.caption).foregroundStyle(.red)}
            HStack {
                Button(L10n.t("取消")){dismiss()}.keyboardShortcut(.cancelAction)
                if draft.selection.range.length>0 {Button(L10n.t("移除链接")){if controller.applyLink(draft,remove:true){dismiss()}else{failure=true}}}
                Spacer()
                Button(L10n.t("应用")){if controller.applyLink(draft){dismiss()}else{failure=true}}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(EditorController.safeURL(draft.address)==nil)
            }
        }.padding(28).frame(width:460).background(JournalTheme.paper)
    }
}
