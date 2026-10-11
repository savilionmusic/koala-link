import AppKit
import AVFoundation
import CoreMIDI
import Push2Display

struct KoalaWave: Equatable {
    var peaks: [Float]
    var slices: [Double]
    var start: Double, end: Double
    var duration: Double
}

/// Push owns its User port; Koala receives translated input from a separate
/// virtual source. Saved song data is labelled as a snapshot, never live audio.
final class PushKoalaBridge {
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onChooseController: (() -> Void)?
    var onQuit: (() -> Void)?
    private let device = Push2Device()
    private let canvas = KoalaPushCanvas()
    private var client = MIDIClientRef(), source = MIDIEndpointRef(), destination = MIDIEndpointRef()
    private var renderTimer: Timer?, fileTimer: Timer?, performanceTimer: Timer?
    private var controller: KoalaController?
    private var lastView: KoalaView?
    private var running = false, readyDelivered = false
    private var stamps: [String: Date] = [:]
    private let fileQueue = DispatchQueue(label: "KoalaLink.Push.Snapshots", qos: .utility)
    private var snapshotPending = false, generation = 0
    private var preview: NSWindow?
    private let previewView = KoalaPushPreviewView(frame: NSRect(x: 0, y: 0, width: 960, height: 160))

    func start() throws {
        guard !running else { if device.connected { onReady?() }; return }
        generation += 1; let runToken = generation
        try check(MIDIClientCreate("Koala Link Push" as CFString, nil, nil, &client))
        do {
            try check(MIDISourceCreate(client, "Koala Link Push" as CFString, &source))
            try check(MIDIDestinationCreateWithBlock(client, "Koala Link Push" as CFString, &destination) { [weak self] list, _ in
                let bytes = Self.packetBytes(list)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == runToken else { return }; self.receiveClock(bytes)
                }
            })
        } catch { dispose(); throw error }
        running = true
        let control = KoalaController { [weak self] in self?.publish($0) }
        control.onQuit = { [weak self] in self?.onQuit?() }
        control.onChooseController = { [weak self] in self?.onChooseController?() }
        controller = control
        device.onEvent = { [weak self] event in
            guard let self, self.running else { return }
            self.controller?.handle(event); self.refresh()
        }
        device.onConnectionChanged = { [weak self] connected in
            guard let self, self.running else { return }
            if !connected { self.controller?.releaseAll(); self.readyDelivered = false }
            self.onStatus?(connected ? "Push 2 connected · preparing Koala" : "Waiting for Push 2 · connect USB and power")
            if connected, !self.readyDelivered { self.readyDelivered = true; self.onReady?() }
            self.lastView = nil; self.refresh()
        }
        device.onDisplayStateChanged = { [weak self] state in self?.onStatus?(state) }
        showPreview()
        refreshSnapshot(force: true)
        device.start()
        renderTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }
            self.refresh(); self.device.keepAlive()
        }
        performanceTimer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in
            guard let self, self.running else { return }; self.controller?.tick()
        }
        RunLoop.main.add(performanceTimer!, forMode: .common)
        fileTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshSnapshot() }
        RunLoop.main.add(renderTimer!, forMode: .common); RunLoop.main.add(fileTimer!, forMode: .common)
        if !device.connected { onStatus?("Waiting for Push 2 · connect USB and power") }
    }

    /// Read the restored keyboard state before Koala launches. Later reads are
    /// autosaved snapshots; they only update fields whose saved values changed.
    func prepareForKoalaLaunch() {
        controller?.setSession(KoalaSession.read())
        let keyboard = KoalaPushProfile.keyboardSettings()
        controller?.keyboardChannel = keyboard.channel; controller?.keyboardOffset = keyboard.offset
    }

    func stop() {
        guard running || client != 0 else { return }
        running = false; generation += 1; snapshotPending = false; stamps = [:]; clockPosition = []
        renderTimer?.invalidate(); fileTimer?.invalidate(); performanceTimer?.invalidate(); renderTimer = nil; fileTimer = nil; performanceTimer = nil
        controller?.releaseAll(); controller = nil
        device.onEvent = nil; device.onConnectionChanged = nil; device.onDisplayStateChanged = nil; device.stop()
        dispose(); preview?.close(); preview = nil; lastView = nil
    }
    private func dispose() {
        if source != 0 { MIDIEndpointDispose(source) }; if destination != 0 { MIDIEndpointDispose(destination) }
        if client != 0 { MIDIClientDispose(client) }
        source = 0; destination = 0; client = 0
    }
    private func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: "KoalaLink.Push", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Push MIDI setup failed (\(status))"]) }
    }
    private func publish(_ bytes: [UInt8]) {
        guard source != 0, !bytes.isEmpty else { return }
        var storage = [UInt8](repeating: 0, count: max(1024, bytes.count + 64))
        storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
            let packet = MIDIPacketListInit(list)
            _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, raw.count, packet, 0, $0.count, $0.baseAddress!) }
            MIDIReceived(source, list)
        }
    }
    private static func packetBytes(_ list: UnsafePointer<MIDIPacketList>) -> [UInt8] {
        var bytes: [UInt8] = []
        let offset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        var packet = UnsafeMutablePointer(mutating: UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self))
        for _ in 0..<Int(list.pointee.numPackets) {
            let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
            bytes += UnsafeBufferPointer(start: data, count: Int(packet.pointee.length))
            packet = MIDIPacketNext(packet)
        }
        return bytes
    }
    private var clockPosition: [UInt8] = []
    private func receiveClock(_ bytes: [UInt8]) {
        guard running else { return }
        for b in bytes {
            if b >= 0xF8 { controller?.clock(b, [], at: ProcessInfo.processInfo.systemUptime) }
            else if b == 0xF2 { clockPosition = [b] }
            else if b & 0x80 != 0 { clockPosition = [] }
            else if !clockPosition.isEmpty {
                clockPosition.append(b)
                if clockPosition.count == 3 { controller?.clock(0xF2, Array(clockPosition.dropFirst()), at: ProcessInfo.processInfo.systemUptime); clockPosition = [] }
            }
        }
    }
    private func refresh() {
        guard running, let controller else { return }
        for (i, color) in controller.padColors().enumerated() { device.setPad(i, color) }
        for (cc, value) in controller.buttonLights() { device.setButton(cc, value) }
        var view = controller.view()
        if !device.connected {
            view.status = "PUSH 2 DISCONNECTED"
            view.message = "CONNECT USB AND POWER"
        }
        guard view != lastView else { return }
        lastView = view; previewView.model = view
        device.show(canvas.pixels { KoalaScreenArt.draw(view, in: $0) })
    }
    private func refreshSnapshot(force: Bool = false) {
        guard running, !snapshotPending else { return }
        var fresh: [String: Date] = [:]
        for name in KoalaSession.files {
            let path = KoalaSession.folder.appendingPathComponent(name).path
            fresh[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        }
        guard force || fresh != stamps else { return }
        stamps = fresh; snapshotPending = true
        let token = generation
        fileQueue.async { [weak self] in
            guard let self else { return }
            var waves: [Int: KoalaWave] = [:]
            let snapshot = KoalaSession.read(frames: { id in
                guard let audio = try? AVAudioFile(forReading: KoalaSession.folder.appendingPathComponent("sampler/\(id).wav")) else { return nil }
                return Double(audio.length)
            })
            if let selected = snapshot.selectedPad, let pad = snapshot.pads[selected], let id = pad.sampleID,
               let wave = Self.readWave(id: id, pad: pad) { waves[id] = wave }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.snapshotPending = false
                self.controller?.setSession(snapshot)
                self.controller?.wave = snapshot.selectedPad.flatMap { snapshot.pads[$0]?.sampleID }.flatMap { waves[$0] }
                self.refresh()
            }
        }
    }
    private static func readWave(id: Int, pad: KoalaSession.Pad) -> KoalaWave? {
        guard let file = try? AVAudioFile(forReading: KoalaSession.folder.appendingPathComponent("sampler/\(id).wav")), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return nil }
        let count = 960, length = Double(file.length)
        var peaks = [Float](repeating: 0, count: count)
        // Bound the work for long recordings: sample each display column rather
        // than read an entire song on the UI thread.
        for column in 0..<count {
            file.framePosition = AVAudioFramePosition(Double(column) * length / Double(count))
            let remaining = file.length - file.framePosition
            let amount = AVAudioFrameCount(min(256, remaining))
            guard amount > 0, (try? file.read(into: buffer, frameCount: amount)) != nil, let data = buffer.floatChannelData else { continue }
            var peak: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) { for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][i])) } }
            peaks[column] = min(1, peak)
        }
        return KoalaWave(peaks: peaks, slices: pad.slices.map { $0 / length }, start: pad.start / length,
                         end: min(1, (pad.end ?? length) / length), duration: length / file.processingFormat.sampleRate)
    }
    private func showPreview() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 160), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Koala Link · Push 2 · Saved song / local control view"
        window.isReleasedWhenClosed = false; window.contentView = previewView; window.center(); window.orderFront(nil)
        preview = window
    }
}

final class KoalaPushPreviewView: NSView {
    var model = KoalaView() { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState(); cg.scaleBy(x: bounds.width / 960, y: bounds.height / 160)
        KoalaScreenArt.draw(model, in: NSRect(x: 0, y: 0, width: 960, height: 160)); cg.restoreGState()
    }
}

final class KoalaPushCanvas {
    private let context = CGContext(data: nil, width: 960, height: 160, bitsPerComponent: 8, bytesPerRow: 3840,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    private func draw(_ body: (NSRect) -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        body(NSRect(x: 0, y: 0, width: 960, height: 160)); context.flush(); NSGraphicsContext.current = previous
    }
    func pixels(_ body: (NSRect) -> Void) -> [UInt16] {
        draw(body); var output = [UInt16](repeating: 0, count: 960 * 160)
        output.withUnsafeMutableBufferPointer { push2_convert_rgba(context.data!.assumingMemoryBound(to: UInt8.self), $0.baseAddress!, Int32(960 * 160)) }
        return output
    }
    func png(_ body: (NSRect) -> Void) -> Data? {
        draw(body); guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
