import AppKit
import CoreText
import Foundation

/// Palette matched to the observed native Koala screen, 2026-10-11.
/// Installed .koalaskin files contain several alternate palettes but no setting
/// identifies which one is active, so they are not used as a source here.
enum KoalaLook {
    static let pink = color(hex: 0xFF2863)
    static let blue = color(hex: 0x00CBEA)
    static let grey = color(hex: 0x6B6262)
    static let muted = color(hex: 0xFFFFFF, alpha: 0.55)
    static let background = color(hex: 0x2D2727)
    static let foreground = color(hex: 0xFFFFFF)

    // The screen observation establishes the two accents, not bank-specific
    // colors. Keep all four bank markers on Koala's observed cyan accent.
    static let banks: [NSColor] = [blue, blue, blue, blue]

    static func bankRGB(_ bank: Int) -> (UInt8, UInt8, UInt8) {
        let value = banks[((bank % banks.count) + banks.count) % banks.count]
            .usingColorSpace(.sRGB) ?? blue
        return (UInt8((value.redComponent * 255).rounded()),
                UInt8((value.greenComponent * 255).rounded()),
                UInt8((value.blueComponent * 255).rounded()))
    }

    static func font(_ size: CGFloat) -> NSFont {
        if fontRegistered {
            if let dosis = NSFont(name: "Dosis-Medium", size: size) { return dosis }
        }
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
    private static let fontRegistered: Bool = {
        guard let url = koalaFontURL else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) || NSFont(name: "Dosis-Medium", size: 12) != nil
    }()

    private static let koalaFontURL: URL? = {
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.elf-audio.koala-mac")
            ?? URL(fileURLWithPath: "/Applications/koala.app")
        let url = app.appendingPathComponent("Contents/Resources/data/font/Dosis-Medium.ttf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    private static func color(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: alpha)
    }
}
