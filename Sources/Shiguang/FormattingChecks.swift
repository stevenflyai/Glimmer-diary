#if DEBUG
import AppKit
import PDFKit
import DiaryCore

@MainActor
enum FormattingChecks {
    static func run(root:URL) async throws {
        let model=AppModel(supportOverride:root.appendingPathComponent("format-"+UUID().uuidString))
        let password="disposable-rich-format-check"
        _=try await model.store.create(password:password)
        model.unlocked=true;model.preferences.autoBackup=false
        let oldLanguage=L10n.language
        defer {L10n.language=oldLanguage}
        L10n.language="zh-Hans"
        var entry=DiaryEntry();entry.title="保留中文标题";entry.notebook="我的 notebook";entry.tags=["平静","Personal"]
        let original=NSAttributedString(string:"中文 italic link\n第二段",attributes:[.font:NSFont(name:"Songti SC",size:18)!])
        entry.text=original.string;entry.richText=try original.data(from:NSRange(location:0,length:original.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
        model.entry=entry;try await model.store.save(entry)
        let refresh=UUID()
        let editor=RichEditor(data:entry.richText,refresh:refresh,preferences:model.preferences,controller:model.editor,changed:{model.editorChanged($0,text:$1,attachments:$2)},importFiles:{_ in},importData:{_ in},preview:{_ in})
        let coordinator=editor.makeCoordinator();let scroll=editor.makeScrollView(coordinator:coordinator)
        scroll.frame=NSRect(x:0,y:0,width:700,height:380)
        let text=scroll.documentView as! DiaryTextView
        let window=NSWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.title="Rich text regression checks";window.contentView=scroll;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
        defer {window.orderOut(nil)}
        try await Task.sleep(for:.milliseconds(300))
        let range=(text.string as NSString).range(of:"中文 italic")
        text.setSelectedRange(range)
        for action in ["bold","italic","underline","strikethrough"] {model.editor.format(action)}
        var attrs=text.textStorage!.attributes(at:0,effectiveRange:nil)
        try require(NSFontManager.shared.traits(of:attrs[.font] as! NSFont).contains(.boldFontMask),"Bold failed")
        try require(EditorController.isItalic(attrs),"Chinese Songti italic fallback failed")
        try require(number(attrs[.underlineStyle])==1 && number(attrs[.strikethroughStyle])==1,"Underline / strike failed")
        try require(text.selectedRange()==range,"Formatting moved selection")
        print("PASS · Combined bold, Songti italic, underline and strikethrough preserve the selection")

        let red=NSColor(srgbRed:0.8,green:0.1,blue:0.2,alpha:1),yellow=NSColor(srgbRed:1,green:0.9,blue:0.5,alpha:1)
        model.editor.color(red,background:false);model.editor.color(yellow,background:true)
        model.editor.font(size:24)
        let draft=EditorController.LinkDraft(selection:model.editor.selection()!,title:"中文 italic",address:"https://example.com/diary?q=a&b=2")
        try require(model.editor.applyLink(draft),"Apply link failed")
        attrs=text.textStorage!.attributes(at:0,effectiveRange:nil)
        try require(DiaryExporter.colorHex(attrs[.foregroundColor])=="#CC1A33" && DiaryExporter.colorHex(attrs[.backgroundColor])=="#FFE680","Colors failed")
        try require((attrs[.font] as? NSFont)?.pointSize==24 && attrs[.link] != nil,"Font size / link failed")
        model.editor.font(family:"Helvetica")
        model.editor.font(family:"Songti SC")
        try require(EditorController.isItalic(text.textStorage!.attributes(at:0,effectiveRange:nil)),"Changing font families lost italic")
        print("PASS · Text color, highlight, font size and links combine without losing other styles")

        let undo=text.undoManager!;undo.removeAllActions();undo.beginUndoGrouping()
        model.editor.applyLink(draft,remove:true);undo.endUndoGrouping()
        try require(text.textStorage!.attribute(.link,at:0,effectiveRange:nil)==nil,"Remove link failed")
        undo.undo();try require(text.textStorage!.attribute(.link,at:0,effectiveRange:nil) != nil,"Link removal undo failed")
        undo.redo();try require(text.textStorage!.attribute(.link,at:0,effectiveRange:nil)==nil,"Link removal redo failed")
        _=model.editor.applyLink(draft)
        print("PASS · Link removal supports undo and redo")

        _=await model.flush()
        let saved=try await model.store.entry(entry.id)!
        coordinator.load(text,data:saved.richText,refresh:UUID(),preferences:model.preferences)
        attrs=text.textStorage!.attributes(at:0,effectiveRange:nil)
        try require(EditorController.isItalic(attrs) && number(attrs[.underlineStyle])==1 && number(attrs[.strikethroughStyle])==1,"RTFD lost style")
        try require(DiaryExporter.colorHex(attrs[.foregroundColor])=="#CC1A33" && DiaryExporter.colorHex(attrs[.backgroundColor])=="#FFE680","Reload replaced colors")
        try require((attrs[.font] as? NSFont)?.pointSize==24 && attrs[.link] != nil,"Reload replaced font or link")
        await model.store.lock();try await model.store.unlock(password:password)
        let reopened=try await model.store.entry(entry.id)!
        try require(reopened.richText==saved.richText,"Encrypted reopen changed rich text")
        print("PASS · RTFD reload and encrypted reopen preserve every rich text attribute")

        text.setSelectedRange(NSRange(location:text.textStorage!.length,length:0));model.editor.format("clear")
        model.editor.format("italic");model.editor.color(red,background:false)
        let insertion=text.selectedRange().location;text.insertText(" 新文字",replacementRange:text.selectedRange())
        attrs=text.textStorage!.attributes(at:insertion,effectiveRange:nil)
        try require(EditorController.isItalic(attrs) && DiaryExporter.colorHex(attrs[.foregroundColor])=="#CC1A33","Future typing attributes failed")
        text.setSelectedRange(NSRange(location:insertion,length:4));model.editor.format("clear")
        attrs=text.textStorage!.attributes(at:insertion,effectiveRange:nil)
        try require(!EditorController.isItalic(attrs) && attrs[.backgroundColor]==nil,"Clear formatting failed")
        print("PASS · Formatting at the caret affects new text; clear formatting restores defaults")

        for invalid in ["javascript:alert(1)","data:text/html,x","file:///etc/hosts","custom:run","https://", "https://bad host"] {
            try require(EditorController.safeURL(invalid)==nil,"Unsafe or invalid link accepted: "+invalid)
        }
        try require(EditorController.safeURL("example.com")?.scheme=="https" && EditorController.safeURL("mailto:me@example.com") != nil,"Conventional links rejected")
        try require(!model.editor.applyLink(draft),"Stale document selection was applied")
        print("PASS · Link validation rejects unsupported schemes and stale document selections")

        text.setSelectedRange(NSRange(location:text.textStorage!.length,length:0))
        text.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked=text.markedRange(),selection=text.selectedRange(),buffer=text.string
        model.editor.format("italic");model.editor.beginLink();model.editor.color(red,background:false)
        model.setLanguage("en")
        coordinator.load(text,data:model.entry!.richText,refresh:coordinator.loaded!,preferences:model.preferences)
        _=await model.flush()
        try require(text.hasMarkedText() && text.markedRange()==marked && text.selectedRange()==selection && text.string==buffer,"Formatting / language switch disturbed IME")
        text.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0))
        print("PASS · Formatting and language changes leave active pinyin composition untouched")

        try require(L10n.t("超链接")=="Link" && L10n.t("天气")=="Weather","English bundle lookup failed")
        let literal="日记{1}"
        try require(L10n.t("密码太短：当前 \(7) 个字符，至少需要 10 个。").contains("7"),"Interpolation failed")
        try require(L10n.t("\(literal) 篇日记").contains(literal),"Placeholder replacement changed user values")
        try require(model.entry!.title==entry.title && model.entry!.tags==entry.tags && model.entry!.notebook==entry.notebook,"Language changed user data")
        let preferences=try JSONDecoder().decode(DiaryPreferences.self,from:JSONEncoder().encode(model.preferences))
        try require(preferences.notebooks==model.preferences.notebooks,"Language changed existing notebooks")
        model.setLanguage("zh-Hans");try require(L10n.t("超链接")=="超链接","Chinese switch failed")
        print("PASS · English / Chinese lookup and interpolation work; switching preserves user content and preferences")

        let destination=root.appendingPathComponent("formatted.md")
        try await DiaryExporter.markdown(saved,to:destination,store:model.store,location:false,mood:false)
        let markdown=try String(contentsOf:destination,encoding:.utf8)
        try require(markdown.contains("<em>") && markdown.contains("<u>") && markdown.contains("<del>") && markdown.contains("color:#CC1A33") && markdown.contains("background-color:#FFE680") && markdown.contains("href=\"https://example.com"),"Markdown dropped styles")
        let plainAttributes:[NSAttributedString.Key:Any]=[.font:NSFontManager.shared.convert(NSFont.systemFont(ofSize:18),toHaveTrait:[.boldFontMask,.italicFontMask]),.link:URL(string:"https://example.com")!]
        try require(DiaryExporter.inlineMarkdown(" hello ",attributes:plainAttributes)==" [***hello***](https://example.com) ","Standard Markdown / surrounding whitespace failed")
        let malicious=DiaryExporter.inlineMarkdown("<script>&",attributes:[.underlineStyle:1,.link:"javascript:alert(1)"])
        try require(!malicious.contains("<script>") && !malicious.contains("href="),"Markdown HTML escaping failed")
        let pdf=root.appendingPathComponent("formatted.pdf");try DiaryExporter.pdf(saved,to:pdf,location:false,mood:false)
        guard let document=PDFDocument(url:pdf) else{throw DiaryError.storage("PDF unreadable")}
        try require(document.string?.contains("italic")==true,"Formatted PDF dropped text")
        print("PASS · Markdown preserves links, combined styles and colors with safe escaping; formatted PDF renders")
        await model.store.lock()
    }
    private static func number(_ value:Any?) -> Int {(value as? NSNumber)?.intValue ?? 0}
    private static func require(_ condition:Bool,_ message:String) throws {if !condition{throw DiaryError.storage(message)}}
}
#endif
