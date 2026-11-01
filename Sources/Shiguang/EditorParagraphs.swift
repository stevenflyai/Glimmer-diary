import AppKit
import DiaryCore

extension DiaryTextView {
    private struct Paragraph {
        let range:NSRange
        let content:NSRange
        let prefix:String
        // AppKit's legacy RTF encoding can round-trip Songti bullets as a middle dot.
        var kind:String {prefix=="· " ? "• ":prefix}
    }

    private func paragraphs(in selection:NSRange) -> [Paragraph] {
        let source=string as NSString
        guard selection.location != NSNotFound,NSMaxRange(selection)<=source.length else{return []}
        // A selection ending at the next paragraph's start must not format that paragraph.
        let last=selection.length>0 ? NSMaxRange(selection)-1:selection.location
        var position=selection.location,result=[Paragraph]()
        repeat {
            var start=0,end=0,contentsEnd=0
            source.getParagraphStart(&start,end:&end,contentsEnd:&contentsEnd,for:NSRange(location:position,length:0))
            let content=NSRange(location:start,length:contentsEnd-start)
            let line=source.substring(with:content)
            let prefix=["• ","· ","❝ "].first(where:{line.hasPrefix($0)}) ?? ""
            result.append(Paragraph(range:NSRange(location:start,length:end-start),content:content,prefix:prefix))
            if end<=position {break}
            position=end
        } while position<=last
        return result
    }

    private func insertionAttributes(at position:Int) -> [NSAttributedString.Key:Any] {
        var attributes=position<(textStorage?.length ?? 0) ? textStorage!.attributes(at:position,effectiveRange:nil):typingAttributes
        attributes.removeValue(forKey:.attachment)
        attributes.removeValue(forKey:.link)
        return attributes
    }

    /// One structural edit, with exact attributed content, selection and typing state restored by undo.
    private func replaceParagraphText(in range:NSRange,with replacement:NSAttributedString,selection:NSRange,typing:[NSAttributedString.Key:Any]? = nil) {
        guard !hasMarkedText(),let storage=textStorage,NSMaxRange(range)<=storage.length else{return}
        let old=storage.attributedSubstring(from:range),oldSelection=selectedRange(),oldTyping=typingAttributes
        let inverseRange=NSRange(location:range.location,length:replacement.length)
        breakUndoCoalescing()
        let undo=undoManager
        // shouldChangeText also registers a native undo. Suppress it while recording our
        // selection-aware edit, otherwise undo applies the length-changing replacement twice.
        undo?.disableUndoRegistration()
        let accepted=shouldChangeText(in:range,replacementString:replacement.string)
        if accepted {
            storage.replaceCharacters(in:range,with:replacement)
            setSelectedRange(selection)
            if let typing {typingAttributes=typing}
            didChangeText()
        }
        undo?.enableUndoRegistration()
        guard accepted else{return}
        undo?.registerUndo(withTarget:self) {target in
            target.replaceParagraphText(in:inverseRange,with:old,selection:oldSelection,typing:oldTyping)
        }
        undo?.setActionName(L10n.t("更改文字格式"))
        window?.makeFirstResponder(self)
        scrollRangeToVisible(selection)
    }

    func toggleParagraphPrefix(_ prefix:String) {
        guard !hasMarkedText(),let storage=textStorage else{return}
        let selection=selectedRange(),lines=paragraphs(in:selectedRange())
        guard let first=lines.first,let last=lines.last else{return}
        let remove=lines.allSatisfy{$0.kind==prefix}
        let range=NSRange(location:first.range.location,length:NSMaxRange(last.range)-first.range.location)
        let replacement=NSMutableAttributedString(attributedString:storage.attributedSubstring(from:range))
        let edits=lines.map {line in (NSRange(location:line.range.location,length:(line.prefix as NSString).length),remove ? "":prefix)}
        for (edit,value) in edits.reversed() {
            replacement.replaceCharacters(in:NSRange(location:edit.location-range.location,length:edit.length),with:NSAttributedString(string:value,attributes:insertionAttributes(at:edit.location)))
        }
        func mapped(_ position:Int) -> Int {
            var shift=0
            for (edit,value) in edits {
                if position<edit.location {break}
                let count=(value as NSString).length
                if position<=NSMaxRange(edit) {return edit.location+shift+count}
                shift += count-edit.length
            }
            return position+shift
        }
        let start=mapped(selection.location),end=mapped(NSMaxRange(selection))
        replaceParagraphText(in:range,with:replacement,selection:NSRange(location:start,length:end-start))
    }

    func insertParagraphSeparator() {
        guard !hasMarkedText(),let line=paragraphs(in:selectedRange()).last else{return}
        let position=NSMaxRange(line.range)
        let needsNewline=line.content.length>0 && NSMaxRange(line.content)==position
        let value=(needsNewline ? "\n":"")+"────────────\n"
        let attributes=insertionAttributes(at:position)
        replaceParagraphText(in:NSRange(location:position,length:0),with:NSAttributedString(string:value,attributes:attributes),selection:NSRange(location:position+(value as NSString).length,length:0),typing:attributes)
    }

    /// Literal prefixes also keep previously saved diaries and exported plain text compatible.
    func continueParagraph() -> Bool {
        let selection=selectedRange()
        guard !hasMarkedText(),let line=paragraphs(in:selection).first,!line.prefix.isEmpty,
              selection.location>=line.content.location+(line.prefix as NSString).length,
              NSMaxRange(selection)<=NSMaxRange(line.content) else{return false}
        let body=NSRange(location:line.content.location+(line.prefix as NSString).length,length:line.content.length-(line.prefix as NSString).length)
        let attributes=insertionAttributes(at:selection.location)
        if (string as NSString).substring(with:body).trimmingCharacters(in:.whitespaces).isEmpty {
            replaceParagraphText(in:line.content,with:NSAttributedString(string:""),selection:NSRange(location:line.content.location,length:0),typing:attributes)
        } else {
            let value="\n"+line.prefix
            replaceParagraphText(in:selection,with:NSAttributedString(string:value,attributes:attributes),selection:NSRange(location:selection.location+(value as NSString).length,length:0),typing:attributes)
        }
        return true
    }

    func removeParagraphPrefixAtCaret() -> Bool {
        let selection=selectedRange()
        guard !hasMarkedText(),selection.length==0,let line=paragraphs(in:selection).first,!line.prefix.isEmpty,
              selection.location==line.range.location+(line.prefix as NSString).length else{return false}
        replaceParagraphText(in:NSRange(location:line.range.location,length:(line.prefix as NSString).length),with:NSAttributedString(string:""),selection:NSRange(location:line.range.location,length:0))
        return true
    }
}
