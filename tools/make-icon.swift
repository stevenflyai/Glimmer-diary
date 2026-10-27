import AppKit
let output=URL(fileURLWithPath:CommandLine.arguments[1])
let image=NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
NSColor(srgbRed:0.929,green:0.914,blue:0.875,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:42,y:42,width:940,height:940),xRadius:210,yRadius:210).fill()
NSColor(srgbRed:0.20,green:0.35,blue:0.27,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:248,y:174,width:548,height:690),xRadius:48,yRadius:48).fill()
NSColor(srgbRed:0.15,green:0.29,blue:0.21,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:248,y:174,width:67,height:690),xRadius:20,yRadius:20).fill()
NSColor(srgbRed:0.91,green:0.89,blue:0.82,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:301,y:199,width:465,height:58),xRadius:15,yRadius:15).fill()
let attributes:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Songti SC",size:250) ?? NSFont.systemFont(ofSize:250),.foregroundColor:NSColor(srgbRed:0.96,green:0.95,blue:0.9,alpha:1)]
("拾" as NSString).draw(at:NSPoint(x:392,y:370),withAttributes:attributes)
NSColor(srgbRed:0.72,green:0.61,blue:0.40,alpha:1).setFill()
let ribbon=NSBezierPath();ribbon.move(to:NSPoint(x:672,y:864));ribbon.line(to:NSPoint(x:726,y:864));ribbon.line(to:NSPoint(x:726,y:715));ribbon.line(to:NSPoint(x:699,y:735));ribbon.line(to:NSPoint(x:672,y:715));ribbon.close();ribbon.fill()
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:output)
