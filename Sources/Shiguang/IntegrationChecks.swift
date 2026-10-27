#if DEBUG
import AppKit
import PDFKit
import DiaryCore

/// Runs only against an explicitly supplied disposable test directory.
@MainActor
enum IntegrationChecks {
    static func run(store:VaultStore,root:URL) async throws {
        let output=root.appendingPathComponent("export-checks")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let picture=NSImage(size:NSSize(width:1200,height:800))
        picture.lockFocus();NSColor.systemGreen.setFill();NSBezierPath(rect:NSRect(x:0,y:0,width:1200,height:800)).fill();picture.unlockFocus()
        let bytes=try ImageProcessing.sanitized(picture.tiffRepresentation!)
        let id=try await store.addAttachment(bytes)
        let wrapper=FileWrapper(regularFileWithContents:bytes);wrapper.preferredFilename=id.uuidString+".png";wrapper.filename=wrapper.preferredFilename
        let attachment=NSTextAttachment(fileWrapper:wrapper)
        let body=NSMutableAttributedString(string:"图文导出验证\n",attributes:[.font:NSFont.systemFont(ofSize:18)])
        body.append(NSAttributedString(attachment:attachment))
        for n in 1...180 {body.append(NSAttributedString(string:"\n第 \(n) 段：这是一篇中文长日记，用于检查分页和内容完整性。",attributes:[.font:NSFont.systemFont(ofSize:16)]))}
        body.append(NSAttributedString(string:"\nEND-OF-DIARY-97428",attributes:[.font:NSFont.systemFont(ofSize:16)]))
        var entry=DiaryEntry();entry.title="导出集成测试";entry.text=body.string;entry.attachmentIDs=[id]
        entry.richText=try body.data(from:NSRange(location:0,length:body.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtfd])
        try await store.save(entry)
        let reloaded=DiaryExporter.rich(entry)
        let text=DiaryTextView(frame:NSRect(x:0,y:0,width:499,height:300));text.isHorizontallyResizable=false;text.textContainer?.containerSize=NSSize(width:499,height:CGFloat.greatestFiniteMagnitude);text.textContainer?.widthTracksTextView=true;text.textStorage?.setAttributedString(reloaded);text.fitAttachments()
        var imageCount=0;var fitted=true
        text.textStorage?.enumerateAttribute(.attachment,in:NSRange(location:0,length:reloaded.length)) {value,_,_ in
            if let image=value as? NSTextAttachment {
                imageCount+=1
                let width=image.bounds.width;fitted = fitted && width<=499 && width>0
                fitted = fitted && image.fileWrapper?.preferredFilename==id.uuidString+".png"
            }
        }
        guard imageCount==1,fitted else {throw DiaryError.storage("RTFD image roundtrip failed: count=\(imageCount), fits=\(fitted)")}
        let pdf=output.appendingPathComponent("long-diary.pdf")
        try DiaryExporter.pdf(entry,to:pdf,location:false,mood:true)
        guard let document=PDFDocument(url:pdf),document.pageCount>1,document.string?.contains("END-OF-DIARY-97428")==true else {throw DiaryError.storage("Long PDF was truncated")}
        let markdown=output.appendingPathComponent("diary.md")
        try await DiaryExporter.markdown(entry,to:markdown,store:store,location:false,mood:true)
        let result=try String(contentsOf:markdown,encoding:.utf8)
        let images=try FileManager.default.contentsOfDirectory(at:output.appendingPathComponent("diary-images"),includingPropertiesForKeys:nil)
        guard result.contains("![照片]"),result.contains("END-OF-DIARY-97428"),images.count==1,NSImage(contentsOf:images[0]) != nil else {throw DiaryError.storage("Markdown image export failed")}
        print("PASS · RTFD image reload fits editor; Markdown + picture; complete PDF with \(document.pageCount) pages")
    }
}
#endif
