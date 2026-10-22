import AppKit
import AVFoundation

// WEBCAM SOUND (2026-10-22): what the recordings' sound goes through, in order, on the capture's own audio thread:
// DRIVE (0 to +12 dB) → MPC3000 OUT, a soft clipper after the MPC3000's output → LIMITER at −1 dBFS, so a video is
// loud without clipping. The VU meter reads the result.
//
// The MPC3000 OUT is an approximation from the machine's known character, not a measurement of real hardware: a gentle
// top-end roll-off like its output filter (a one-pole low-pass at 16 kHz) and an output stage that rounds peaks a
// little unevenly (an asymmetric tanh: unity gain for quiet sound, a touch of second harmonic as it is pushed, and a
// DC blocker for the asymmetry).
//
// The limiter looks 1.5 ms ahead: each sample's needed gain is held over the look-ahead, released over 120 ms, then
// averaged over the look-ahead, so the gain is already down when a peak arrives (no overshoot, no click). The sound is
// moved back by the look-ahead so it stays in sync with the picture.

final class WebcamSoundChain {
    /// dBFS: the VU (RMS, 300 ms), the peak, and how much the limiter is taking off.
    struct Meter { var vu = -60.0, peak = -60.0, reduction = 0.0 }
    static let ceiling: Float = 0.891
    private let lock = NSLock()
    private var drive: Float = 1, clip = true, limit = true
    private var meter = Meter()
    private var rate = 0.0, lookahead = 0
    private var lowpass: [Float] = [0, 0], dcIn: [Float] = [0, 0], dcOut: [Float] = [0, 0]
    private var lowpassCoef: Float = 0, dcCoef: Float = 0, releaseCoef: Float = 0, vuCoef: Float = 0
    private var delayL: [Float] = [], delayR: [Float] = [], needed: [Float] = [], smoothed: [Float] = []
    private var index = 0, held: Float = 1, sum: Float = 0, vuSquare: Float = 0, peak: Float = 0

    func configure(driveDB: Double, clip: Bool, limit: Bool) {
        lock.lock(); drive = Float(pow(10, driveDB / 20)); self.clip = clip; self.limit = limit; lock.unlock()
    }
    var reading: Meter { lock.lock(); defer { lock.unlock() }; return meter }

    private func prepare(_ sampleRate: Double) {
        rate = sampleRate; lookahead = max(1, Int(sampleRate * 0.0015))
        let n = lookahead + 1
        delayL = Array(repeating: 0, count: n); delayR = delayL; needed = Array(repeating: 1, count: n); smoothed = needed
        index = 0; held = 1; sum = Float(n)
        lowpassCoef = Float(1 - exp(-2 * Double.pi * 16000 / sampleRate))
        dcCoef = Float(exp(-2 * Double.pi * 10 / sampleRate))
        releaseCoef = Float(1 - exp(-1 / (0.12 * sampleRate)))
        vuCoef = Float(1 - exp(-1 / (0.3 * sampleRate)))
    }

    /// The asymmetric output-stage curve: tanh(x + b) − tanh(b), scaled to unity gain at zero.
    private static let bias: Float = 0.08
    private static let offset = tanh(bias), slope = 1 - tanh(bias) * tanh(bias)
    private func colour(_ x: Float, _ ch: Int) -> Float {
        lowpass[ch] += (x - lowpass[ch]) * lowpassCoef
        let shaped = (tanh(lowpass[ch] + Self.bias) - Self.offset) / Self.slope
        let out = shaped - dcIn[ch] + dcCoef * dcOut[ch]
        dcIn[ch] = shaped; dcOut[ch] = out
        return out
    }

    /// A processed copy of `sample` (32-bit float only; anything else passes through untouched).
    func process(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let d = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              d.mFormatID == kAudioFormatLinearPCM, d.mFormatFlags & kAudioFormatFlagIsFloat != 0, d.mBitsPerChannel == 32,
              d.mSampleRate > 0, d.mChannelsPerFrame > 0 else { return sample }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return sample }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return sample }
        if d.mSampleRate != rate { prepare(d.mSampleRate) }
        lock.lock(); let gain = drive, clip = self.clip, limit = self.limit; lock.unlock()

        // Our own copy, in the source's layout (interleaved or one buffer per channel).
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let interleaved = d.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(d.mChannelsPerFrame), frames = CMSampleBufferGetNumSamples(sample)
        let counts = buffers.map { Int($0.mDataByteSize) / 4 }
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: max(1, counts.reduce(0, +))); defer { storage.deallocate() }
        var starts: [UnsafeMutablePointer<Float>] = []
        var at = 0
        for (b, count) in zip(buffers, counts) {
            if let data = b.mData { storage.advanced(by: at).update(from: data.assumingMemoryBound(to: Float.self), count: count) }
            else { storage.advanced(by: at).initialize(repeating: 0, count: count) }
            starts.append(storage.advanced(by: at)); at += count
        }
        func pointer(_ frame: Int, _ ch: Int) -> UnsafeMutablePointer<Float>? {
            let c = min(ch, channels - 1)
            if interleaved { return frame * channels + c < counts[0] ? starts[0].advanced(by: frame * channels + c) : nil }
            return c < starts.count && frame < counts[c] ? starts[c].advanced(by: frame) : nil
        }

        let n = lookahead + 1
        var loudest: Float = 0, lowestGain: Float = 1
        for f in 0..<frames {
            guard let pl = pointer(f, 0) else { break }
            let pr = pointer(f, 1) ?? pl
            var l = pl.pointee * gain, r = pr.pointee * gain
            if clip { l = colour(l, 0); r = colour(r, 1) }
            // Look-ahead limiter (see the top of the file).
            delayL[index] = l; delayR[index] = r
            let p = max(abs(l), abs(r))
            needed[index] = p > Self.ceiling ? Self.ceiling / p : 1
            var hold: Float = 1
            for v in needed where v < hold { hold = v }
            held = hold < held ? hold : held + (hold - held) * releaseCoef
            sum += held - smoothed[index]; smoothed[index] = held
            let g = limit ? min(1, sum / Float(n)) : 1
            let oldest = (index + 1) % n
            var ol = delayL[oldest] * g, or = delayR[oldest] * g
            if limit { ol = max(-Self.ceiling, min(Self.ceiling, ol)); or = max(-Self.ceiling, min(Self.ceiling, or)) }
            index = oldest
            pl.pointee = ol
            if channels > 1 { pr.pointee = or }
            vuSquare += ((ol * ol + or * or) / 2 - vuSquare) * vuCoef
            loudest = max(loudest, abs(ol), abs(or)); lowestGain = min(lowestGain, g)
        }
        sum = smoothed.reduce(0, +)

        lock.lock()
        meter.vu = 10 * log10(max(1e-7, Double(vuSquare)))
        peak = max(loudest, peak * 0.85)
        meter.peak = 20 * log10(max(1e-6, Double(peak)))
        meter.reduction = 20 * log10(Double(lowestGain))
        lock.unlock()

        // A new buffer with the processed sound, moved back by the look-ahead.
        let out = AudioBufferList.allocate(maximumBuffers: buffers.count); defer { free(out.unsafeMutablePointer) }
        for (i, b) in buffers.enumerated() {
            out[i] = AudioBuffer(mNumberChannels: b.mNumberChannels, mDataByteSize: UInt32(counts[i] * 4), mData: UnsafeMutableRawPointer(starts[i]))
        }
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: CMTimeValue(lookahead), timescale: CMTimeScale(d.mSampleRate)))
        var made: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                                              formatDescription: format, sampleCount: frames, presentationTimeStamp: pts,
                                                              packetDescriptions: nil, sampleBufferOut: &made) == noErr, let made,
              CMSampleBufferSetDataBufferFromAudioBufferList(made, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: out.unsafePointer) == noErr
        else { return sample }
        return made
    }
}

/// An analogue-style VU: 0 VU = −14 dBFS RMS (about where streaming platforms set loudness), red from 0 VU, with the
/// peak and the limiter's gain reduction written underneath.
final class WebcamVUView: NSView {
    var reading = WebcamSoundChain.Meter() { didSet { needsDisplay = true } }
    private var needle = -20.0
    static let reference = -14.0
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSBezierPath(roundedRect: b, xRadius: 10, yRadius: 10).fill()
        let centre = NSPoint(x: b.midX, y: b.minY + 34), radius = min(b.width * 0.46, b.height - 48)
        func angle(_ vu: Double) -> CGFloat {
            let t = (max(-20, min(3, vu)) + 20) / 23
            return CGFloat(150 - 120 * t) * .pi / 180
        }
        func point(_ vu: Double, _ r: CGFloat) -> NSPoint { NSPoint(x: centre.x + cos(angle(vu)) * r, y: centre.y + sin(angle(vu)) * r) }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.75)]
        for mark in [-20.0, -10, -7, -5, -3, -1, 0, 1, 2, 3] {
            let tick = NSBezierPath(); tick.move(to: point(mark, radius - 8)); tick.line(to: point(mark, radius))
            (mark >= 0 ? KoalaLook.pink : NSColor(white: 1, alpha: 0.7)).setStroke(); tick.lineWidth = 2; tick.stroke()
            let text = (mark > 0 ? "+" : "") + String(Int(mark)) as NSString
            let size = text.size(withAttributes: attributes), p = point(mark, radius + 9)
            text.draw(at: NSPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attributes)
        }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: centre, radius: radius - 4, startAngle: angle(0) * 180 / .pi, endAngle: angle(3) * 180 / .pi, clockwise: true)
        KoalaLook.pink.setStroke(); arc.lineWidth = 4; arc.stroke()
        // The needle eases toward the reading, as a real one would.
        needle += (reading.vu - Self.reference - needle) * 0.35
        let hand = NSBezierPath(); hand.move(to: centre); hand.line(to: point(needle, radius - 2))
        KoalaLook.blue.setStroke(); hand.lineWidth = 2.5; hand.stroke()
        let label = String(format: "VU   PEAK %.1f dB   LIMIT %.1f dB", reading.peak, reading.reduction) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: b.midX - size.width / 2, y: b.minY + 8), withAttributes: attributes)
    }
}
