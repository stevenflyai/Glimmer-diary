#if DEBUG
import AppKit
import DiaryCore

@MainActor
enum EditorParagraphChecks {
    static func run() throws {
        let controller=EditorController()
        var serialized=Data(),attachmentIDs=[UUID](),changeCount=0
        let empty=try NSAttributedString(string:"").data(from:NSRange(location:0,length:0),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
        let editor=RichEditor(data:empty,refresh:UUID(),preferences:DiaryPreferences(),controller:controller,changed:{data,_,ids in serialized=data;attachmentIDs=ids;changeCount += 1},importFiles:{_ in},importData:{_ in},preview:{_ in})
        let coordinator=editor.makeCoordinator()
        let scroll=editor.makeScrollView(coordinator:coordinator)
        scroll.frame=NSRect(x:0,y:0,width:650,height:350)
        let text=scroll.documentView as! DiaryTextView
        let window=NSWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=scroll;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
        defer {window.orderOut(nil)}
        func reset(_ value:String,_ selection:NSRange) {
            text.textStorage!.setAttributedString(NSAttributedString(string:value,attributes:[.font:text.defaultFont]))
            text.setSelectedRange(selection);text.typingAttributes=[.font:text.defaultFont];text.undoManager?.removeAllActions()
        }
        func require(_ condition:Bool,_ message:String) throws {if !condition {throw DiaryError.storage(message)}}
        func checkUndo(_ before:NSAttributedString,selection:NSRange,action:()->Void) throws {
            let undo=text.undoManager!
            undo.removeAllActions();undo.beginUndoGrouping();action();undo.endUndoGrouping()
            let after=NSAttributedString(attributedString:text.textStorage!),afterSelection=text.selectedRange()
            undo.undo()
            try require(text.textStorage!.isEqual(to:before) && text.selectedRange()==selection,"Undo lost attributes or selection")
            undo.redo()
            try require(text.textStorage!.isEqual(to:after) && text.selectedRange()==afterSelection,"Redo lost attributes or selection")
        }
        var failures=[String]()
        reset("中文日记\nEnglish diary",NSRange(location:0,length:18))
        controller.format("list")
        if text.string != "• 中文日记\n• English diary" {failures.append("Selected list text was lost: \(text.string.debugDescription)")}
        reset("• 第一项",NSRange(location:5,length:0))
        text.insertNewline(nil)
        if text.string != "• 第一项\n• " {failures.append("Return did not continue list: \(text.string.debugDescription)")}
        guard failures.isEmpty else {throw DiaryError.invalidInput(failures.joined(separator:"; "))}
        print("PASS · Paragraph commands preserve selected text and Return continues lists")

        reset("第一段\n第二段\n第三段",NSRange(location:1,length:7))
        let original=NSAttributedString(attributedString:text.textStorage!)
        try checkUndo(original,selection:text.selectedRange()){controller.format("list")}
        try require(text.string=="• 第一段\n• 第二段\n第三段","Selection boundary formatted an unselected paragraph")
        controller.format("list")
        try require(text.string==original.string && text.selectedRange()==NSRange(location:1,length:7),"List toggle failed to restore selected text")
        text.setSelectedRange(NSRange(location:6,length:0));controller.format("quote")
        try require(text.string=="第一段\n❝ 第二段\n第三段" && text.selectedRange().location==8,"Caret command failed to format only current paragraph")
        controller.format("list")
        try require(text.string=="第一段\n• 第二段\n第三段","Switching quote to list accumulated prefixes")
        print("PASS · Multiline toggle, paragraph boundaries, caret formatting and exact undo/redo")

        let mixed="• 中文🙂\r\nEnglish👩🏽‍💻\u{2029}❝ 最后一段"
        reset(mixed,NSRange(location:0,length:(mixed as NSString).length));controller.format("list")
        try require(text.string=="• 中文🙂\r\n• English👩🏽‍💻\u{2029}• 最后一段","Mixed prefixes, emoji or Unicode paragraph boundaries were damaged")
        controller.format("quote")
        try require(text.string=="❝ 中文🙂\r\n❝ English👩🏽‍💻\u{2029}❝ 最后一段","Quote conversion failed")
        controller.format("quote")
        try require(text.string=="中文🙂\r\nEnglish👩🏽‍💻\u{2029}最后一段","Quote toggle lost content")
        reset("已有一段\n",NSRange(location:5,length:0));controller.format("list")
        try require(text.string=="已有一段\n• ","Trailing empty paragraph could not become a list")
        print("PASS · Mixed list/quote paragraphs, CRLF, Unicode separators, emoji and trailing empty paragraphs")

        reset("• 第一项",NSRange(location:5,length:0))
        try checkUndo(NSAttributedString(attributedString:text.textStorage!),selection:text.selectedRange()){text.insertNewline(nil)}
        text.insertText("第二项",replacementRange:text.selectedRange());text.insertNewline(nil)
        try require(text.string=="• 第一项\n• 第二项\n• ","Repeated list continuation failed")
        text.insertNewline(nil)
        try require(text.string=="• 第一项\n• 第二项\n","Return did not exit an empty item")
        text.insertText("普通正文",replacementRange:text.selectedRange());text.insertNewline(nil)
        try require(text.string.hasSuffix("普通正文\n"),"List formatting leaked into ordinary paragraphs")
        reset("• \t\n后面的文字",NSRange(location:3,length:0));text.insertNewline(nil)
        try require(text.string=="\n后面的文字","Exiting a whitespace-only item damaged the next paragraph")
        reset("",NSRange(location:0,length:0));controller.format("list");text.insertNewline(nil)
        try require(text.string.isEmpty,"Empty document list exit failed")
        print("PASS · Return continues repeatedly, exits empty/whitespace items and preserves following paragraphs")

        reset("• 前半🙂后半",NSRange(location:6,length:0));text.insertNewline(nil)
        try require(text.string=="• 前半🙂\n• 后半","Splitting a list item lost suffix text")
        reset("• 一二三",NSRange(location:3,length:1));text.insertNewline(nil)
        try require(text.string=="• 一\n• 三","Return with a selection damaged unselected content")
        reset("❝ 引用内容",NSRange(location:6,length:0));text.insertNewline(nil)
        try require(text.string=="❝ 引用内容\n❝ ","Quote continuation failed")
        text.insertNewline(nil);try require(text.string=="❝ 引用内容\n","Quote exit failed")
        reset("• 保留内容",NSRange(location:2,length:0))
        try checkUndo(NSAttributedString(attributedString:text.textStorage!),selection:text.selectedRange()){text.deleteBackward(nil)}
        try require(text.string=="保留内容","Backspace at content start deleted content")
        reset("• 第一行",NSRange(location:5,length:0));text.insertLineBreak(nil)
        try require(text.string=="• 第一行\u{2028}","Soft line break created an unwanted bullet")
        print("PASS · Mid-item split, selected Return, quote continuation, prefix Backspace and soft line break")

        reset("第一段\n第二段",NSRange(location:1,length:2))
        try checkUndo(NSAttributedString(attributedString:text.textStorage!),selection:text.selectedRange()){controller.format("separator")}
        try require(text.string=="第一段\n────────────\n第二段","Separator replaced selected text or merged paragraphs")
        reset("末尾正文",NSRange(location:0,length:4));controller.format("separator")
        try require(text.string=="末尾正文\n────────────\n","Separator at document end lost content")
        let unchanged=text.string;controller.format("unknown-command")
        try require(text.string==unchanged,"Unknown command inserted content")
        print("PASS · Separators preserve selected paragraphs and undo; unknown commands do nothing")

        let rich=NSMutableAttributedString(string:"彩色链接🙂\n",attributes:[.font:NSFont.boldSystemFont(ofSize:23),.foregroundColor:NSColor.systemRed,.backgroundColor:NSColor.systemYellow,.underlineStyle:1,.link:URL(string:"https://example.com")!])
        let imageID=UUID(),wrapper=FileWrapper(regularFileWithContents:Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aWuoAAAAASUVORK5CYII=")!)
        wrapper.preferredFilename=imageID.uuidString+".png"
        rich.append(NSAttributedString(attachment:NSTextAttachment(fileWrapper:wrapper)))
        text.textStorage!.setAttributedString(rich);text.setSelectedRange(NSRange(location:0,length:rich.length))
        changeCount=0
        try checkUndo(rich,selection:text.selectedRange()){controller.format("list")}
        try require(changeCount==3 && attachmentIDs==[imageID],"Formatting did not emit one complete autosave change per edit/undo/redo")
        let encoded=try NSAttributedString(data:serialized,options:[.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes:nil)
        try require(encoded.string==text.string && encoded.attribute(.link,at:2,effectiveRange:nil) != nil && (encoded.attribute(.font,at:2,effectiveRange:nil) as? NSFont)?.pointSize==23,"RTFD lost list text, links or fonts")
        try require(DiaryExporter.colorHex(encoded.attribute(.foregroundColor,at:2,effectiveRange:nil))==DiaryExporter.colorHex(rich.attribute(.foregroundColor,at:0,effectiveRange:nil)),"RTFD lost color")
        try require(text.textStorage!.attribute(.attachment,at:text.textStorage!.length-1,effectiveRange:nil) != nil && text.textStorage!.attribute(.link,at:0,effectiveRange:nil)==nil,"List marker inherited a link or lost an image")
        controller.format("list")
        try require(text.textStorage!.isEqual(to:rich),"List round trip changed original rich text or image")
        print("PASS · List edits preserve images, rich attributes, RTFD and autosave notifications")

        for family in ["Songti SC","PingFang SC","Helvetica","Georgia","Menlo"] {
            reset("保存后继续写",NSRange(location:6,length:0))
            text.textStorage!.addAttribute(.font,value:NSFont(name:family,size:18)!,range:NSRange(location:0,length:6))
            controller.format("list")
            let restored=try NSAttributedString(data:serialized,options:[.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes:nil)
            text.textStorage!.setAttributedString(restored);text.setSelectedRange(NSRange(location:restored.length,length:0))
            text.insertNewline(nil)
            try require(text.string==restored.string+"\n"+String(restored.string.prefix(2)),"Saved list failed to continue with font "+family)
            text.insertNewline(nil);text.setSelectedRange(NSRange(location:0,length:restored.length));controller.format("list")
            try require(text.string=="保存后继续写\n","Saved list failed to toggle off with font "+family)
        }
        reset("· 旧版列表",NSRange(location:6,length:0));text.insertNewline(nil)
        try require(text.string=="· 旧版列表\n· ","Legacy middle-dot list did not continue")
        print("PASS · Lists round-trip and continue in all five toolbar fonts, including legacy Songti middle dots")

        reset("• 中文",NSRange(location:4,length:0))
        text.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked=text.markedRange(),selection=text.selectedRange(),buffer=text.string
        for action in ["list","quote","separator"] {controller.format(action)}
        try require(text.hasMarkedText() && text.markedRange()==marked && text.selectedRange()==selection && text.string==buffer,"Paragraph formatting disturbed active pinyin")
        text.insertText("中",replacementRange:NSRange(location:NSNotFound,length:0));text.insertNewline(nil)
        try require(text.string=="• 中文中\n• ","Committed Chinese candidate or list continuation was lost")
        print("PASS · Paragraph commands leave active IME composition untouched; committed Chinese continues correctly")
    }
}
#endif
