import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.09, green: 0.13, blue: 0.10, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 565, weight: .bold), .foregroundColor: NSColor(calibratedRed: 0.68, green: 0.86, blue: 0.70, alpha: 1)]
let text = NSAttributedString(string: "M", attributes: attributes)
let size = text.size()
text.draw(at: NSPoint(x: (1024-size.width)/2, y: (1024-size.height)/2 + 16))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
