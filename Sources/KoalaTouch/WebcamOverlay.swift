import AppKit
import CoreImage
import CoreText

/// The webcam's card: the pad being played (lit while held, flashing on the hit), its name and its sample's waveform
/// with a playhead from the hit, the Perform effects that are on, and how loud the sound is. Drawn each picture with
/// Core Graphics at card size (small), on the studio's queue; the pad's name and waveform load on a queue of their own.
final class WebcamOverlayPainter {
    private struct PadInfo { var hit: KoalaPerformanceFeed.Hit, name: String, wave: KoalaWave?, slice: Int? }
    private let lock = NSLock()
    private var info: PadInfo?
    private var tempo = 120.0
    private var requested: Double = -1
    private let loader = DispatchQueue(label: "Koala Link webcam pads", qos: .utility)
    private var session: KoalaSession?, sessionRead = -10.0
    private var audio: [KoalaAudioSignature: KoalaWaveformAudio] = [:]
    private var token: KoalaWaveformReadToken?

    /// The song's tempo (Koala's session files), for the effects' 1/16 grid.
    var bpm: Double { lock.lock(); defer { lock.unlock() }; return tempo }

    func picture(feed: KoalaPerformanceFeed.Snapshot, level: Float, now: Double, vertical: Bool, frameSize: CGSize) -> CIImage? {
        if let hit = feed.lastHit, hit.time != requested { requested = hit.time; load(hit) }
        lock.lock(); let pad = info; lock.unlock()
        let margin = (frameSize.width * 0.025).rounded()
        let size = vertical ? CGSize(width: frameSize.width - 2 * margin, height: 250) : CGSize(width: 680, height: 200)
        guard let image = draw(size: size, feed: feed, pad: pad, level: level, now: now) else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: margin, y: margin))
    }

    // MARK: Pad name and waveform
    private func load(_ hit: KoalaPerformanceFeed.Hit) {
        token?.cancel()
        let token = KoalaWaveformReadToken(); self.token = token
        loader.async { [weak self] in
            guard let self else { return }
            let now = KoalaPerformanceFeed.now()
            if now - self.sessionRead > 1 { self.session = KoalaSession.readSaved() ?? self.session; self.sessionRead = now }
            let session = self.session ?? KoalaSession()
            // A chop or a keyboard note plays the selected pad.
            let index = hit.chop || hit.keys ? session.selectedPad : hit.pad
            let pad = index.flatMap { session.pads[$0] }
            var wave: KoalaWave?
            if let pad, let id = pad.sampleID, let signature = KoalaAudioSignature(url: KoalaSession.folder.appendingPathComponent("sampler/\(id).wav")) {
                if self.audio[signature] == nil, let read = KoalaWaveformReader.read(signature, token: token) {
                    if self.audio.count > 24 { self.audio.removeAll() }
                    self.audio[signature] = read
                }
                wave = self.audio[signature]?.wave(for: pad)
            }
            guard !token.cancelled else { return }
            let name = pad?.label.isEmpty == false ? pad!.label : (pad?.loaded == true ? "Sample" : "Empty pad")
            self.lock.lock()
            self.info = PadInfo(hit: hit, name: name, wave: wave, slice: hit.chop ? hit.pad : nil)
            if let bpm = session.bpm, bpm > 20 { self.tempo = bpm }
            self.lock.unlock()
        }
    }

    // MARK: Drawing
    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private static func title(_ hit: KoalaPerformanceFeed.Hit) -> (big: String, kind: String) {
        if hit.keys { return (noteNames[hit.note % 12] + String(hit.note / 12 - 2), "KEY") }
        if hit.chop { return ("\(hit.pad + 1)", "CHOP") }
        return (["A", "B", "C", "D"][hit.pad / 16] + "\(hit.pad % 16 + 1)", "PAD")
    }

    private func draw(size: CGSize, feed: KoalaPerformanceFeed.Snapshot, pad: PadInfo?, level: Float, now: Double) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: FrameRenderer.colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let u = size.height / 200, inset = 18 * u
        cg.setFillColor(KoalaLook.background.withAlphaComponent(0.86).cgColor)
        cg.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 22 * u, cornerHeight: 22 * u, transform: nil)); cg.fillPath()

        // The pad: pink on the hit and while held, fading back to blue.
        let badge = CGRect(x: inset, y: inset, width: size.height - 2 * inset, height: size.height - 2 * inset)
        let hit = feed.lastHit
        let held = hit.map { feed.held[$0.note] != nil } ?? false
        let flash = held ? 1 : hit.map { max(0, 1 - (now - $0.time) / 0.35) } ?? 0
        cg.setFillColor(Self.mix(KoalaLook.blue.withAlphaComponent(0.35), KoalaLook.pink, CGFloat(flash)))
        cg.addPath(CGPath(roundedRect: badge, cornerWidth: 16 * u, cornerHeight: 16 * u, transform: nil)); cg.fillPath()
        let title: (big: String, kind: String) = hit.map(Self.title) ?? ("–", "PLAY A PAD")
        text(cg, title.big, size: 64 * u, color: KoalaLook.foreground, center: CGPoint(x: badge.midX, y: badge.midY + 10 * u))
        text(cg, title.kind, size: 18 * u, color: KoalaLook.foreground.withAlphaComponent(0.8), center: CGPoint(x: badge.midX, y: badge.minY + 22 * u))

        // Name, waveform, effects, level.
        let left = badge.maxX + inset, right = size.width - inset
        let current = pad.flatMap { p in hit.map { p.hit.time == $0.time } ?? false ? p : nil }
        text(cg, current?.name ?? (hit == nil ? "Koala Link" : " "), size: 26 * u, color: KoalaLook.foreground,
             origin: CGPoint(x: left, y: size.height - inset - 26 * u), maxWidth: right - left)
        let waveBox = CGRect(x: left, y: inset + 42 * u, width: right - left, height: size.height - 2 * inset - 42 * u - 36 * u)
        if let wave = current?.wave { waveform(cg, wave, in: waveBox, slice: current?.slice, hit: current?.hit, now: now) }
        else {
            cg.setFillColor(KoalaLook.blue.withAlphaComponent(0.25).cgColor)
            cg.fill(CGRect(x: waveBox.minX, y: waveBox.midY - u, width: waveBox.width, height: 2 * u))
        }
        var x = left
        for name in KoalaPushProfile.fxNames where feed.fx[name] != nil || (name == "STUTTER" && feed.manualStutter) {
            let width = chip(cg, name, at: CGPoint(x: x, y: inset + 12 * u), u: u)
            x += width + 8 * u
            if x > right - 60 * u { break }
        }
        cg.setFillColor(KoalaLook.foreground.withAlphaComponent(0.12).cgColor)
        cg.fill(CGRect(x: left, y: inset, width: right - left, height: 5 * u))
        cg.setFillColor(KoalaLook.blue.cgColor)
        cg.fill(CGRect(x: left, y: inset, width: (right - left) * CGFloat(min(1, level)), height: 5 * u))
        return cg.makeImage()
    }

    private func waveform(_ cg: CGContext, _ wave: KoalaWave, in r: CGRect, slice: Int?, hit: KoalaPerformanceFeed.Hit?, now: Double) {
        guard !wave.peaks.isEmpty else { return }
        let columns = max(1, Int(r.width / 3))
        // The chop being played, or the pad's trimmed region, is bright; the rest dim.
        var bright = wave.start...max(wave.start, wave.end)
        if let slice, !wave.slices.isEmpty {
            let edges = [wave.start] + wave.slices.filter { $0 > wave.start && $0 < wave.end } + [wave.end]
            let i = slice % max(1, edges.count - 1)
            if i + 1 < edges.count { bright = edges[i]...edges[i + 1] }
        }
        for c in 0..<columns {
            let at = Double(c) / Double(columns)
            let peak = CGFloat(wave.peaks[min(wave.peaks.count - 1, Int(at * Double(wave.peaks.count)))])
            let height = max(2, peak * r.height)
            cg.setFillColor((bright.contains(at) ? KoalaLook.blue : KoalaLook.blue.withAlphaComponent(0.3)).cgColor)
            cg.fill(CGRect(x: r.minX + CGFloat(c) * r.width / CGFloat(columns), y: r.midY - height / 2, width: max(1, r.width / CGFloat(columns) - 1), height: height))
        }
        // The playhead runs from the hit through the bright part at the sample's own speed.
        if let hit, wave.duration > 0 {
            let position = bright.lowerBound + (now - hit.time) / wave.duration
            if position <= bright.upperBound {
                cg.setFillColor(KoalaLook.pink.cgColor)
                cg.fill(CGRect(x: r.minX + CGFloat(position) * r.width - 1.5, y: r.minY, width: 3, height: r.height))
            }
        }
    }

    private func chip(_ cg: CGContext, _ name: String, at p: CGPoint, u: CGFloat) -> CGFloat {
        let line = Self.line(name, size: 16 * u, color: KoalaLook.foreground)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) + 20 * u
        cg.setFillColor(KoalaLook.pink.cgColor)
        cg.addPath(CGPath(roundedRect: CGRect(x: p.x, y: p.y, width: width, height: 26 * u), cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil)); cg.fillPath()
        cg.textPosition = CGPoint(x: p.x + 10 * u, y: p.y + 7 * u); CTLineDraw(line, cg)
        return width
    }
    private static func line(_ string: String, size: CGFloat, color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: KoalaLook.font(size), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]))
    }
    private func text(_ cg: CGContext, _ string: String, size: CGFloat, color: NSColor, center: CGPoint) {
        let line = Self.line(string, size: size, color: color)
        let bounds = CTLineGetImageBounds(line, cg)
        cg.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY); CTLineDraw(line, cg)
    }
    private func text(_ cg: CGContext, _ string: String, size: CGFloat, color: NSColor, origin: CGPoint, maxWidth: CGFloat) {
        var line = Self.line(string, size: size, color: color)
        if CTLineGetTypographicBounds(line, nil, nil, nil) > maxWidth, let truncated = CTLineCreateTruncatedLine(line, maxWidth, .end, Self.line("…", size: size, color: color)) { line = truncated }
        cg.textPosition = origin; CTLineDraw(line, cg)
    }
    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> CGColor {
        let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
        return CGColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t, green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}
