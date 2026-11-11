// Renders tools/icons/*.svg into a contact sheet (large + home-screen sizes with iOS mask).
//   swift tools/render_icons.swift [out.png] [svg ...]
import AppKit

let args = CommandLine.arguments.dropFirst()
let out = URL(fileURLWithPath: args.first ?? "sheet.png")
let files = args.dropFirst().map { URL(fileURLWithPath: $0) }

let big: CGFloat = 420, small: CGFloat = 120, tiny: CGFloat = 60, pad: CGFloat = 40
let colW = big + pad
let W = pad + CGFloat(files.count) * colW
let H = pad + big + pad + small + pad + 40

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

func draw(_ img: NSImage, _ r: NSRect) {
    let path = NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    img.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
}

for (i, f) in files.enumerated() {
    guard let img = NSImage(contentsOf: f) else { print("cannot load \(f.path)"); continue }
    let x = pad + CGFloat(i) * colW
    draw(img, NSRect(x: x, y: H - pad - big, width: big, height: big))
    draw(img, NSRect(x: x, y: H - pad - big - pad - small, width: small, height: small))
    // dark wallpaper chip
    NSColor(white: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x + small + 30, y: H - pad - big - pad - small, width: small + 40, height: small),
                 xRadius: 16, yRadius: 16).fill()
    draw(img, NSRect(x: x + small + 50, y: H - pad - big - pad - small + 30, width: tiny, height: tiny))
    let label = f.deletingPathExtension().lastPathComponent as NSString
    label.draw(at: NSPoint(x: x, y: 14), withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold)])
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
