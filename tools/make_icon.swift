// Renders the knitted app icons (from tools/icons/gen_knit_grid.py) into the asset catalog:
//   python3 -I tools/icons/gen_knit_grid.py build/icons && swift tools/make_icon.swift build/icons
//
// - AppIcon.appiconset            primary icon (PRIMARY below), light/dark/tinted
// - Icon-<key>-<detail>.appiconset  every other icon, as an alternate icon (light/dark/tinted)
// - IconPreview-<key>-<detail>.imageset  small light/dark preview for the picker in Settings
// All PNGs are opaque (App Store rejects alpha in the primary icon).
import AppKit

let PRIMARY = "Icon-yesil-ayrintili"

let args = CommandLine.arguments.dropFirst()
let src = URL(fileURLWithPath: args.first ?? "build/icons")
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let catalog = root.appendingPathComponent("../Ilmek/Assets.xcassets").standardizedFileURL
let fm = FileManager.default

func png(_ svg: URL, size: Int) -> Data {
    guard let img = NSImage(contentsOf: svg) else { fatalError("load \(svg.path)") }
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func write(_ dir: URL, _ json: String) throws {
    try? fm.removeItem(at: dir)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try json.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

func appIconSet(_ dir: URL, from name: String, looks: [String] = ["light", "dark", "tinted"]) throws {
    if looks == ["light"] {
        try write(dir, """
        { "images" : [ { "filename" : "light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
          "info" : { "author" : "xcode", "version" : 1 } }
        """)
    } else {
    try write(dir, """
    {
      "images" : [
        { "filename" : "light.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "filename" : "dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ],
          "filename" : "tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """)
    }
    for look in looks {
        try png(src.appendingPathComponent("\(name)-\(look).svg"), size: 1024)
            .write(to: dir.appendingPathComponent("\(look).png"))
    }
}

// Old generated sets go first, so a removed colour does not linger in the catalog.
for item in try fm.contentsOfDirectory(atPath: catalog.path)
where item.hasPrefix("Icon-") || item.hasPrefix("IconPreview-") || item == "AppIcon.appiconset" {
    try fm.removeItem(at: catalog.appendingPathComponent(item))
}

let names = Set(try fm.contentsOfDirectory(atPath: src.path)
    .filter { $0.hasSuffix("-light.svg") }
    .map { String($0.dropLast("-light.svg".count)) }).sorted()

try appIconSet(catalog.appendingPathComponent("AppIcon.appiconset"), from: PRIMARY)
for name in names {
    if name != PRIMARY {  // the primary is AppIcon; the app clears the alternate to show it
        try appIconSet(catalog.appendingPathComponent("\(name).appiconset"), from: name)
    }
    let preview = catalog.appendingPathComponent("IconPreview-\(name.dropFirst("Icon-".count)).imageset")
    try write(preview, """
    { "images" : [
        { "filename" : "preview.png", "idiom" : "universal" },
        { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "filename" : "preview-dark.png", "idiom" : "universal" } ],
      "info" : { "author" : "xcode", "version" : 1 } }
    """)
    try png(src.appendingPathComponent("\(name)-light.svg"), size: 240)
        .write(to: preview.appendingPathComponent("preview.png"))
    try png(src.appendingPathComponent("\(name)-dark.svg"), size: 240)
        .write(to: preview.appendingPathComponent("preview-dark.png"))
    print("wrote \(name)")
}
