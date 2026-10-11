import AppKit

/// Synthetic artwork only: no MIDI endpoints, controller USB, song reads or
/// settings changes. Uses the same renderer as the physical Push display.
enum PushPreviewArtwork {
    static func write(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var session = KoalaSession()
        session.name = "Koala Link demo"; session.selectedPad = 0; session.bpm = 96
        session.bars = Array(repeating: 2, count: 32)
        session.notes = Array(repeating: [], count: 32)
        session.scale = "CHROMATIC"
        for i in 0..<64 {
            var pad = KoalaSession.Pad()
            pad.loaded = i % 5 != 4; pad.label = ["DRUM BREAK", "KICK", "SNARE", "HAT", "", "BASS", "KEYS", "TEXTURE"][i % 8]
            pad.frames = 176400; pad.end = 176400; pad.pitch = 0
            session.pads[i] = pad
        }
        session.notes[0] = (0..<32).map { i in
            KoalaSession.Note(pad: [0, 1, 2, 3, 5, 6][i % 6], beat: Double(i) * 0.25, length: 0.18, velocity: 105)
        }
        let controller = KoalaController { _ in }
        controller.setSession(session)
        var artworkTime = 100.0; controller.now = { artworkTime }
        let peaks = (0..<960).map { i -> Float in
            let t = Double(i) / 960
            let decay = exp(-Double(i % 120) / 31)
            return Float(min(1, 0.08 + decay * abs(sin(t * 273)) * 0.85))
        }
        controller.wave = KoalaWave(peaks: peaks, slices: [], start: 0, end: 1, duration: 4)
        var views: [(String, KoalaView)] = [("01-sample", controller.view())]
        var chopper = session.pads[0]!
        chopper.chopper = true; chopper.slices = (0..<128).map { Double($0) / 128 * 176400 }
        session.pads[0] = chopper; session.keyboard = true
        controller.setSession(session)
        controller.wave?.slices = (0..<128).map { Double($0) / 128 }
        views.append(("02-chopper-128", controller.view()))
        controller.handle(.button(Push2Button.pageRight, down: true))
        controller.handle(.button(Push2Button.pageRight, down: false))
        views.append(("03-chopper-page-two", controller.view()))
        session.keyboard = false; controller.setSession(session)
        controller.show(.fx)
        controller.handle(.button(Push2Button.lowerRow.lowerBound + 4, down: true))
        controller.handle(.button(Push2Button.lowerRow.lowerBound + 4, down: false))
        views.append(("04-perform", controller.view()))
        artworkTime += 5; controller.show(.seq); views.append(("05-sequence", controller.view()))
        controller.show(.eq); views.append(("06-eq", controller.view()))
        controller.show(.mixer); views.append(("07-mixer", controller.view()))
        let choice = ControllerChoiceWindow()
        if let content = choice.window?.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: folder.appendingPathComponent("Koala-Link-Controller-Choice.png"), options: .atomic)
            }
        }
        let canvas = KoalaPushCanvas()
        for (name, view) in views {
            guard let data = canvas.png({ KoalaScreenArt.draw(view, in: $0) }) else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        }
        let overview = NSImage(size: NSSize(width: 960, height: 160 * views.count))
        overview.lockFocus()
        for (i, entry) in views.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: 0, yBy: CGFloat((views.count - i - 1) * 160)); transform.concat()
            KoalaScreenArt.draw(entry.1, in: NSRect(x: 0, y: 0, width: 960, height: 160))
            NSGraphicsContext.restoreGraphicsState()
        }
        overview.unlockFocus()
        guard let tiff = overview.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: folder.appendingPathComponent("Koala-Link-Push-Screens.png"), options: .atomic)
        print("Rendered Push display artwork in \(folder.path)")
    }
}
