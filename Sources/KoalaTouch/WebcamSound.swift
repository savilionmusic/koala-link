import AppKit
import AVFoundation

// WEBCAM SOUND (2026-10-22): what the recordings' sound goes through, in order, on the capture's own audio thread:
// DRIVE (0 to +12 dB) → MPC3000 OUT, a soft clipper after the MPC3000's output → LIMITER with a THRESHOLD (0 to
// −20 dB: the sound is raised by that much into it) and a −1 dBFS ceiling, so a video is loud without clipping. The dB
// meter reads the result.
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
    /// dBFS, left and right: RMS (300 ms) and peak (falling back), and how much the limiter is taking off.
    struct Meter { var rms = [-90.0, -90.0], peak = [-90.0, -90.0], reduction = 0.0 }
    static let ceiling: Float = 0.891
    private let lock = NSLock()
    private var drive: Float = 1, push: Float = 1, clip = true, limit = true
    private var meter = Meter()
    private var rate = 0.0, lookahead = 0
    private var lowpass: [Float] = [0, 0], dcIn: [Float] = [0, 0], dcOut: [Float] = [0, 0]
    private var lowpassCoef: Float = 0, dcCoef: Float = 0, releaseCoef: Float = 0, vuCoef: Float = 0
    private var delayL: [Float] = [], delayR: [Float] = [], needed: [Float] = [], smoothed: [Float] = []
    private var index = 0, held: Float = 1, sum: Float = 0, squares: [Float] = [0, 0], peaks: [Float] = [0, 0]

    func configure(driveDB: Double, clip: Bool, limit: Bool, thresholdDB: Double) {
        lock.lock()
        drive = Float(pow(10, driveDB / 20)); push = Float(pow(10, -min(0, thresholdDB) / 20)); self.clip = clip; self.limit = limit
        lock.unlock()
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
        lock.lock(); let gain = drive, clip = self.clip, limit = self.limit, push = limit ? self.push : 1; lock.unlock()

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
        var loudest: [Float] = [0, 0], lowestGain: Float = 1
        for f in 0..<frames {
            guard let pl = pointer(f, 0) else { break }
            let pr = pointer(f, 1) ?? pl
            var l = pl.pointee * gain, r = pr.pointee * gain
            if clip { l = colour(l, 0); r = colour(r, 1) }
            l *= push; r *= push
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
            squares[0] += (ol * ol - squares[0]) * vuCoef; squares[1] += (or * or - squares[1]) * vuCoef
            loudest[0] = max(loudest[0], abs(ol)); loudest[1] = max(loudest[1], abs(or)); lowestGain = min(lowestGain, g)
        }
        sum = smoothed.reduce(0, +)

        lock.lock()
        for c in 0..<2 {
            peaks[c] = max(loudest[c], peaks[c] * 0.85)
            meter.rms[c] = 10 * log10(max(1e-9, Double(squares[c])))
            meter.peak[c] = 20 * log10(max(1e-5, Double(peaks[c])))
        }
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

/// The dB meter: left and right bars from −48 to 0 dBFS (RMS filled, peak as a line with its number), and the limiter's
/// gain reduction under them. Blue to −12, yellow to −3, pink above.
final class WebcamDBMeter: NSView {
    var reading = WebcamSoundChain.Meter() { didSet { needsDisplay = true } }
    private static let floor = -48.0
    private func x(_ db: Double, _ r: NSRect) -> CGFloat { r.minX + r.width * CGFloat((max(Self.floor, min(0, db)) - Self.floor) / -Self.floor) }
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill(); NSBezierPath(roundedRect: b, xRadius: 6, yRadius: 6).fill()
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.7)]
        let labelWidth: CGFloat = 14, numberWidth: CGFloat = 40
        let area = NSRect(x: b.minX + 6 + labelWidth, y: b.minY + 16, width: b.width - 12 - labelWidth - numberWidth, height: b.height - 22)
        let rowHeight = (area.height - 4) / 3
        for c in 0..<2 {
            let row = NSRect(x: area.minX, y: area.maxY - CGFloat(c + 1) * rowHeight - CGFloat(c) * 2, width: area.width, height: rowHeight)
            NSColor(white: 1, alpha: 0.08).setFill(); row.fill()
            let level = x(reading.rms[c], row)
            for (from, to, colour) in [(Self.floor, -12.0, KoalaLook.blue), (-12.0, -3.0, NSColor.systemYellow), (-3.0, 0.0, KoalaLook.pink)] {
                let start = x(from, row), end = min(level, x(to, row))
                if end > start { colour.setFill(); NSRect(x: start, y: row.minY, width: end - start, height: row.height).fill() }
            }
            let peakX = x(reading.peak[c], row)
            (reading.peak[c] > -3 ? KoalaLook.pink : NSColor.white).setFill()
            NSRect(x: peakX - 1, y: row.minY, width: 2, height: row.height).fill()
            (c == 0 ? "L" : "R" as NSString).draw(at: NSPoint(x: b.minX + 6, y: row.midY - 7), withAttributes: small)
            let number = reading.peak[c] < -80 ? "–" : String(format: "%.1f", reading.peak[c])
            (number as NSString).draw(at: NSPoint(x: row.maxX + 6, y: row.midY - 7), withAttributes: small)
        }
        // The limiter's gain reduction grows from the right (0 to −12 dB across).
        let gr = NSRect(x: area.minX, y: area.minY, width: area.width, height: rowHeight)
        NSColor(white: 1, alpha: 0.05).setFill(); gr.fill()
        let amount = CGFloat(min(12, -reading.reduction) / 12) * gr.width
        KoalaLook.pink.withAlphaComponent(0.8).setFill(); NSRect(x: gr.maxX - amount, y: gr.minY, width: amount, height: gr.height).fill()
        ("GR" as NSString).draw(at: NSPoint(x: b.minX + 4, y: gr.midY - 7), withAttributes: small)
        (String(format: "%.1f", reading.reduction) as NSString).draw(at: NSPoint(x: gr.maxX + 6, y: gr.midY - 7), withAttributes: small)
        for mark in [-48.0, -24, -12, -6, -3, 0] {
            let text = (mark == 0 ? "0" : String(Int(mark))) as NSString
            let size = text.size(withAttributes: small)
            text.draw(at: NSPoint(x: x(mark, area) - size.width / 2, y: b.minY + 2), withAttributes: small)
        }
    }
}
