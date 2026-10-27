import SwiftUI
import AppKit
import DiaryCore

@MainActor
final class EditorController:ObservableObject {
    weak var textView:DiaryTextView?
    func commitComposition() {
        if let view=textView,view.hasMarkedText() {view.unmarkText();view.didChangeText()}
    }
    @Published var linkDraft:LinkDraft?
    struct Selection {
        let document:UUID
        let range:NSRange
    }
    struct LinkDraft:Identifiable {
        let id=UUID()
        let selection:Selection
        var title:String
        var address:String
    }
    func selection() -> Selection? {
        guard let view=textView,!view.hasMarkedText(),let document=view.documentID else {NSSound.beep();return nil}
        return Selection(document:document,range:view.selectedRange())
    }
    func validView(_ selection:Selection) -> DiaryTextView? {
        guard let view=textView,view.documentID==selection.document,!view.hasMarkedText(),NSMaxRange(selection.range)<=(view.textStorage?.length ?? 0) else {return nil}
        return view
    }
    static func safeURL(_ address:String) -> URL? {
        var value=address.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,!value.contains(where:{$0.isWhitespace || $0.isNewline}) else{return nil}
        if !value.contains(":") {value="https://"+value}
        guard let url=URL(string:value),let scheme=url.scheme?.lowercased() else{return nil}
        if scheme=="mailto" {return url.path.contains("@") ? url:nil}
        guard ["http","https"].contains(scheme),let host=url.host,!host.isEmpty else{return nil}
        return url
    }
    static func isItalic(_ attributes:[NSAttributedString.Key:Any]) -> Bool {
        let trait=(attributes[.font] as? NSFont).map{NSFontManager.shared.traits(of:$0).contains(.italicFontMask)} ?? false
        return trait || ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) != 0
    }
    func style(_ selection:Selection? = nil,transform:([NSAttributedString.Key:Any])->[NSAttributedString.Key:Any]) {
        guard let selection=selection ?? self.selection(),let view=validView(selection) else{return}
        let range=selection.range
        if range.length==0 {view.typingAttributes=transform(view.typingAttributes)}
        else if let storage=view.textStorage,view.shouldChangeText(in:range,replacementString:nil) {
            let old=storage.attributedSubstring(from:range)
            view.undoManager?.registerUndo(withTarget:view){$0.restoreStyle(in:range,with:old)}
            view.undoManager?.setActionName(L10n.t("更改文字格式"))
            storage.beginEditing()
            old.enumerateAttributes(in:NSRange(location:0,length:old.length)){attributes,local,_ in
                storage.setAttributes(transform(attributes),range:NSRange(location:range.location+local.location,length:local.length))
            }
            storage.endEditing();view.didChangeText()
        }
        view.setSelectedRange(range);view.window?.makeFirstResponder(view)
    }
    func format(_ action:String) {
        guard let selection=selection(),let view=validView(selection) else{return}
        let attributes=selection.range.length>0 ? view.textStorage!.attributes(at:selection.range.location,effectiveRange:nil):view.typingAttributes
        let font=attributes[.font] as? NSFont ?? view.defaultFont
        let remove:Bool
        switch action {
        case "bold":remove=NSFontManager.shared.traits(of:font).contains(.boldFontMask)
        case "italic":remove=Self.isItalic(attributes)
        case "underline":remove=(attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0
        case "strikethrough":remove=(attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0
        case "clear":remove=false
        default:
            view.window?.makeFirstResponder(view)
            view.insertText(action=="list" ? "• " : action=="quote" ? "❝ " : "\n────────────\n",replacementRange:selection.range)
            return
        }
        style(selection){old in
            var attrs=old;let font=attrs[.font] as? NSFont ?? view.defaultFont;let manager=NSFontManager.shared
            switch action {
            case "bold":attrs[.font]=remove ? manager.convert(font,toNotHaveTrait:.boldFontMask):manager.convert(font,toHaveTrait:.boldFontMask)
            case "italic":
                let changed=remove ? manager.convert(font,toNotHaveTrait:.italicFontMask):manager.convert(font,toHaveTrait:.italicFontMask)
                attrs[.font]=changed
                attrs[.obliqueness]=(!remove && !manager.traits(of:changed).contains(.italicFontMask)) ? 0.2:nil
            case "underline":attrs[.underlineStyle]=remove ? nil:NSUnderlineStyle.single.rawValue
            case "strikethrough":attrs[.strikethroughStyle]=remove ? nil:NSUnderlineStyle.single.rawValue
            default:
                for key:NSAttributedString.Key in [.foregroundColor,.backgroundColor,.underlineStyle,.strikethroughStyle,.obliqueness,.strokeWidth,.baselineOffset,.kern] {attrs.removeValue(forKey:key)}
                attrs[.font]=view.defaultFont;attrs[.foregroundColor]=NSColor.labelColor
            }
            return attrs
        }
    }
    func color(_ color:NSColor?,background:Bool,selection:Selection? = nil) {
        style(selection){old in var attrs=old;attrs[background ? .backgroundColor:.foregroundColor]=color ?? (background ? nil:NSColor.labelColor);return attrs}
    }
    func font(family:String? = nil,size:CGFloat? = nil) {
        style{old in
            var attrs=old;let original=attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize:18)
            let base=NSFont(name:family ?? original.fontName,size:size ?? original.pointSize) ?? original
            let converted=NSFontManager.shared.convert(base,toHaveTrait:NSFontManager.shared.traits(of:original))
            let italic=Self.isItalic(attrs)
            attrs[.font]=converted;attrs[.obliqueness]=italic && !NSFontManager.shared.traits(of:converted).contains(.italicFontMask) ? 0.2:nil
            return attrs
        }
    }
    func beginLink() {
        guard var selection=selection(),let view=validView(selection),let storage=view.textStorage else{return}
        var address=""
        if selection.range.location<storage.length {
            var effective=NSRange()
            if let existing=storage.attribute(.link,at:selection.range.location,effectiveRange:&effective) {
                address=(existing as? URL)?.absoluteString ?? (existing as? String ?? "")
                if selection.range.length==0 {selection=Selection(document:selection.document,range:effective)}
            }
        }
        let title=(storage.string as NSString).substring(with:selection.range)
        guard !title.contains("\u{fffc}") else{NSSound.beep();return}
        linkDraft=LinkDraft(selection:selection,title:title,address:address)
    }
    @discardableResult
    func applyLink(_ draft:LinkDraft,remove:Bool = false) -> Bool {
        guard let view=validView(draft.selection) else{return false}
        if remove {style(draft.selection){old in var attrs=old;attrs.removeValue(forKey:.link);return attrs};return true}
        guard let url=Self.safeURL(draft.address) else{return false}
        let title=draft.title.isEmpty ? url.absoluteString:draft.title
        let range=draft.selection.range
        let existing=(view.string as NSString).substring(with:range)
        if range.length>0 && title==existing {style(draft.selection){old in var attrs=old;attrs[.link]=url;return attrs}}
        else {
            var attrs=range.length>0 ? view.textStorage!.attributes(at:range.location,effectiveRange:nil):view.typingAttributes
            attrs[.link]=url;view.window?.makeFirstResponder(view)
            view.insertText(NSAttributedString(string:title,attributes:attrs),replacementRange:range)
            view.typingAttributes.removeValue(forKey:.link)
        }
        return true
    }
    func choosePhotos() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.jpeg,.png,.heic]; panel.allowsMultipleSelection=true; panel.message=L10n.t("选择要插入日记的照片"); panel.prompt=L10n.t("插入")
        if panel.runModal() == .OK {textView?.importFiles(panel.urls)}
    }
    func insert(_ photos:[ImportedPhoto]) {
        guard let view=textView else {return}
        for photo in photos {
            let wrapper=FileWrapper(regularFileWithContents:photo.preview); wrapper.preferredFilename=photo.id.uuidString+".png";wrapper.filename=wrapper.preferredFilename
            let attachment=NSTextAttachment(fileWrapper:wrapper)
            let available=max(240,(view.textContainer?.containerSize.width ?? 640)-24)
            let width=min(available,photo.size.width,640); let height=width*photo.size.height/max(1,photo.size.width)
            let scale=min(1,440/max(1,height)); attachment.bounds=CGRect(x:0,y:0,width:width*scale,height:height*scale)
            attachment.fitImage(maxWidth:width*scale)
            view.insertText("\n",replacementRange:view.selectedRange())
            view.insertText(NSAttributedString(attachment:attachment),replacementRange:view.selectedRange())
            view.insertText("\n",replacementRange:view.selectedRange())
        }
    }
}

final class DiaryTextView:NSTextView {
    var documentID:UUID?
    var defaultFont=NSFont.systemFont(ofSize:18)
    var formatAction:((String)->Void)?
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)==[.command],window?.firstResponder===self,
           let key=event.charactersIgnoringModifiers?.lowercased(),let action=["b":"bold","i":"italic","u":"underline","k":"link"][key] {
            formatAction?(action);return true
        }
        return super.performKeyEquivalent(with:event)
    }

    override func setFrameSize(_ newSize:NSSize) {
        let changed=abs(newSize.width-frame.width)>0.5
        super.setFrameSize(newSize)
        if changed {fitAttachments()}
    }
    func fitAttachments() {
        guard let storage=textStorage,storage.length>0 else{return}
        let width=max(120,min(640,frame.width-2*textContainerInset.width-16))
        storage.enumerateAttribute(.attachment,in:NSRange(location:0,length:storage.length)) {value,_,_ in
            (value as? NSTextAttachment)?.fitImage(maxWidth:width)
        }
        layoutManager?.invalidateLayout(forCharacterRange:NSRange(location:0,length:storage.length),actualCharacterRange:nil)
    }
    var onFiles:(([URL])->Void)?
    var onImageData:((Data)->Void)?
    var onPreview:((NSImage)->Void)?
    func importFiles(_ urls:[URL]) {onFiles?(urls)}
    func restoreStyle(in range:NSRange,with old:NSAttributedString) {
        guard let storage=textStorage,NSMaxRange(range)<=storage.length else{return}
        let current=storage.attributedSubstring(from:range)
        undoManager?.registerUndo(withTarget:self) {target in target.restoreStyle(in:range,with:current)}
        storage.replaceCharacters(in:range,with:old);didChangeText()
    }
    override func paste(_ sender:Any?) {
        let board=NSPasteboard.general
        if let files=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!files.isEmpty {onFiles?(files); return}
        if let image=NSImage(pasteboard:board),let data=image.tiffRepresentation {onImageData?(data); return}
        super.paste(sender)
    }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        let board=sender.draggingPasteboard
        if let files=board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!files.isEmpty {onFiles?(files);return true}
        if let image=NSImage(pasteboard:board),let data=image.tiffRepresentation {onImageData?(data);return true}
        return super.performDragOperation(sender)
    }
    override func mouseDown(with event:NSEvent) {
        if event.clickCount==2,let manager=layoutManager,let container=textContainer {
            let point=convert(event.locationInWindow,from:nil)
            let location=manager.characterIndex(for:CGPoint(x:point.x-textContainerOrigin.x,y:point.y-textContainerOrigin.y),in:container,fractionOfDistanceBetweenInsertionPoints:nil)
            if location<(textStorage?.length ?? 0),let attachment=textStorage?.attribute(.attachment,at:location,effectiveRange:nil) as? NSTextAttachment,let image=attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)) {onPreview?(image);return}
        }
        super.mouseDown(with:event)
    }
}

struct RichEditor:NSViewRepresentable {
    let data:Data
    let refresh:UUID
    let preferences:DiaryPreferences
    let controller:EditorController
    let changed:(Data,String,[UUID])->Void
    let importFiles:([URL])->Void
    let importData:(Data)->Void
    let preview:(NSImage)->Void
    func makeCoordinator() -> Coordinator {Coordinator(self)}
    func makeNSView(context:Context) -> NSScrollView {
        makeScrollView(coordinator:context.coordinator)
    }
    func makeScrollView(coordinator:Coordinator) -> NSScrollView {
        let scroll=NSScrollView(); scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.drawsBackground=false
        let text=DiaryTextView(frame:.zero); text.minSize=NSSize(width:0,height:0); text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable=true; text.isHorizontallyResizable=false; text.autoresizingMask=[.width]
        text.textContainer?.containerSize=NSSize(width:640,height:CGFloat.greatestFiniteMagnitude); text.textContainer?.widthTracksTextView=true
        text.textContainerInset=NSSize(width:30,height:18)
        text.isRichText=true; text.importsGraphics=true; text.allowsUndo=true; text.isAutomaticQuoteSubstitutionEnabled=true; text.isAutomaticLinkDetectionEnabled=true
        text.isAutomaticSpellingCorrectionEnabled=false; text.isContinuousSpellCheckingEnabled=false; text.drawsBackground=false
        text.usesFindBar=true; text.isIncrementalSearchingEnabled=true; text.delegate=coordinator
        text.setAccessibilityLabel(L10n.t("日记正文")); text.registerForDraggedTypes([.fileURL,.png,.tiff,.rtf,.rtfd,.string])
        text.onFiles=importFiles; text.onImageData=importData; text.onPreview=preview
        text.formatAction={[weak controller] action in if action=="link" {controller?.beginLink()}else{controller?.format(action)}}
        text.setAccessibilityLabel(L10n.t("日记正文"))
        scroll.documentView=text; controller.textView=text
        coordinator.load(text,data:data,refresh:refresh,preferences:preferences)
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let text=scroll.documentView as? DiaryTextView else {return}
        context.coordinator.parent=self; controller.textView=text
        text.onFiles=importFiles; text.onImageData=importData; text.onPreview=preview
        text.formatAction={[weak controller] action in if action=="link" {controller?.beginLink()}else{controller?.format(action)}}
        text.setAccessibilityLabel(L10n.t("日记正文"))
        context.coordinator.load(text,data:data,refresh:refresh,preferences:preferences)
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:RichEditor
        var loaded:UUID?
        var lastPreferences:DiaryPreferences?
        var loading=false
        init(_ parent:RichEditor) {self.parent=parent}
        @MainActor func load(_ text:DiaryTextView,data:Data,refresh:UUID,preferences:DiaryPreferences) {
            let reloaded=loaded != refresh
            // The input method owns both the marked range and its temporary attributes until a candidate commits.
            guard reloaded || !text.hasMarkedText() else {return}
            loading=true; defer {loading=false}
            let typography=lastPreferences?.fontSize != preferences.fontSize || lastPreferences?.lineSpacing != preferences.lineSpacing || lastPreferences?.serif != preferences.serif
            if reloaded {
                let attributed=(try? NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtfd],documentAttributes:nil)) ?? NSAttributedString(string:"")
                text.textStorage?.setAttributedString(attributed); text.fitAttachments(); text.undoManager?.removeAllActions(); loaded=refresh; text.documentID=refresh
                text.setSelectedRange(NSRange(location:0,length:0))
            }
            if reloaded || typography || text.typingAttributes[.font]==nil {
                let font=NSFont(name:preferences.serif ? "Songti SC":"PingFang SC",size:preferences.fontSize) ?? NSFont.systemFont(ofSize:preferences.fontSize)
                let paragraph=NSMutableParagraphStyle(); paragraph.lineSpacing=preferences.lineSpacing; paragraph.paragraphSpacing=12
                text.defaultFont=font
                if reloaded {text.typingAttributes=[.font:font,.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph]}
                else {text.typingAttributes[.font]=font;text.typingAttributes[.paragraphStyle]=paragraph}
                if let storage=text.textStorage,storage.length>0 {
                    let original=NSAttributedString(attributedString:storage)
                    storage.beginEditing()
                    original.enumerateAttributes(in:NSRange(location:0,length:original.length)) {attributes,range,_ in
                        if attributes[.font]==nil || (typography && !reloaded) {
                            let old=attributes[.font] as? NSFont ?? font
                            let converted=NSFontManager.shared.convert(font,toHaveTrait:NSFontManager.shared.traits(of:old))
                            storage.addAttribute(.font,value:converted,range:range)
                            if EditorController.isItalic(attributes) && !NSFontManager.shared.traits(of:converted).contains(.italicFontMask) {storage.addAttribute(.obliqueness,value:0.2,range:range)}
                        }
                        if attributes[.foregroundColor]==nil {storage.addAttribute(.foregroundColor,value:NSColor.labelColor,range:range)}
                        if attributes[.paragraphStyle]==nil || (typography && !reloaded) {storage.addAttribute(.paragraphStyle,value:paragraph,range:range)}
                    }
                    storage.endEditing()
                    if typography && !reloaded {DispatchQueue.main.async {[weak self,weak text] in guard let self,let text,self.loaded==refresh else{return};self.textDidChange(Notification(name:NSText.didChangeNotification,object:text))}}
                }
            }

            lastPreferences=preferences
            text.insertionPointColor = .labelColor
        }
        func textView(_ textView:NSTextView,clickedOnLink link:Any,at charIndex:Int) -> Bool {
            let address=(link as? URL)?.absoluteString ?? (link as? String ?? "")
            if NSApp.currentEvent?.modifierFlags.contains(.command)==true,let url=EditorController.safeURL(address) {NSWorkspace.shared.open(url)}
            return true
        }
        func textDidChange(_ notification:Notification) {
            guard !loading,let text=notification.object as? NSTextView,!text.hasMarkedText(),let storage=text.textStorage else {return}
            do {
                let data=try storage.data(from:NSRange(location:0,length:storage.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
                var ids=[UUID]()
                storage.enumerateAttribute(.attachment,in:NSRange(location:0,length:storage.length)) {value,_,_ in
                    if let attachment=value as? NSTextAttachment,let name=attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename,let id=UUID(uuidString:String(name.prefix(36))) {ids.append(id)}
                }
                parent.changed(data,storage.string,Array(Set(ids)).sorted{$0.uuidString<$1.uuidString})
            } catch { /* The model keeps the previous durable version; serialization errors are surfaced below. */
                NotificationCenter.default.post(name:.editorSerializationFailed,object:nil)
            }
        }
    }
}
extension Notification.Name {static let editorSerializationFailed=Notification.Name("ShiguangEditorSerializationFailed")}
