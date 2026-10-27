#if DEBUG
import AppKit
import DiaryCore

/// Exercises the real NSTextInputClient and autosave path, without using a user's input source or vault.
@MainActor
enum EditorIMEChecks {
    static func run(root:URL) async throws {
        let model=AppModel(supportOverride:root.appendingPathComponent("ime-"+UUID().uuidString))
        _=try await model.store.create(password:"disposable-ime-test-passphrase")
        model.unlocked=true;model.preferences.autoBackup=false
        let original="已确认的中文🙂。\n继续记录："
        let attributed=NSAttributedString(string:original,attributes:[.font:NSFont.systemFont(ofSize:18)])
        var entry=DiaryEntry();entry.text=original;entry.title="中文输入检查"
        entry.richText=try attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
        try await model.store.save(entry);model.entry=entry;model.summaries=try await model.store.list()
        let refresh=UUID()
        let editor=RichEditor(data:entry.richText,refresh:refresh,preferences:model.preferences,controller:model.editor,changed:{model.editorChanged($0,text:$1,attachments:$2)},importFiles:{_ in},importData:{_ in},preview:{_ in})
        let coordinator=editor.makeCoordinator()
        let scroll=editor.makeScrollView(coordinator:coordinator)
        scroll.frame=NSRect(x:0,y:0,width:680,height:360)
        guard let text=scroll.documentView as? DiaryTextView else {throw DiaryError.storage("Missing editor")}
        let window=NSWindow(contentRect:scroll.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.title="拾光 · 中文输入回归检查";window.contentView=scroll
        window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
        defer {window.orderOut(nil)}
        try await Task.sleep(for:.milliseconds(300))
        text.setSelectedRange(NSRange(location:(original as NSString).length,length:0))
        model.changed {$0.title="自动保存正在等待"}
        text.setMarkedText("zhong",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        let marked=text.markedRange(),selection=text.selectedRange()
        try require(text.hasMarkedText(),"Native marked text did not start")
        try await Task.sleep(for:.milliseconds(1400))
        try require(text.hasMarkedText() && text.markedRange()==marked && text.selectedRange()==selection,"Autosave committed pinyin or moved the IME selection")
        try require(model.entry?.text==original,"Unconfirmed pinyin entered the model")
        let saved=try await model.store.entry(entry.id)
        try require(saved?.text==original,"Unconfirmed pinyin reached disk")
        print("PASS · Autosave preserves marked pinyin, selection and committed disk content")

        for _ in 0..<5 {coordinator.load(text,data:model.entry!.richText,refresh:refresh,preferences:model.preferences)}
        try require(text.hasMarkedText() && text.markedRange()==marked && text.selectedRange()==selection,"View updates disturbed composition")
        var newPreferences=model.preferences;newPreferences.fontSize=22
        let originalFont=text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        coordinator.load(text,data:model.entry!.richText,refresh:refresh,preferences:newPreferences)
        let duringCompositionFont=text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        try require(text.hasMarkedText() && text.markedRange()==marked && text.selectedRange()==selection && originalFont?.pointSize==duringCompositionFont?.pointSize,"Typography was applied inside an active composition")
        _=await model.flush()
        try require(text.hasMarkedText() && text.markedRange()==marked,"Manual save disturbed composition")
        print("PASS · Repeated view updates and manual save preserve the active composition")

        text.insertText("中文",replacementRange:NSRange(location:NSNotFound,length:0))
        try require(!text.hasMarkedText(),"Candidate commit did not finish composition")
        try require(text.string==original+"中文","Candidate text was lost or duplicated")
        coordinator.load(text,data:model.entry!.richText,refresh:refresh,preferences:newPreferences)
        let committedFont=text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont
        try require(committedFont?.pointSize==22,"Deferred typography was not applied after composition")
        try await Task.sleep(for:.milliseconds(1400))
        let committed=try await model.store.entry(entry.id)
        try require(committed?.text==original+"中文","Committed Chinese was not autosaved")
        try require(text.selectedRange().location==(text.string as NSString).length,"Caret jumped after save")
        print("PASS · Chinese candidates commit once, autosave and retain the caret")

        text.setSelectedRange(NSRange(location:0,length:0))
        text.setMarkedText("tianqi",selectedRange:NSRange(location:6,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        _=await model.flush()
        try require(text.hasMarkedText(),"Composition at the start of an existing entry was interrupted")
        text.insertText("天气",replacementRange:NSRange(location:NSNotFound,length:0))
        try await Task.sleep(for:.milliseconds(1400))
        let mixed=try await model.store.entry(entry.id)
        try require(mixed?.text=="天气"+original+"中文","Mid-document Chinese edit was not preserved")
        print("PASS · Editing before existing mixed Chinese/emoji text preserves the content")

        let beforeCancel=text.string
        text.setMarkedText("quxiao",selectedRange:NSRange(location:6,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        _=await model.flush()
        text.insertText("",replacementRange:text.markedRange())
        _=await model.flush()
        try require(!text.hasMarkedText() && text.string==beforeCancel && model.entry?.text==beforeCancel,"Cancelling composition leaked pinyin or lost committed text")
        print("PASS · Cancelling a composition preserves the committed text")

        guard let undo=text.undoManager else {throw DiaryError.storage("Undo manager unavailable")}
        undo.removeAllActions();undo.beginUndoGrouping()
        text.setMarkedText("ceshi",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        text.insertText("测试",replacementRange:NSRange(location:NSNotFound,length:0))
        undo.endUndoGrouping()
        let afterInsert=text.string
        try await Task.sleep(for:.milliseconds(1400))
        try require(undo.canUndo,"Autosave removed the undo history")
        undo.undo()
        try require(text.string==beforeCancel,"Undo did not restore the text before candidate selection")
        undo.redo()
        try require(text.string==afterInsert,"Redo duplicated or lost Chinese text")
        _=await model.flush()
        print("PASS · Undo and redo work after Chinese candidate selection and autosave")

        var next=DiaryEntry();next.text="另一篇测试日记";try await model.store.save(next)
        text.setMarkedText("draft",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        await model.select(next.id)
        try require(model.entry?.id==next.id && !text.hasMarkedText(),"Explicit navigation did not finish editing")
        let beforeReopen=try await model.store.entry(entry.id)
        try require(beforeReopen?.text==text.string,"Navigation lost the editor's final buffer")
        await model.store.lock()
        try await model.store.unlock(password:"disposable-ime-test-passphrase")
        let reopened=try await model.store.entry(entry.id)
        try require(reopened?.text==beforeReopen?.text,"Reopening changed saved Chinese text")
        await model.store.lock()
        print("PASS · Explicit navigation saves the final buffer; encrypted reopen preserves it")
    }
    private static func require(_ condition:Bool,_ message:String) throws {
        if !condition {throw DiaryError.storage(message)}
    }
}
#endif
