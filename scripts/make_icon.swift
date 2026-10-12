import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.40, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 140, y: 140, width: 744, height: 744)).fill()
let text: NSString = "¥"
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 520, weight: .semibold), .foregroundColor: NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.40, alpha: 1)]
let measured = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024 - measured.width)/2, y: (1024 - measured.height)/2), withAttributes: attributes)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "PersonalKakeibo/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
