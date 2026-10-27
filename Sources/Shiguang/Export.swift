import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiaryCore

@MainActor
enum DiaryExporter {
    static func rich(_ entry:DiaryEntry) -> NSAttributedString {
        (try? NSAttributedString(data:entry.richText,options:[.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes:nil)) ?? NSAttributedString(string:entry.text)
    }
    static func metadata(_ entry:DiaryEntry,location:Bool,mood:Bool) -> String {
        var lines=[entry.date.journalDateTime]
        if location,let weather=entry.weather {lines.append(L10n.t("\(weather.city) · \(weather.condition) \(weather.temperature.formatted())°C · 数据时间 \(weather.journalTimestamp) · \(weather.source)"))}
        if mood {if !entry.mood.isEmpty{lines.append(L10n.t("心情：")+L10n.text(entry.mood))};if !entry.tags.isEmpty{lines.append(L10n.t("标签：")+entry.tags.joined(separator:", "))}}
        return lines.joined(separator:"\n")
    }
    static func markdown(_ entry:DiaryEntry,to url:URL,store:VaultStore,location:Bool,mood:Bool) async throws {
        let body=rich(entry);var result="# "+entry.displayTitle+"\n\n"+metadata(entry,location:location,mood:mood)+"\n\n"
        let imageDirectory=url.deletingPathExtension().lastPathComponent+"-images"
        let imageFolder=url.deletingLastPathComponent().appendingPathComponent(imageDirectory)
        var ranges=[(NSRange,[NSAttributedString.Key:Any])]()
        body.enumerateAttributes(in:NSRange(location:0,length:body.length)) {attributes,range,_ in ranges.append((range,attributes))}
        for (range,attributes) in ranges {
            if let attachment=attributes[.attachment] as? NSTextAttachment {
                let name=attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename ?? ""
                let id=UUID(uuidString:String(name.prefix(36)))
                let data:Data
                if let id {data=try await store.attachment(id)}
                else if let embedded=attachment.fileWrapper?.regularFileContents {data=embedded}
                else if let embedded=attachment.image?.tiffRepresentation {data=embedded}
                else {throw DiaryError.storage(L10n.t("有一张图片无法导出，请检查日记。"))}
                let clean=try ImageProcessing.sanitized(data)
                try FileManager.default.createDirectory(at:imageFolder,withIntermediateDirectories:true)
                let filename=(id ?? UUID()).uuidString+".png"
                try clean.write(to:imageFolder.appendingPathComponent(filename),options:.atomic)
                let path=(imageDirectory+"/"+filename).addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? filename
                result += L10n.t("\n![照片](")+path+")\n"
            } else {
                let string=(body.string as NSString).substring(with:range)
                result += inlineMarkdown(string,attributes:attributes)
            }
        }
        if location,let weather=entry.weather,!weather.manual {result += L10n.t("\n\n天气数据：[Open-Meteo](https://open-meteo.com/)，[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。\n")}
        try Data(result.utf8).write(to:url,options:.atomic)
    }
    static func colorHex(_ value:Any?) -> String? {
        guard let color=(value as? NSColor)?.usingColorSpace(.sRGB) else{return nil}
        return String(format:"#%02X%02X%02X",Int((color.redComponent*255).rounded()),Int((color.greenComponent*255).rounded()),Int((color.blueComponent*255).rounded()))
    }
    static func inlineMarkdown(_ string:String,attributes:[NSAttributedString.Key:Any]) -> String {
        let font=attributes[.font] as? NSFont
        let bold=font.map{NSFontManager.shared.traits(of:$0).contains(.boldFontMask)} ?? false
        let italic=EditorController.isItalic(attributes)
        let underline=((attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        let strike=((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        let foreground=colorHex(attributes[.foregroundColor])
        let background=colorHex(attributes[.backgroundColor])
        let color=foreground=="#000000" ? nil:foreground
        let rawLink=(attributes[.link] as? URL)?.absoluteString ?? (attributes[.link] as? String ?? "")
        let link=EditorController.safeURL(rawLink)?.absoluteString
        let html=underline || color != nil || background != nil
        func escapedHTML(_ value:String) -> String {value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        return string.components(separatedBy:"\n").map {line in
            let leading=String(line.prefix(while:{$0.isWhitespace}))
            let remaining=line.dropFirst(leading.count)
            let trailing=String(remaining.reversed().prefix(while:{$0.isWhitespace}).reversed())
            let core=String(remaining.dropLast(trailing.count))
            guard !core.isEmpty else{return line}
            var value:String
            if html {
                value=escapedHTML(core)
                if bold {value="<strong>"+value+"</strong>"}
                if italic {value="<em>"+value+"</em>"}
                if underline {value="<u>"+value+"</u>"}
                if strike {value="<del>"+value+"</del>"}
                let styles=[color.map{"color:"+$0},background.map{"background-color:"+$0}].compactMap{$0}.joined(separator:";")
                if !styles.isEmpty {value="<span style=\""+styles+"\">"+value+"</span>"}
                if let link {value="<a href=\""+escapedHTML(link)+"\">"+value+"</a>"}
            } else {
                value=core.reduce(into:""){result,character in if "\\`*_{}[]<>#~".contains(character){result.append("\\")};result.append(character)}
                if bold && italic {value="***"+value+"***"}else if bold{value="**"+value+"**"}else if italic{value="*"+value+"*"}
                if strike {value="~~"+value+"~~"}
                if let link {value="["+value+"]("+link.replacingOccurrences(of:"(",with:"%28").replacingOccurrences(of:")",with:"%29")+")"}
            }
            return leading+value+trailing
        }.joined(separator:"\n")
    }
    static func pdf(_ entry:DiaryEntry,to url:URL,location:Bool,mood:Bool) throws {
        let content=NSMutableAttributedString(string:entry.displayTitle+"\n\n",attributes:[.font:NSFont(name:"Songti SC",size:25) ?? NSFont.systemFont(ofSize:25),.foregroundColor:NSColor.black])
        content.append(NSAttributedString(string:metadata(entry,location:location,mood:mood)+"\n\n",attributes:[.font:NSFont.systemFont(ofSize:10),.foregroundColor:NSColor.darkGray]))
        let text=NSMutableAttributedString(attributedString:rich(entry))
        let light=NSAppearance(named:.aqua)!
        light.performAsCurrentDrawingAppearance {
            for key:NSAttributedString.Key in [.foregroundColor,.backgroundColor] {
                let original=NSAttributedString(attributedString:text)
                original.enumerateAttribute(key,in:NSRange(location:0,length:original.length)){value,range,_ in
                    if let color=value as? NSColor,let resolved=color.usingColorSpace(.sRGB) {text.addAttribute(key,value:resolved,range:range)}
                }
            }
        }
        text.enumerateAttribute(.attachment,in:NSRange(location:0,length:text.length)) {value,_,_ in
            (value as? NSTextAttachment)?.fitImage(maxWidth:490,maxHeight:640)
        }
        content.append(text)
        if location,let weather=entry.weather,!weather.manual {content.append(NSAttributedString(string:L10n.t("\n\n天气数据：Open-Meteo (open-meteo.com) · CC BY 4.0"),attributes:[.font:NSFont.systemFont(ofSize:9),.foregroundColor:NSColor.darkGray]))}
        let view=NSTextView(frame:NSRect(x:0,y:0,width:499,height:100))
        view.appearance=NSAppearance(named:.aqua);view.textContainerInset=NSSize(width:0,height:0);view.textContainer?.lineFragmentPadding=0
        view.textContainer?.containerSize=NSSize(width:499,height:CGFloat.greatestFiniteMagnitude);view.isHorizontallyResizable=false;view.isVerticallyResizable=true;view.textStorage?.setAttributedString(content)
        view.layoutManager?.ensureLayout(for:view.textContainer!)
        let height=view.layoutManager?.usedRect(for:view.textContainer!).height ?? 100
        view.setFrameSize(NSSize(width:499,height:max(100,height+12)))
        let info=NSPrintInfo();info.paperSize=NSSize(width:595,height:842);info.topMargin=48;info.bottomMargin=48;info.leftMargin=48;info.rightMargin=48;info.isHorizontallyCentered=false;info.isVerticallyCentered=false;info.horizontalPagination = .fit;info.verticalPagination = .automatic
        info.jobDisposition = .save;info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL]=url
        let operation=NSPrintOperation(view:view,printInfo:info);operation.showsPrintPanel=false;operation.showsProgressPanel=false
        guard operation.run(),FileManager.default.fileExists(atPath:url.path) else {throw DiaryError.storage(L10n.t("PDF 导出未完成。"))}
    }
    static func filename(_ entry:DiaryEntry) -> String {
        let allowed=entry.displayTitle.components(separatedBy:CharacterSet(charactersIn:"/\\:?%*|\"<>\n\r")).joined(separator:"-")
        let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd"
        return formatter.string(from:entry.date)+"-"+String(allowed.prefix(45))+"-"+entry.id.uuidString.prefix(6)
    }
}

struct ExportView:View {
    @EnvironmentObject var model:AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var format="PDF"
    @ViewState private var batch=false
    @ViewState private var location=false
    @ViewState private var mood=true
    @ViewState private var exporting=false
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Text(L10n.t("带走你的日记")).font(.custom("Songti SC",size:27))
            Text(L10n.t("PDF 和 Markdown 是可读文件，导出后不受日记密码保护。图片会去掉 GPS 等元数据。")).foregroundStyle(JournalTheme.muted)
            Picker(L10n.t("格式"),selection:$format){Text("PDF").tag("PDF");Text(L10n.t("Markdown + 图片")).tag("Markdown")}.pickerStyle(.segmented)
            Toggle(L10n.t("导出当前列表中的 \(model.filtered.count) 篇日记"),isOn:$batch)
            Toggle(L10n.t("包含城市与天气"),isOn:$location)
            Toggle(L10n.t("包含心情与标签"),isOn:$mood)
            Text(batch ? L10n.t("将导出当前筛选结果，每篇保存为单独文件。"):L10n.t("将导出：")+(model.entry?.displayTitle ?? "")).font(.caption).foregroundStyle(JournalTheme.muted)
            HStack{Button(L10n.t("取消")){dismiss()}.disabled(exporting);Spacer();if exporting{ProgressView().controlSize(.small)};Button(L10n.t("选择位置并导出…")){Task{await export()}}.buttonStyle(.borderedProminent).disabled(exporting || (batch && model.filtered.isEmpty))}
        }.padding(28).frame(width:510).background(JournalTheme.paper)
    }
    private func export() async {
        guard await model.flush(),let selected=model.entry else{return}
        let target:URL
        if batch {let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L10n.t("导出到此文件夹");guard panel.runModal() == .OK,let url=panel.url else{return};target=url}
        else {let panel=NSSavePanel();panel.allowedContentTypes=format=="PDF" ? [.pdf]:[.plainText];panel.nameFieldStringValue=DiaryExporter.filename(selected)+(format=="PDF" ? ".pdf":".md");panel.allowsOtherFileTypes=true;guard panel.runModal() == .OK,let url=panel.url else{return};target=url}
        exporting=true;defer{exporting=false}
        let access=target.startAccessingSecurityScopedResource();defer{if access{target.stopAccessingSecurityScopedResource()}}
        do {
            let ids=batch ? model.filtered.map(\.id):[selected.id]
            var count=0
            for id in ids {
                guard let entry=try await model.store.entry(id) else{continue}
                let url:URL
                if batch {
                    let suffix=format=="PDF" ? "pdf":"md";let base=DiaryExporter.filename(entry)
                    var candidate=target.appendingPathComponent(base+"."+suffix);var number=1
                    while FileManager.default.fileExists(atPath:candidate.path){candidate=target.appendingPathComponent(base+"-\(number)."+suffix);number+=1}
                    url=candidate
                }else{url=target}
                if format=="PDF" {try DiaryExporter.pdf(entry,to:url,location:location,mood:mood)}else{try await DiaryExporter.markdown(entry,to:url,store:model.store,location:location,mood:mood)}
                count+=1
            }
            model.notice=L10n.t("已导出 \(count) 篇日记。导出文件不受保险库加密保护。");dismiss()
        }catch{model.error=L10n.t("导出未全部完成：")+error.localizedDescription}
    }
}
