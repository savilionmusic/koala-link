import AVFoundation
import CoreAudio

/// Koala's sound through a Core Audio process tap (macOS 14.2+), in a private aggregate device with the output you
/// listen on. With LISTEN on, the tap mutes Koala's own (dry) sound and the IO cycle plays the processed sound out of
/// the same output in its place, one buffer later: the signal is switched, never doubled. With LISTEN off Koala plays
/// as normal and the tap only records. Needs Screen & System Audio Recording (System Audio Recording Only is enough).
@available(macOS 14.2, *)
final class KoalaAudioTap {
    /// Each block of Koala's sound (host-clock stamped); returns the processed block to play when listening.
    var onAudio: ((CMSampleBuffer) -> CMSampleBuffer?)?
    private var tap = AudioObjectID(kAudioObjectUnknown), aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let listen: Bool
    private var format: CMAudioFormatDescription?
    private var tapBuffers = 1
    private let queue = DispatchQueue(label: "Koala Link audio tap", qos: .userInteractive)

    init(pid: pid_t, listen: Bool, outputUID: String?) throws {
        self.listen = listen
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var process = pid, object = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &process, &size, &object) == noErr,
              object != kAudioObjectUnknown else { throw Self.failure("Koala isn't playing sound yet. Play a pad, then open Webcam again.") }
        let description = CATapDescription(stereoMixdownOfProcesses: [object])
        description.uuid = UUID(); description.isPrivate = true; description.name = "Koala Link webcam"
        description.muteBehavior = listen ? .mutedWhenTapped : .unmuted
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { throw Self.failure(KoalaScreenCapture.permission) }

        var asbd = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        address.mSelector = kAudioTapPropertyFormat
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr,
              CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                             extensions: nil, formatDescriptionOut: &format) == noErr else { stop(); throw Self.failure("Can't read Koala's sound format") }
        tapBuffers = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? Int(asbd.mChannelsPerFrame) : 1

        let output = outputUID ?? Self.defaultOutputUID() ?? ""
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koala Link webcam", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate) == noErr else { stop(); throw Self.failure("Can't open the sound output for LISTEN") }
        guard AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, { [weak self] _, input, time, output, _ in
            self?.cycle(input, time, output)
        }) == noErr, AudioDeviceStart(aggregate, proc) == noErr else { stop(); throw Self.failure("Can't start Koala's sound capture") }
    }

    func stop() {
        if let proc, aggregate != kAudioObjectUnknown { AudioDeviceStop(aggregate, proc); AudioDeviceDestroyIOProcID(aggregate, proc) }
        proc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = AudioObjectID(kAudioObjectUnknown) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown) }
    }
    deinit { stop() }

    private func cycle(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>, _ output: UnsafeMutablePointer<AudioBufferList>) {
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for b in outs { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
        // The tap's buffers come after any inputs of the output device.
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let format, ins.count >= tapBuffers else { return }
        let first = ins.count - tapBuffers
        let tapList = AudioBufferList.allocate(maximumBuffers: tapBuffers); defer { free(tapList.unsafeMutablePointer) }
        for i in 0..<tapBuffers { tapList[i] = ins[first + i] }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mBytesPerFrame > 0 else { return }
        let frames = Int(tapList[0].mDataByteSize / asbd.mBytesPerFrame)
        guard frames > 0 else { return }
        var sample: CMSampleBuffer?
        let pts = CMClockMakeHostTimeFromSystemUnits(time.pointee.mHostTime)
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                                              formatDescription: format, sampleCount: frames, presentationTimeStamp: pts,
                                                              packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: tapList.unsafePointer) == noErr else { return }
        guard let processed = onAudio?(sample), listen else { return }
        // Play the processed sound into the output's first two channels.
        let back = AudioBufferList.allocate(maximumBuffers: tapBuffers); defer { free(back.unsafeMutablePointer) }
        let bytes = frames * Int(asbd.mBytesPerFrame)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: bytes * tapBuffers, alignment: 16); defer { storage.deallocate() }
        for i in 0..<tapBuffers {
            back[i] = AudioBuffer(mNumberChannels: tapBuffers == 1 ? asbd.mChannelsPerFrame : 1, mDataByteSize: UInt32(bytes), mData: storage.advanced(by: i * bytes))
        }
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(processed, at: 0, frameCount: Int32(frames), into: back.unsafeMutablePointer) == noErr else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        func source(_ frame: Int, _ ch: Int) -> Float {
            let c = min(ch, channels - 1)
            if tapBuffers == 1 { return back[0].mData!.assumingMemoryBound(to: Float.self)[frame * channels + c] }
            return back[c].mData!.assumingMemoryBound(to: Float.self)[frame]
        }
        var channel = 0
        for b in outs where channel < 2 {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(b.mNumberChannels), outFrames = min(frames, Int(b.mDataByteSize) / 4 / max(1, count))
            for c in 0..<count where channel + c < 2 {
                for f in 0..<outFrames { data[f * count + c] = source(f, channel + c) }
            }
            channel += count
        }
    }

    static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString; size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "KoalaLink.AudioTap", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
