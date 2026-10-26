import AppKit
import CoreText

/// Koala Link's own screens (the starting card and the bank overlay) in the Paper look: Paper Cut's pen-and-paper
/// palette and Alicja Hand (copied from Paper Picker's PaperArtwork.swift).
enum PickerPaper {
    static let paper = NSColor(calibratedRed: 0.962, green: 0.948, blue: 0.918, alpha: 1)
    static let face = NSColor(calibratedRed: 0.982, green: 0.970, blue: 0.944, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.095, green: 0.151, blue: 0.214, alpha: 1)
    static let mutedInk = NSColor(calibratedRed: 0.330, green: 0.382, blue: 0.413, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.574, green: 0.240, blue: 0.229, alpha: 1)
    static let rule = NSColor(calibratedRed: 0.691, green: 0.749, blue: 0.752, alpha: 1)
    static let marker = NSColor(calibratedRed: 0.957, green: 0.824, blue: 0.620, alpha: 1)
    /// Koala's own pink, for the icon.
    static let koala = NSColor(srgbRed: 1, green: 0, blue: 0x99 / 255.0, alpha: 1)

    private static let registeredFonts: Void = {
        for style in ["Regular", "Bold"] {
            let filename = "AlicjaHand-\(style)"
            let url = Bundle.main.url(forResource: filename, withExtension: "otf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: filename, withExtension: "otf", subdirectory: "Fonts")
            if let url { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }()

    static func registerFonts() { _ = registeredFonts }

    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        registerFonts()
        let size = size * 1.2
        let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
        let fallback = bold ? "Noteworthy-Bold" : "Noteworthy-Light"
        guard let base = NSFont(name: bold ? "AlicjaHand-Bold" : "AlicjaHand-Regular", size: size) else {
            return NSFont(name: fallback, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        let cascade = [NSFontDescriptor(name: fallback, size: 0),
                       NSFontDescriptor(name: "Apple Symbols", size: 0),
                       NSFontDescriptor(name: "LucidaGrande", size: 0)]
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]), size: size) ?? base
    }

    private static let grain: NSColor = {
        let image = NSImage(size: NSSize(width: 256, height: 256))
        image.lockFocus()
        var seed: UInt64 = 0xE24B97D63A518C2F
        for _ in 0..<1500 {
            seed = seed &* 6364136223846793005 &+ 1
            let x = CGFloat((seed >> 24) & 255), y = CGFloat((seed >> 40) & 255)
            ink.withAlphaComponent(0.018).setFill()
            NSRect(x: x, y: y, width: 0.7, height: 0.7).fill()
        }
        image.unlockFocus()
        return NSColor(patternImage: image)
    }()

    static func background(_ rect: NSRect, spacing: CGFloat = 32) {
        paper.setFill(); rect.fill()
        grain.setFill(); rect.fill()
        let lines = NSBezierPath()
        lines.lineWidth = 0.65
        for x in stride(from: rect.minX, through: rect.maxX, by: spacing) {
            lines.move(to: NSPoint(x: x, y: rect.minY)); lines.line(to: NSPoint(x: x, y: rect.maxY))
        }
        for y in stride(from: rect.minY, through: rect.maxY, by: spacing) {
            lines.move(to: NSPoint(x: rect.minX, y: y)); lines.line(to: NSPoint(x: rect.maxX, y: y))
        }
        rule.withAlphaComponent(0.18).setStroke(); lines.stroke()
    }

    static func line(_ a: NSPoint, _ b: NSPoint, seed: Int, width: CGFloat = 1.6, color: NSColor = ink) {
        let path = NSBezierPath()
        path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: a)
        let dx = b.x - a.x, dy = b.y - a.y, length = max(1, hypot(dx, dy))
        let segments = max(2, Int(length / 13))
        for i in 1..<segments {
            let t = CGFloat(i) / CGFloat(segments)
            let wobble = sin(CGFloat(i * 17 + seed * 11)) * 0.65
            path.line(to: NSPoint(x: a.x + dx * t - dy / length * wobble,
                                  y: a.y + dy * t + dx / length * wobble))
        }
        path.line(to: b); color.setStroke(); path.stroke()
    }

    static func box(_ rect: NSRect, seed: Int, width: CGFloat = 1.6) {
        let a = NSPoint(x: rect.minX, y: rect.minY), b = NSPoint(x: rect.maxX, y: rect.minY)
        let c = NSPoint(x: rect.maxX, y: rect.maxY), d = NSPoint(x: rect.minX, y: rect.maxY)
        line(a, b, seed: seed, width: width); line(b, c, seed: seed + 1, width: width)
        line(c, d, seed: seed + 2, width: width); line(d, a, seed: seed + 3, width: width)
    }
}

final class PaperBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { PickerPaper.background(bounds) }
}

/// Koala Link's log: ~/Library/Logs/Koala Link.log.
enum PickerLog {
    private static let queue = DispatchQueue(label: "KoalaTouch.Log")
    static func write(_ message: String) {
        queue.async {
            let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("Koala Link.log")
            let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(message)\n".utf8)
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url); return }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf: data)
        }
    }
}

/// Command-line checks and artwork (offline: no MPC, no Koala, nothing posted).
enum KoalaTouchArtwork {
    static func handleCommandLine() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        do {
            switch args[1] {
            case "--render-push" where args.count == 3:
                try PushPreviewArtwork.write(to: URL(fileURLWithPath: args[2], isDirectory: true))
            case "--render-icon" where args.count == 3:
                try writeIconset(to: URL(fileURLWithPath: args[2], isDirectory: true))
            case "--render-controls" where args.count == 3:
                try KoalaTouchOverlay.writePreview(to: URL(fileURLWithPath: args[2]))
            case "--render-installer-art" where args.count == 3:
                try writeInstallerBackgrounds(to: URL(fileURLWithPath: args[2], isDirectory: true))
            case "--render-card" where args.count == 3:
                try writeCard(to: URL(fileURLWithPath: args[2]))
            case "--check-push-keyboard":
                try PushKeyboardChecks.run()
            case "--self-check":
                guard try KoalaMIDIProfile.offlineSelfCheck() else { throw CocoaError(.validationMissingMandatoryProperty) }
                print("PASS: 64 routed pads match Koala's profile; the profile backs up, keeps other settings, refuses a running Koala and runs once")
                guard KoalaPadMapper.offlineSelfCheck(), KoalaControlRouter.offlineSelfCheck(),
                      KoalaMIDIBridge.packetSelfCheck(), KoalaTouchOverlay.offlineSelfCheck() else { throw CocoaError(.validationMissingMandatoryProperty) }
                print("PASS: 64 pad assignments, duplicate note suppression, held release across a bank change")
                print("PASS: packed/split/running-status messages, long SysEx, separate Public/Private held selectors, Q-Link bank/contact capture")
                print("PASS: CoreMIDI variable-length 602-byte payload plus the following packet")
                print("PASS: measured overlay targets, move/down/up events and loop prevention; no events posted")
                guard try KoalaPushProfile.offlineSelfCheck() else { throw CocoaError(.validationMissingMandatoryProperty) }
                print("PASS: Koala's map gets the MPC's keys back after MIDI Learn, keeps anything else learned, never a key twice; Koala's MIDI settings set (built-in device maps off); both refuse a running Koala, back up, and have nothing to do the second time")
                try PushKeyboardChecks.run()
            default: return false
            }
            return true
        } catch {
            fputs("Koala Link: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    /// The starting card, as the MPC's screen shows it.
    private static func writeCard(to url: URL) throws {
        let view = KoalaTouchCard(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.status = "MPC touch ready · starting its controls…"
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    private static func writeIconset(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes = [("16x16",16), ("16x16@2x",32), ("32x32",32), ("32x32@2x",64),
                     ("128x128",128), ("128x128@2x",256), ("256x256",256), ("256x256@2x",512),
                     ("512x512",512), ("512x512@2x",1024)]
        for (name, pixels) in sizes {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
            drawIcon()
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(name).png"))
        }
    }

    /// The installer's window backgrounds (light and dark): graph paper with the icon in the corner, as Paper Cut's.
    private static func writeInstallerBackgrounds(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let size = NSSize(width: 640, height: 480)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let rect = NSRect(origin: .zero, size: size)
            if dark { NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1).setFill(); rect.fill() } else { PickerPaper.background(rect) }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: 18, yBy: 18); transform.scale(by: 132 / 1024); transform.concat()
            drawIcon()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: folder.appendingPathComponent(dark ? "background-dark.png" : "background.png"))
        }
    }

    /// A paper sheet with a 4×4 pad grid (Koala's pink pads) and a fingertip touching one.
    private static func drawIcon() {
        let sheet = NSBezierPath(roundedRect: NSRect(x: 108, y: 108, width: 808, height: 808), xRadius: 170, yRadius: 170)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -16); shadow.shadowBlurRadius = 25; shadow.set()
        PickerPaper.paper.setFill(); sheet.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState(); sheet.addClip()
        PickerPaper.background(NSRect(x: 108, y: 108, width: 808, height: 808), spacing: 64)
        let lit: Set<Int> = [0, 5, 6, 10, 15]
        for row in 0..<4 {
            for col in 0..<4 {
                let pad = NSRect(x: 214 + CGFloat(col) * 138, y: 214 + CGFloat(row) * 138, width: 110, height: 110)
                (lit.contains(row * 4 + col) ? PickerPaper.koala.withAlphaComponent(0.85) : PickerPaper.face).setFill(); pad.fill()
                PickerPaper.box(pad, seed: row * 4 + col, width: 9)
            }
        }
        // The fingertip, on the lit pad in row 2, column 3.
        let tip = NSBezierPath(ovalIn: NSRect(x: 497, y: 365, width: 130, height: 130))
        PickerPaper.marker.withAlphaComponent(0.9).setFill(); tip.fill()
        PickerPaper.ink.setStroke(); tip.lineWidth = 10; tip.stroke()
        NSGraphicsContext.restoreGraphicsState()
        PickerPaper.ink.withAlphaComponent(0.8).setStroke(); sheet.lineWidth = 6; sheet.stroke()
        let fold = NSBezierPath()
        fold.move(to: NSPoint(x: 742, y: 916)); fold.line(to: NSPoint(x: 916, y: 742))
        fold.line(to: NSPoint(x: 748, y: 744)); fold.close()
        PickerPaper.marker.setFill(); fold.fill(); PickerPaper.ink.setStroke(); fold.lineWidth = 7; fold.stroke()
    }
}

/// The card on the MPC's screen (and the Mac's) while Koala Link gets the MPC ready and opens Koala.
final class KoalaTouchCard: NSView {
    var status = "" { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        PickerPaper.background(bounds)
        let s = min(bounds.width / 1280, bounds.height / 800)
        func text(_ t: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (t as NSString).draw(in: NSRect(x: 40 * s, y: y * s, width: bounds.width - 80 * s, height: size * 1.8 * s),
                                 withAttributes: [.font: PickerPaper.font(size: size * s, weight: weight), .foregroundColor: color, .paragraphStyle: style])
        }
        text("KOALA LINK", y: 470, size: 64, weight: .bold, color: PickerPaper.ink)
        PickerPaper.line(NSPoint(x: bounds.midX - 190 * s, y: 462 * s), NSPoint(x: bounds.midX + 190 * s, y: 463 * s), seed: 3, width: 2.4 * s, color: PickerPaper.accent)
        text("Koala Sampler on the MPC Touch", y: 380, size: 24, weight: .regular, color: PickerPaper.mutedInk)
        text(status, y: 250, size: 20, weight: .regular, color: PickerPaper.mutedInk)
    }
}
