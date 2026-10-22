import Accelerate
import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

// WEBCAM (2026-10-22): one camera and Koala's sound, with the pad being played, its waveform and the Perform effects
// seen on the picture; 16:9 or 9:16, and a tutorial layout with Koala's whole window. Modelled on Paper Cut's
// performance recording (its PerformanceRecorder.swift and VisualFX.swift), with one camera.
//
// - **Sound**: Koala's own output through ScreenCaptureKit (no loopback driver; needs Screen & System Audio Recording),
//   or any audio input. Koala Link makes no sound of its own.
// - **Picture**: the camera fills the frame. With KOALA SCREEN on, Koala's window fills it and the camera sits in a
//   corner (16:9) or under it (9:16). Effects apply to the picture; the overlay stays readable on top.
// - **Effects**: what the controller sends Koala (KoalaPerformanceFeed): STUTTER repeats the picture on a 1/16 of the
//   song's tempo, GATE blacks out the off 1/16s, FILTER blurs, CRUSH pixelates. Letting go returns to normal.
// - **Files**: Koala_Performance_<time>.mp4 in the chosen folder (~/Movies/Koala Link until one is chosen), hardware
//   H.264 and AAC on the host clock.

struct WebcamSettings: Codable, Equatable {
    var camera: String?
    /// "koala" = Koala's own sound; otherwise an audio input's unique ID.
    var audio = "koala"
    var vertical = false, tutorial = false, overlay = true, effects = true, mirror = true
    /// 9:16 turns the camera a quarter: 1 = right (the default), 2 = left, 0 = not at all (optional so older saved
    /// settings still load).
    var rotate: Int?
    /// DRIVE in dB (0…12), MPC3000 OUT and LIMITER (WebcamSound.swift).
    var drive: Double?, mpcOut: Bool?, limiter: Bool?
    /// The limiter's threshold in dB (0 to −20; the ceiling is always −1 dBFS).
    var threshold: Double?
    /// Where Koala's STUTTER is on its Perform page (0…1 of Koala's window, from the top left), learned by touch.
    var stutterSpot: CGPoint?
    /// LISTEN: play the processed sound out of `listenDevice` (an output's unique ID; nil = the Mac's default).
    var listen: Bool?, listenDevice: String?
    /// Where recordings go (a path); nil = ~/Movies/Koala Link.
    var folder: String?
    var folderURL: URL {
        folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Koala Link", isDirectory: true)
    }
    /// Where things sit for each shape and layout, dragged on the setup screen.
    var layouts: [String: WebcamLayout]?
    var layoutKey: String { (vertical ? "tall" : "wide") + (tutorial ? " tutorial" : "") }
    /// The camera always keeps its standard place; Koala's screen and the card can be moved.
    var layout: WebcamLayout {
        let standard = WebcamLayout.standard(vertical: vertical, tutorial: tutorial)
        guard var saved = layouts?[layoutKey] else { return standard }
        saved.camera = standard.camera
        return saved
    }
    private static let key = "KoalaLink.webcam"
    static func load() -> WebcamSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(WebcamSettings.self, from: data) else { return WebcamSettings() }
        return saved
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) } }
    var size: (w: Int, h: Int) { vertical ? (1080, 1920) : (1920, 1080) }
}

/// Where the camera, Koala's window and the card sit (0…1 of the picture, from the bottom left).
struct WebcamLayout: Codable, Equatable {
    var camera: CGRect, koala: CGRect, card: CGPoint
    static func standard(vertical: Bool, tutorial: Bool) -> WebcamLayout {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let card = CGPoint(x: 0.025, y: vertical ? 0.014 : 0.044)
        guard tutorial else { return WebcamLayout(camera: full, koala: full, card: card) }
        if vertical { return WebcamLayout(camera: CGRect(x: 0, y: 0, width: 1, height: 0.42), koala: CGRect(x: 0, y: 0.42, width: 1, height: 0.58), card: card) }
        return WebcamLayout(camera: CGRect(x: 0.705, y: 0.686, width: 0.27, height: 0.27), koala: full, card: card)
    }
}

enum WebcamDevices {
    /// Real cameras first (iPhone, USB cameras, the Mac's own); virtual cameras (OBS, NDI, Camo) last.
    static func cameras() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types += [.continuityCamera, .external] } else { types.append(.externalUnknown) }
        func rank(_ d: AVCaptureDevice) -> Int {
            let n = d.localizedName.lowercased()
            if ["virtual", "obs", "ndi", "camo", "snap camera"].contains(where: n.contains) { return 3 }
            return d.deviceType == .builtInWideAngleCamera ? 2 : 0
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .filter { $0.isConnected && !$0.isSuspended }.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
    static func microphones() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) { types = [.microphone, .external] } else { types = [.builtInMicrophone, .externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified).devices.filter(\.isConnected)
    }
}

private func failure(_ text: String) -> NSError {
    NSError(domain: "KoalaLink.Webcam", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}

/// Core Image into pooled, IOSurface-backed BGRA buffers.
final class FrameRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: colorSpace])
    private var pool: CVPixelBufferPool?, poolSize = (0, 0)
    func render(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                             kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                                             kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attributes as CFDictionary, &made)
            pool = made; poolSize = (width, height)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        Self.context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: Self.colorSpace)
        return out
    }
}

/// The camera: its session and its newest frame, copied at once so the camera's small pool is never held up.
final class WebcamCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "Koala Link camera", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var count = 0
    private let copier = FrameRenderer()
    init(device: AVCaptureDevice) throws {
        super.init()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw failure("\(device.localizedName) is in use by another app") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw failure("Can't read \(device.localizedName)") }
        session.addOutput(output)
        session.commitConfiguration()
    }
    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    var frame: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }
    /// How many frames have arrived (a new one means a new picture to make).
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        let own = copier.render(CIImage(cvPixelBuffer: buffer), width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        lock.lock(); latest = own ?? buffer; count &+= 1; lock.unlock()
    }
}

/// Koala through ScreenCaptureKit: its sound, and its biggest window when the tutorial layout needs it.
final class KoalaScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    static let bundleID = "com.elf-audio.koala-mac"
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((String) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Koala Link screen capture", qos: .userInitiated)
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var video = false, audio = false, region = CGRect.zero
    /// Stopped before the stream had started: it is stopped as soon as it does.
    private var stopped = false
    private var refresh: Timer?
    static let permission = "Allow Koala Link in System Settings › Privacy & Security › Screen & System Audio Recording, then reopen Webcam."

    /// `done` (main thread) gets a problem to show, or nil once Koala is being captured.
    func start(video: Bool, audio: Bool, done: @escaping (String?) -> Void) {
        self.video = video; self.audio = audio
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self else { return }
            guard let content else { DispatchQueue.main.async { done(Self.permission) }; return }
            guard let app = content.applications.first(where: { $0.bundleIdentifier == Self.bundleID }),
                  let (display, rect) = Self.target(content) else { DispatchQueue.main.async { done("Open Koala first: Webcam captures its sound and screen.") }; return }
            let stream = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []),
                                  configuration: self.configuration(rect), delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                if audio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue) }
            } catch { DispatchQueue.main.async { done(error.localizedDescription) }; return }
            stream.startCapture { error in
                DispatchQueue.main.async {
                    if error != nil { done(Self.permission); return }
                    if self.stopped { stream.stopCapture { _ in }; return }
                    self.stream = stream; self.region = rect
                    // Koala's window can move or resize: follow it.
                    if video { self.refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.follow() } }
                    done(nil)
                }
            }
        }
    }
    func stop() {
        // The stream and the window-following timer are set on the main thread.
        DispatchQueue.main.async {
            self.stopped = true
            self.refresh?.invalidate(); self.refresh = nil
            self.stream?.stopCapture { _ in }; self.stream = nil
        }
        lock.lock(); latest = nil; lock.unlock()
    }
    var frame: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return latest }

    /// Koala's biggest window, and the display it is on (the window in that display's points).
    private static func target(_ content: SCShareableContent) -> (SCDisplay, CGRect)? {
        let windows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 && $0.frame.width > 200 }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)) }) ?? content.displays.first
        else { return nil }
        let rect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY).intersection(CGRect(origin: .zero, size: display.frame.size))
        return rect.isEmpty ? nil : (display, rect)
    }
    private func configuration(_ rect: CGRect) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.capturesAudio = audio; c.excludesCurrentProcessAudio = true; c.sampleRate = 48000; c.channelCount = 2
        c.pixelFormat = kCVPixelFormatType_32BGRA; c.queueDepth = 5; c.showsCursor = true
        if video {
            let scale = min(2, 1920 / max(rect.width, rect.height))
            c.sourceRect = rect
            c.width = Int(rect.width * scale / 2) * 2; c.height = Int(rect.height * scale / 2) * 2
            c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        } else {
            // Sound only: the smallest, slowest picture ScreenCaptureKit allows.
            c.width = 64; c.height = 64; c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        return c
    }
    private func follow() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            guard let self, let content, let (_, rect) = Self.target(content) else { return }
            DispatchQueue.main.async {
                guard let stream = self.stream, rect != self.region else { return }
                self.region = rect
                stream.updateConfiguration(self.configuration(rect)) { _ in }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        switch type {
        case .audio: onAudio?(sample)
        case .screen:
            guard video, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            lock.lock(); latest = buffer; lock.unlock()
        default: break
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onStop?("Koala's capture stopped: \(error.localizedDescription)") }
    }
}

/// An audio input (interface, microphone), stereo float at 48 kHz, retimed onto the host clock.
final class WebcamMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onAudio: ((CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "Koala Link audio input", qos: .userInitiated)
    init(device: AVCaptureDevice) throws {
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw failure("\(device.localizedName) is in use") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw failure("Can't read \(device.localizedName)") }
        session.addOutput(output)
    }
    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { onAudio?(sample); return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                        presentationTimeStamp: CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sample), from: clock, to: CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        onAudio?(copy ?? sample)
    }
}

/// One MP4: hardware H.264 picture and AAC sound, on the host clock. The file starts at its first picture.
final class WebcamWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput, audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var started = false, finished = false, lastVideo = CMTime.invalid
    init(url: URL, width: Int, height: Int) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 6, AVVideoExpectedSourceFrameRateKey: 30,
                                              AVVideoMaxKeyFrameIntervalKey: 60, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel] as [String: Any]])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else { throw failure("Can't write \(url.lastPathComponent)") }
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? failure("Can't write \(url.lastPathComponent)") }
    }
    func appendVideo(_ buffer: CVPixelBuffer, at time: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, time.isValid else { return }
        if !started { writer.startSession(atSourceTime: time); started = true }
        guard !lastVideo.isValid || time > lastVideo, video.isReadyForMoreMediaData else { return }
        if adaptor.append(buffer, withPresentationTime: time) { lastVideo = time }
    }
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard started, !finished, audio.isReadyForMoreMediaData else { return }
        audio.append(sample)
    }
    func finish(_ done: @escaping (Bool) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); done(false); return }
        finished = true
        let ok = started
        if ok { video.markAsFinished(); audio.markAsFinished(); writer.endSession(atSourceTime: lastVideo.isValid ? lastVideo : .zero) }
        lock.unlock()
        guard ok else { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); done(false); return }
        writer.finishWriting { [writer] in done(writer.status == .completed) }
    }
}

/// How loud the sound is now (0…1, falling back over about a third of a second), from any audio thread.
final class WebcamLevel {
    private let lock = NSLock()
    private var peak: Float = 0, at = 0.0
    func add(_ sample: CMSampleBuffer) {
        let p = Self.peak(sample), now = KoalaPerformanceFeed.now()
        lock.lock(); if p >= value(now) { peak = p; at = now }; lock.unlock()
    }
    var level: Float { lock.lock(); defer { lock.unlock() }; return value(KoalaPerformanceFeed.now()) }
    private func value(_ now: Double) -> Float { max(0, peak - Float(now - at) * 3) }
    static func peak(_ sample: CMSampleBuffer) -> Float {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return 0 }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return 0 }
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            if description.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
                var p: Float = 0
                vDSP_maxmgv(data.assumingMemoryBound(to: Float.self), 1, &p, vDSP_Length(Int(buffer.mDataByteSize) / 4))
                peak = max(peak, p)
            } else if description.mBitsPerChannel == 16 {
                let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(buffer.mDataByteSize) / 2)
                for s in samples { peak = max(peak, Float(abs(Int32(s))) / 32768) }
            }
        }
        return min(1, peak)
    }
}

/// The effects Koala is playing, as pictures (Paper Cut's VisualFX, reduced to Koala's STUTTER, GATE, FILTER, CRUSH).
final class WebcamFX {
    /// `stutter`: the repeat length in seconds (0 = off), from `stutterStart` (host seconds). `filter`: −1 (low-pass) to 1.
    /// `cutter`: the length of each cut (half on, half black; 0 = off), counted from `cutterStart` so the first cut lands
    /// on the turn of the knob.
    struct State { var stutter = 0.0, stutterStart = 0.0, gate = 0.0, filter = 0.0, crush = 0.0, cutter = 0.0, cutterStart = 0.0 }
    /// An effect amount (1–127) as a note length in seconds: a quarter, 8th, 16th or 32nd note, shorter as the amount rises.
    static func division(_ amount: Int, beat: Double) -> Double { beat / Double(1 << min(3, max(0, amount - 1) / 32)) }
    private var history: [(time: Double, buffer: CVPixelBuffer)] = []
    /// The last 0.4 s of pictures, kept all the time, so a stutter repeats from the moment it began even though
    /// it is noticed a picture or two later.
    private var recent: [(time: Double, buffer: CVPixelBuffer)] = []
    private var loopFrom: Double?
    private let store = FrameRenderer()
    func process(_ image: CIImage, now: Double, state: State, frame: CGRect) -> CIImage {
        var out = image
        // A half-size copy of each picture (to save memory).
        let half = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        let copy = store.render(half, width: Int(frame.width / 2), height: Int(frame.height / 2))
        if let copy { recent.append((now, copy)) }
        while let first = recent.first, now - first.time > 0.4 { recent.removeFirst() }
        // STUTTER: the pictures from the stutter's start (kept up to a second), played round at Koala's repeat length.
        if state.stutter > 0 {
            let period = min(1, state.stutter), from = state.stutterStart
            if loopFrom != from { loopFrom = from; history = recent.filter { $0.time >= from - 0.02 } }
            else if now < from + 1, let copy { history.append((now, copy)) }
            let target = from + (now - from).truncatingRemainder(dividingBy: period)
            if let pick = history.last(where: { $0.time <= target }) ?? history.first {
                out = CIImage(cvPixelBuffer: pick.buffer).transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            }
        } else if loopFrom != nil { loopFrom = nil; history.removeAll() }
        if state.crush > 0 {
            out = out.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 6 + 34 * state.crush, kCIInputCenterKey: CIVector(x: 0, y: 0)])
        }
        // FILTER both ways, as Koala's: low-pass (below the middle) soft and dark, high-pass (above) hard and bleached.
        if state.filter < 0 {
            let f = -state.filter
            out = out.clampedToExtent().applyingGaussianBlur(sigma: 14 * f)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.2 * f, kCIInputSaturationKey: 1 - 0.4 * f])
        } else if state.filter > 0 {
            let f = state.filter
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 2.5 * f])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.12 * f, kCIInputSaturationKey: 1 - 0.8 * f, kCIInputContrastKey: 1 + 0.9 * f])
        }
        if state.gate > 0, (now / state.gate).truncatingRemainder(dividingBy: 1) >= 0.5 {
            out = out.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.08, y: 0, z: 0, w: 0),
                                                                    "inputGVector": CIVector(x: 0, y: 0.08, z: 0, w: 0),
                                                                    "inputBVector": CIVector(x: 0, y: 0, z: 0.08, w: 0)])
        }
        // CUTTER: the second half of each cut is black.
        if state.cutter > 0, ((now - state.cutterStart) / state.cutter).truncatingRemainder(dividingBy: 1) >= 0.5 {
            out = CIImage(color: .black)
        }
        return out.cropped(to: frame)
    }
}

/// Cameras, Koala's sound and screen, the composed picture, the preview and the file.
final class WebcamStudio {
    private let settingsLock = NSLock()
    private var stored = WebcamSettings.load()
    /// Read on any thread, changed through `update`: the main thread never waits for the compositor.
    var settings: WebcamSettings { settingsLock.lock(); defer { settingsLock.unlock() }; return stored }
    /// The composed picture for the window (main thread).
    var onPicture: ((CMSampleBuffer) -> Void)?
    var onProblem: ((String?) -> Void)?
    private(set) var recordingURL: URL?
    /// Set on `setupQueue`, read by `tick` (under `sourceLock`).
    private var camera: WebcamCamera?, screen: KoalaScreenCapture?
    private let sourceLock = NSLock()
    /// Cameras, Koala's sound, inputs and LISTEN open and close here, in order and off the main thread (a camera
    /// session or an aggregate device can take a moment). `microphone`, `koalaTap` and `monitor` changes happen here.
    private let setupQueue = DispatchQueue(label: "Koala Link webcam setup", qos: .userInitiated)
    private var microphone: WebcamMicrophone?
    /// Koala's sound through a process tap, which handles LISTEN itself (KoalaAudioTap.swift).
    private var koalaTap: AnyObject?
    private let queue = DispatchQueue(label: "Koala Link webcam", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var running = false
    private let renderer = FrameRenderer(), fx = WebcamFX(), painter = WebcamOverlayPainter(), level = WebcamLevel()
    private let sound = WebcamSoundChain()
    private let stutterLength = StutterPeriodFinder()
    /// Touches on Koala's STUTTER (main thread).
    let stutterTouch = KoalaStutterTouch()
    private let monitorLock = NSLock()
    private var monitor: WebcamMonitor?
    /// The VU, peak and limiting of the processed sound.
    var meter: WebcamSoundChain.Meter { sound.reading }

    init() {
        configureSound()
        stutterTouch.spot = settings.stutterSpot
        stutterTouch.onLearned = { [weak self] spot in self?.update { $0.stutterSpot = spot } }
    }
    private func configureSound() {
        let s = settings
        sound.configure(driveDB: s.drive ?? 0, clip: s.mpcOut ?? true, limit: s.limiter ?? true, thresholdDB: s.threshold ?? 0)
    }
    private let writerLock = NSLock()
    private var writer: WebcamWriter?
    private var format: CMVideoFormatDescription?

    /// `save` false while a slider or layout box is being dragged (saved when it is let go).
    func update(save: Bool = true, _ change: (inout WebcamSettings) -> Void) {
        settingsLock.lock(); let old = stored; var next = stored; change(&next); stored = next; settingsLock.unlock()
        if save { next.save() }
        guard next != old else { return }
        configureSound()
        guard running else { return }
        if next.camera != old.camera { setupQueue.async { self.closeCamera(); self.openCamera() } }
        let listenChanged = next.listen != old.listen || next.listenDevice != old.listenDevice
        if next.audio != old.audio || next.tutorial != old.tutorial || (next.audio == "koala" && listenChanged) {
            setupQueue.async { self.closeAudio(); self.openAudio(); self.restartMonitor() }
        } else if listenChanged { setupQueue.async { self.restartMonitor() } }
    }

    func start() {
        guard timer == nil else { return }
        running = true
        onProblem?(nil)
        stutterTouch.start()
        setupQueue.async { self.openCamera(); self.openAudio(); self.restartMonitor() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume(); timer = t
    }
    func stop() {
        stopRecording { _ in }
        timer?.cancel(); timer = nil
        running = false
        stutterTouch.stop()
        setupQueue.async { self.restartMonitor(); self.closeCamera(); self.closeAudio() }
    }

    private func report(_ text: String?) { DispatchQueue.main.async { [weak self] in self?.onProblem?(text) } }
    /// Asks for camera or microphone access (on `setupQueue`, which may wait for the answer).
    private func access(_ type: AVMediaType) -> Bool {
        if AVCaptureDevice.authorizationStatus(for: type) == .authorized { return true }
        let answered = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: type) { granted = $0; answered.signal() }
        answered.wait()
        return granted
    }

    private func openCamera() {
        guard running else { return }
        let s = settings
        guard access(.video) else { report("Allow Koala Link in System Settings › Privacy & Security › Camera."); return }
        let devices = WebcamDevices.cameras()
        guard let device = devices.first(where: { $0.uniqueID == s.camera }) ?? devices.first else { report("No camera found."); return }
        do {
            let c = try WebcamCamera(device: device); c.start()
            sourceLock.lock(); camera = c; sourceLock.unlock()
        } catch { report(error.localizedDescription) }
    }
    private func closeCamera() {
        sourceLock.lock(); let c = camera; camera = nil; sourceLock.unlock()
        c?.stop()
    }

    private func openAudio() {
        guard running else { return }
        let s = settings
        let audio: (CMSampleBuffer) -> Void = { [weak self] sample in _ = self?.handleAudio(sample) }
        // Koala's sound: a process tap where macOS has them (LISTEN switches Koala's dry sound for the processed one),
        // otherwise ScreenCaptureKit.
        var tapped = false
        if s.audio == "koala", #available(macOS 14.2, *),
           let koala = NSRunningApplication.runningApplications(withBundleIdentifier: KoalaScreenCapture.bundleID).first(where: { !$0.isTerminated }) {
            do {
                let tap = try KoalaAudioTap(pid: koala.processIdentifier, listen: s.listen == true, outputUID: s.listenDevice)
                tap.onAudio = { [weak self] sample in self?.handleAudio(sample) }
                koalaTap = tap; tapped = true
            } catch { report(error.localizedDescription) }
        }
        if (s.audio == "koala" && !tapped) || s.tutorial {
            let capture = KoalaScreenCapture()
            if s.audio == "koala" && !tapped { capture.onAudio = audio }
            capture.onStop = { [weak self] text in self?.onProblem?(text) }
            capture.start(video: s.tutorial, audio: s.audio == "koala" && !tapped) { [weak self] problem in if let problem { self?.onProblem?(problem) } }
            sourceLock.lock(); screen = capture; sourceLock.unlock()
        }
        if s.audio != "koala" {
            guard access(.audio) else { report("Allow Koala Link in System Settings › Privacy & Security › Microphone."); return }
            guard let device = WebcamDevices.microphones().first(where: { $0.uniqueID == s.audio }) else { report("That audio input isn't connected."); return }
            do { let m = try WebcamMicrophone(device: device); m.onAudio = audio; m.start(); microphone = m } catch { report(error.localizedDescription) }
        }
    }
    private func closeAudio() {
        if #available(macOS 14.2, *) { (koalaTap as? KoalaAudioTap)?.stop() }
        koalaTap = nil
        sourceLock.lock(); let s = screen; screen = nil; sourceLock.unlock()
        s?.stop()
        microphone?.stop(); microphone = nil
    }
    /// LISTEN for sources other than the tap (an audio input, or Koala on older macOS).
    private func restartMonitor() {
        let next = running && settings.listen == true && koalaTap == nil ? WebcamMonitor(deviceUID: settings.listenDevice) : nil
        monitorLock.lock(); let old = monitor; monitor = next; monitorLock.unlock()
        old?.stop()
    }
    /// Processes a block of sound for the meter, the file and (other than the tap) LISTEN; returns it processed.
    private func handleAudio(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        stutterLength.add(sample)
        let processed = sound.process(sample)
        level.add(processed)
        writerLock.lock(); let writer = self.writer; writerLock.unlock()
        writer?.appendAudio(processed)
        monitorLock.lock(); let monitor = self.monitor; monitorLock.unlock()
        monitor?.play(processed)
        return processed
    }

    var isRecording: Bool { writerLock.lock(); defer { writerLock.unlock() }; return writer != nil }
    func startRecording() throws -> URL {
        let folder = settings.folderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = folder.appendingPathComponent("Koala_Performance \(stamp.string(from: Date())) \(settings.vertical ? "9x16" : "16x9").mp4")
        let size = settings.size
        let made = try WebcamWriter(url: url, width: size.w, height: size.h)
        writerLock.lock(); writer = made; writerLock.unlock()
        recordingURL = url
        return url
    }
    func stopRecording(_ done: @escaping (URL?) -> Void) {
        writerLock.lock(); let finishing = writer; writer = nil; writerLock.unlock()
        guard let finishing else { done(nil); return }
        finishing.finish { ok in DispatchQueue.main.async { done(ok ? finishing.url : nil) } }
    }

    /// 30 times a second on `queue`: compose, record, show.
    private var lastCompose = 0.0, lastFrames = -1, lastFX: [String: Int] = [:], lastStutter = false
    /// Every 8 ms on `queue`: a picture as soon as the camera has a new frame or an effect starts or stops (else 30 a second).
    private func tick() {
        let s = settings, (w, h) = s.size, frame = CGRect(x: 0, y: 0, width: w, height: h)
        let now = KoalaPerformanceFeed.now(), feed = KoalaPerformanceFeed.shared.snapshot
        sourceLock.lock(); let camera = self.camera, screen = self.screen; sourceLock.unlock()
        let frames = camera?.frames ?? 0
        guard frames != lastFrames || feed.stutterOn != lastStutter || feed.fx != lastFX || now - lastCompose >= 1.0 / 30 else { return }
        lastFrames = frames; lastStutter = feed.stutterOn; lastFX = feed.fx; lastCompose = now
        var picture = CIImage(color: .black).cropped(to: frame)
        var cam = camera?.frame.map { CIImage(cvPixelBuffer: $0) }
        if s.vertical, case let turn = s.rotate ?? 1, turn != 0 { cam = cam?.oriented(turn == 1 ? .right : .left) }
        if s.mirror { cam = cam?.oriented(.upMirrored) }
        let layout = s.layout
        func box(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * frame.width, y: r.minY * frame.height, width: r.width * frame.width, height: r.height * frame.height).integral
        }
        if s.tutorial, let koala = screen?.frame.map({ CIImage(cvPixelBuffer: $0) }) {
            picture = Self.place(koala, in: box(layout.koala), fill: false).composited(over: picture)
        }
        if let cam {
            // A camera that doesn't fill the picture gets a thin border.
            let r = box(layout.camera)
            var placed = Self.place(cam, in: r, fill: true)
            if r.width < frame.width * 0.98, r.height < frame.height * 0.98 {
                placed = placed.composited(over: CIImage(color: CIColor(cgColor: KoalaLook.blue.cgColor)).cropped(to: r.insetBy(dx: -5, dy: -5)))
            }
            picture = placed.composited(over: picture)
        }
        if s.effects {
            let bpm = painter.bpm, sixteenth = 15 / bpm
            var state = WebcamFX.State()
            // Only STUTTER and CUTTER show in the picture. Turned by a knob, the amount sets the rate: a little = 1/4,
            // then 1/8, 1/16, all the way = 1/32. From a button or a touch on Koala: Koala's own repeat length, once heard.
            if feed.stutterOn, let since = feed.stutterSince {
                state.stutter = feed.fx["STUTTER"].map { WebcamFX.division($0, beat: 60 / bpm) }
                    ?? stutterLength.period(since: since, beat: 60 / bpm) ?? sixteenth
                state.stutterStart = since
            }
            if let v = feed.fx["CUTTER"] { state.cutter = WebcamFX.division(v, beat: 60 / bpm); state.cutterStart = feed.cutterSince ?? now }
            picture = fx.process(picture, now: now, state: state, frame: frame)
        }
        if s.overlay, let card = painter.picture(feed: feed, level: level.level, now: now, vertical: s.vertical, frameSize: frame.size, at: layout.card) {
            picture = card.composited(over: picture)
        }
        guard let buffer = renderer.render(picture, width: w, height: h) else { return }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        writerLock.lock(); let writer = self.writer; writerLock.unlock()
        writer?.appendVideo(buffer, at: time)
        if let sample = sampleBuffer(buffer, time) { DispatchQueue.main.async { [weak self] in self?.onPicture?(sample) } }
    }
    private func sampleBuffer(_ buffer: CVPixelBuffer, _ time: CMTime) -> CMSampleBuffer? {
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
            format = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
    /// `image` scaled to fill (cropped) or fit `r`, centred.
    static func place(_ image: CIImage, in r: CGRect, fill: Bool) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let s = fill ? max(r.width / e.width, r.height / e.height) : min(r.width / e.width, r.height / e.height)
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: r.midX - e.width * s / 2, y: r.midY - e.height * s / 2))
            .cropped(to: r)
    }
}
