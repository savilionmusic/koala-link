import Foundation
import AVFoundation
import Accelerate

/// Audio identity includes the file inode because Koala can replace a sample
/// using the same numeric ID. Trim/chop edits do not invalidate decoded peaks.
struct KoalaAudioSignature: Hashable {
    let path: String
    let modified: Date
    let size: UInt64
    let fileNumber: UInt64

    init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else { return nil }
        self.path = url.path; self.modified = modified; self.size = size.uint64Value
        self.fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}

struct KoalaWaveformAudio {
    let signature: KoalaAudioSignature
    let peaks: [Float]
    let frames: Double
    let sampleRate: Double

    func wave(for pad: KoalaSession.Pad) -> KoalaWave {
        KoalaWave(peaks: peaks, slices: pad.slices.map { $0 / frames },
                  start: pad.start / frames, end: min(1, (pad.end ?? frames) / frames),
                  duration: frames / sampleRate, frames: frames)
    }
}

/// A changed pad can stop a long decode at the next PCM chunk, rather than
/// waiting behind the whole previous sample on the worker queue.
final class KoalaWaveformReadToken {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum KoalaWaveformReader {
    static func read(_ signature: KoalaAudioSignature, token: KoalaWaveformReadToken) -> KoalaWaveformAudio? {
        let url = URL(fileURLWithPath: signature.path)
        guard !token.cancelled, KoalaAudioSignature(url: url) == signature,
              let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0, file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return nil }
        let columns = 960, length = Double(file.length)
        var peaks = [Float](repeating: 0, count: columns)
        while file.framePosition < file.length {
            guard !token.cancelled else { return nil }
            let firstFrame = file.framePosition
            let amount = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - firstFrame))
            guard amount > 0, (try? file.read(into: buffer, frameCount: amount)) != nil,
                  buffer.frameLength > 0, let channels = buffer.floatChannelData else { return nil }
            var offset = 0
            let count = Int(buffer.frameLength)
            while offset < count {
                let absoluteFrame = Double(firstFrame) + Double(offset)
                let column = min(columns - 1, Int(absoluteFrame * Double(columns) / length))
                let columnEnd = ceil(Double(column + 1) * length / Double(columns))
                let segment = max(1, min(count - offset, Int(columnEnd - absoluteFrame)))
                for channel in 0..<Int(buffer.format.channelCount) {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: offset), 1, &peak, vDSP_Length(segment))
                    peaks[column] = max(peaks[column], min(1, peak))
                }
                offset += segment
            }
        }
        guard !token.cancelled, KoalaAudioSignature(url: url) == signature else { return nil }
        // Koala's editor makes quiet clips readable. Scale only these display
        // peaks, rather than changing the file or a sample's playback volume.
        if let peak = peaks.max(), peak.isFinite, peak > 0 {
            for i in peaks.indices { peaks[i] = min(1, peaks[i] / peak) }
        }
        return KoalaWaveformAudio(signature: signature, peaks: peaks, frames: length, sampleRate: file.processingFormat.sampleRate)
    }
}
