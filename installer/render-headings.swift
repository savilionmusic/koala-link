// macOS Installer's NSAttributedString HTML importer ignores @font-face.
// Render its four headings using the actual approved OTF, at 3x resolution.
// Text remains available as each HTML image's alt label. No system installation.
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { fatalError("Usage: headings <font-folder> <output-folder> [package-html-folder]") }
let fonts = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let url = fonts.appendingPathComponent("AlicjaHand-Bold.otf")
guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) else { fatalError("Cannot register Alicja Hand Bold") }
let headings: [(String, String, CGFloat)] = [
    ("welcome", "Koala Link", 26),
    ("readme-how", "How it works", 18),
    ("readme-requirements", "Requirements", 18),
    ("conclusion", "Koala Link is installed", 24)
]
for (name, value, size) in headings {
    let font = NSFont(name: "AlicjaHand-Bold", size: size * 1.2)!
    let ink = NSColor(calibratedRed: 0.095, green: 0.151, blue: 0.214, alpha: 1)
    let string = NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: ink])
    let width = ceil(string.size().width + 2), height = ceil(string.size().height)
    let pixels: CGFloat = 3
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * pixels), pixelsHigh: Int(height * pixels),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: pixels); transform.concat()
    // Installer adapts text to dark mode but does not adapt image pixels. A
    // paper backing keeps the exact font visible in both light and dark modes.
    NSColor(calibratedRed: 0.976, green: 0.963, blue: 0.938, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    string.draw(at: NSPoint(x: 1, y: 0))
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = NSSize(width: width, height: height)
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent("\(name).png"))
    if args.count == 4 {
        // The native importer also rejects package-relative image URLs. Inline
        // the PNG into the package HTML so it remains completely self-contained.
        let filename = name.hasPrefix("readme-") ? "readme" : name
        let htmlURL = URL(fileURLWithPath: args[3]).appendingPathComponent("\(filename).html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let pattern = "src=\"headings/\(name).png\" width=\"[0-9]+\" height=\"[0-9]+\""
        let sized = html.replacingOccurrences(of: pattern,
            with: "src=\"headings/\(name).png\" width=\"\(Int(width))\" height=\"\(Int(height))\"", options: .regularExpression)
        let embedded = sized.replacingOccurrences(of: "src=\"headings/\(name).png\"",
            with: "src=\"data:image/png;base64,\(png.base64EncodedString())\"")
        try embedded.write(to: htmlURL, atomically: true, encoding: .utf8)
    }
    print("\(name): \(Int(width)) x \(Int(height)) CSS pixels")
}
if args.count == 4 {
    for name in ["welcome", "readme", "conclusion"] {
        let folder = URL(fileURLWithPath: args[3])
        let rich = try NSAttributedString(url: folder.appendingPathComponent("\(name).html"),
            options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        // Flat RTFD preserves the font artwork as real native text attachments.
        // Installer strips image attachments from its HTML import path.
        let data = try rich.data(from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        try data.write(to: folder.appendingPathComponent("\(name).rtfd"))
    }
}
