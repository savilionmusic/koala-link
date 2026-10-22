import Accelerate
import AppKit
import AVFoundation

// STUTTER IN TIME WITH KOALA (2026-10-22). On the MPC Touch, STUTTER is touched on Koala's own Perform page, which
// sends no MIDI. So the webcam learns where Koala's STUTTER is (LEARN, then touch it once) and watches the touches the
// touch driver makes: a touch there on the Perform page holds the video stutter until it lifts. Koala's repeat length
// is then measured from its sound (the length at which the sound repeats itself since the touch), so the video repeats
// at the same timing; until Koala has repeated once, a 1/16 of the song's tempo stands in.

/// Touches on Koala's STUTTER, and LEARN.
final class KoalaStutterTouch {
    /// Where STUTTER is: 0…1 of Koala's window, from the top left.
    var spot: CGPoint?
    var learning = false
    var onLearned: ((CGPoint) -> Void)?
    private var monitor: Any?
    private var holding = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in self?.handle(event) }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if holding { holding = false; KoalaPerformanceFeed.shared.setTouchStutter(false) }
    }
    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if holding { holding = false; KoalaPerformanceFeed.shared.setTouchStutter(false) }
            return
        }
        guard let (point, frame) = Self.koalaPoint(NSEvent.mouseLocation) else { return }
        if learning { learning = false; spot = point; onLearned?(point); return }
        guard let spot, KoalaPerformanceFeed.shared.snapshot.page.map({ $0 == "perform" }) ?? true else { return }
        // Within about a finger's width of the learned spot.
        let dx = (point.x - spot.x) * frame.width, dy = (point.y - spot.y) * frame.height
        guard hypot(dx, dy) < max(28, frame.width * 0.035) else { return }
        holding = true; KoalaPerformanceFeed.shared.setTouchStutter(true)
    }
    /// A screen point (Cocoa, bottom left) as 0…1 of Koala's biggest window, and that window (top-left coordinates).
    static func koalaPoint(_ cocoa: NSPoint) -> (CGPoint, CGRect)? {
        guard let primary = NSScreen.screens.first?.frame else { return nil }
        let p = CGPoint(x: cocoa.x, y: primary.maxY - cocoa.y)
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: KoalaScreenCapture.bundleID).map(\.processIdentifier))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frames = windows.compactMap { w -> CGRect? in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid), (w[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bounds), r.width > 200 else { return nil }
            return r
        }
        guard let frame = frames.max(by: { $0.width * $0.height < $1.width * $1.height }), frame.contains(p) else { return nil }
        return (CGPoint(x: (p.x - frame.minX) / frame.width, y: (p.y - frame.minY) / frame.height), frame)
    }
}

/// Koala's stutter length, from its sound: mono at 4 kHz with host times, searched for the shortest length (40–700 ms)
/// at which the sound since the stutter began repeats itself.
final class StutterPeriodFinder {
    private static let rate = 4000.0
    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 12000)
    private var write = 0, filled = 0, lastTime = 0.0
    private var sum: Float = 0, summed = 0
    private var found: (since: Double, period: Double?, at: Double)?

    func add(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let d = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              d.mFormatFlags & kAudioFormatFlagIsFloat != 0, d.mBitsPerChannel == 32, d.mSampleRate > 0 else { return }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let interleaved = d.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(d.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(sample)
        let step = max(1, Int((d.mSampleRate / Self.rate).rounded()))
        let end = CMSampleBufferGetPresentationTimeStamp(sample).seconds + Double(frames) / d.mSampleRate
        lock.lock(); defer { lock.unlock() }
        for f in 0..<frames {
            var v: Float = 0
            if interleaved, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                for c in 0..<channels { v += data[f * channels + c] }
            } else {
                for c in 0..<min(channels, buffers.count) { if let data = buffers[c].mData?.assumingMemoryBound(to: Float.self) { v += data[f] } }
            }
            sum += v; summed += 1
            if summed == step {
                ring[write] = sum / Float(step * max(1, channels)); write = (write + 1) % ring.count; filled = min(ring.count, filled + 1)
                sum = 0; summed = 0
            }
        }
        lastTime = end
    }

    /// The repeat length in seconds since `since` (host seconds), or nil until Koala has repeated. Looked for at most
    /// every 80 ms (then every 300 ms once found).
    /// `beat`: the song's beat in seconds, when known; the length is then one of the tempo's divisions (whole beat down to
    /// a 1/64, straight, dotted or triplet), so a held note's pitch can't pass for a repeat.
    func period(since: Double, beat: Double? = nil) -> Double? {
        let now = KoalaPerformanceFeed.now()
        lock.lock(); defer { lock.unlock() }
        if let found, found.since == since, now - found.at < (found.period == nil ? 0.08 : 0.3) { return found.period }
        // The sound from just after the touch (Koala's own output delay) to now.
        let start = since + 0.05
        let count = min(filled, Int((lastTime - start) * Self.rate))
        var period: Double?
        if count >= 400 {
            var segment = [Float](repeating: 0, count: count)
            for i in 0..<count { segment[i] = ring[(write - count + i + ring.count) % ring.count] }
            period = Self.search(segment, beat: beat)
        }
        found = (since, period, now)
        return period
    }

    private static let divisions: [Double] = [1, 3 / 4, 2 / 3, 1 / 2, 3 / 8, 1 / 3, 1 / 4, 3 / 16, 1 / 6, 1 / 8, 1 / 12, 1 / 16]
    private static func search(_ x: [Float], beat: Double? = nil) -> Double? {
        let minLag = Int(0.04 * rate), maxLag = min(Int(0.7 * rate), x.count * 2 / 3)
        guard maxLag > minLag else { return nil }
        // Squares summed so far, for each shifted window's energy.
        var running = [Float](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { running[i + 1] = running[i] + x[i] * x[i] }
        var scores: [(lag: Int, score: Float)] = []
        x.withUnsafeBufferPointer { p in
            for lag in minLag...maxLag {
                let w = min(x.count - lag, 1600)
                let ea = running[w] - running[0], eb = running[lag + w] - running[lag]
                guard ea > 1e-6, eb > 1e-6 else { continue }
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &dot, vDSP_Length(w))
                scores.append((lag, dot / sqrt(ea * eb)))
            }
        }
        if let beat, beat > 0 {
            scores = scores.filter { s in
                let length = Double(s.lag) / rate
                return divisions.contains { abs(length - $0 * beat) <= $0 * beat * 0.06 }
            }
        }
        guard let best = scores.max(by: { $0.score < $1.score }), best.score > 0.75 else { return nil }
        // The shortest length that repeats about as well (a repeat also matches at twice its length).
        let shortest = scores.first { $0.score >= best.score - 0.03 } ?? best
        return Double(shortest.lag) / rate
    }
}
