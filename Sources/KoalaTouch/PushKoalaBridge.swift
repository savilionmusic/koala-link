import AppKit
import AVFoundation
import CoreMIDI
import Darwin
import Push2Display

struct KoalaWave: Equatable {
    var peaks: [Float]
    var slices: [Double]
    var start: Double, end: Double
    var duration: Double
    var frames: Double = 0
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
    private var running = false, readyDelivered = false, controlsReady = false
    private var stamps: [String: Date] = [:]
    private let fileQueue = DispatchQueue(label: "KoalaLink.Push.Snapshots", qos: .utility)
    private let audioQueue = DispatchQueue(label: "KoalaLink.Push.Waveforms", qos: .userInitiated)
    private var snapshotPending = false, generation = 0
    // Lengths belong to fileQueue; decoded waveforms and requests belong to the
    // main queue. No PCM decoding blocks snapshot updates or hardware events.
    private var audioLengths: [KoalaAudioSignature: Double] = [:]
    private var waveCache: [KoalaAudioSignature: KoalaWaveformAudio] = [:]
    private var waveToken: KoalaWaveformReadToken?
    private var waveRequested: KoalaAudioSignature?, waveRequestedPad: Int?
    private var waveSignature: KoalaAudioSignature?, wavePad: Int?
    private var waveFailure: (signature: KoalaAudioSignature, until: TimeInterval)?
    private var preloadToken: KoalaWaveformReadToken?
    private var preloadFailures: [KoalaAudioSignature: TimeInterval] = [:]
    private var preloadCandidates: [KoalaAudioSignature] = []
    private var preloadReported: [KoalaAudioSignature] = []
    private var preloadNeedsScan = true, lastPreloadScan = -10.0
    private var folderWatches: [String: (inode: UInt64, source: DispatchSourceFileSystemObject)] = [:]
    private var waveSelectionBegan: TimeInterval?
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
            guard let self, self.running, self.controlsReady else { return }
            let previous = self.controller?.waveformPad
            self.controller?.handle(event)
            if self.controller?.waveformPad != previous { self.waveSelectionBegan = ProcessInfo.processInfo.systemUptime }
            self.refresh()
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
        updateFolderWatches()
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
        fileTimer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.updateFolderWatches(); self?.refreshSnapshot(); self?.refreshWave(checkFile: true)
            self?.preloadNextWave()
        }
        RunLoop.main.add(renderTimer!, forMode: .common); RunLoop.main.add(fileTimer!, forMode: .common)
        if !device.connected { onStatus?("Waiting for Push 2 · connect USB and power") }
    }

    /// Read the restored keyboard state and MIDI channels after Koala's profile
    /// is prepared. Input remains paused until the expected profile is active.
    func prepareForKoalaLaunch() {
        controller?.setSession(KoalaSession.read())
        let keyboard = KoalaPushProfile.keyboardSettings()
        controller?.keyboardChannel = keyboard.channel; controller?.keyboardOffset = keyboard.offset
        controller?.padsSelectInKoala = KoalaPushProfile.canSelectPads()
        controlsReady = KoalaPushProfile.settingsMatch(mode: .push2)
        refresh()
    }

    func stop() {
        guard running || client != 0 else { return }
        running = false; controlsReady = false; generation += 1; snapshotPending = false; stamps = [:]; clockPosition = []
        waveToken?.cancel(); waveToken = nil; waveRequested = nil; waveRequestedPad = nil
        waveSignature = nil; wavePad = nil; waveFailure = nil; waveCache = [:]
        preloadToken?.cancel(); preloadToken = nil; preloadFailures = [:]; waveSelectionBegan = nil
        preloadCandidates = []; preloadReported = []; preloadNeedsScan = true; lastPreloadScan = -10
        for watch in folderWatches.values { watch.source.cancel() }; folderWatches = [:]
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
        KoalaPerformanceFeed.shared.observe(bytes)
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
        refreshWave()
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
        snapshotPending = true
        let token = generation
        let selectionRevision = controller?.selectionRevision
        let trimRevision = controller?.trimRevision
        let commandRevision = controller?.commandRevision ?? 0
        fileQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = KoalaSession.readSaved(frames: { id in
                let url = KoalaSession.folder.appendingPathComponent("sampler/\(id).wav")
                guard let signature = KoalaAudioSignature(url: url) else { return nil }
                if let length = self.audioLengths[signature] { return length }
                guard let audio = try? AVAudioFile(forReading: url) else { return nil }
                let length = Double(audio.length)
                self.audioLengths = self.audioLengths.filter { $0.key.path != signature.path }
                if self.audioLengths.count >= 128 { self.audioLengths.removeAll(keepingCapacity: true) }
                self.audioLengths[signature] = length
                return length
            })
            var after: [String: Date] = [:]
            for name in KoalaSession.files {
                let path = KoalaSession.folder.appendingPathComponent(name).path
                after[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == token else { return }
                self.snapshotPending = false
                guard let snapshot else { return }
                // Do not apply an old/partially written snapshot if Koala saved
                // another selection while the background read was in flight.
                var current: [String: Date] = [:]
                for name in KoalaSession.files {
                    let path = KoalaSession.folder.appendingPathComponent(name).path
                    current[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                }
                guard fresh == after, after == current else { self.refreshSnapshot(force: true); return }
                self.stamps = after
                let samplerPath = KoalaSession.folder.appendingPathComponent("sampler/sampler.json").path
                self.controller?.setSession(snapshot, acceptSelection: self.controller?.selectionRevision == selectionRevision,
                                            samplerSavedAt: after[samplerPath], readTrimRevision: trimRevision,
                                            savedDates: Dictionary(uniqueKeysWithValues: KoalaSession.files.compactMap { name in
                                                after[KoalaSession.folder.appendingPathComponent(name).path].map { (name, $0) }
                                            }), readCommandRevision: commandRevision)
                self.preloadNeedsScan = true
                self.refreshWave(checkFile: true)
                self.refresh()
                self.preloadNextWave()
            }
        }
    }
    private func refreshWave(checkFile: Bool = false) {
        guard running, let controller else { return }
        guard controller.page == .pad else { cancelWaveRead(); return }
        let index = controller.waveformPad
        let pad = controller.padInfo(index)
        guard let id = pad.sampleID else {
            cancelWaveRead()
            waveSignature = nil; wavePad = index; controller.wave = nil
            return
        }
        let url = KoalaSession.folder.appendingPathComponent("sampler/\(id).wav")
        if checkFile || wavePad != index || waveSignature?.path != url.path {
            waveSignature = KoalaAudioSignature(url: url); wavePad = index
        }
        guard let signature = waveSignature else { cancelWaveRead(); controller.wave = nil; return }
        if waveRequested != signature || waveRequestedPad != index { cancelWaveRead() }
        if let cached = waveCache[signature] {
            controller.updateWave(cached, pad: index)
            if let began = waveSelectionBegan {
                PickerLog.write("Push pad \(KoalaController.padID(index)) waveform from cache: \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms")
                waveSelectionBegan = nil
            }
            return
        }
        // A header change must never display the previous sample's waveform.
        controller.wave = nil
        if waveRequested == signature, waveRequestedPad == index { return }
        if let failure = waveFailure, failure.signature == signature, ProcessInfo.processInfo.systemUptime < failure.until { return }
        waveToken?.cancel()
        // A played pad always takes priority over background warming.
        preloadToken?.cancel()
        let readToken = KoalaWaveformReadToken(), runToken = generation
        waveToken = readToken; waveRequested = signature; waveRequestedPad = index
        let began = ProcessInfo.processInfo.systemUptime
        audioQueue.async { [weak self] in
            let audio = KoalaWaveformReader.read(signature, token: readToken)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == runToken, self.waveToken === readToken else { return }
                self.waveToken = nil; self.waveRequested = nil; self.waveRequestedPad = nil
                if let audio {
                    self.cacheWave(audio)
                    self.waveFailure = nil
                    PickerLog.write("Push waveform ready: \(Int(audio.frames)) frames, \(Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) ms; cached")
                } else {
                    self.waveFailure = (signature, ProcessInfo.processInfo.systemUptime + 0.3)
                }
                guard let controller = self.controller, controller.waveformPad == index,
                      controller.padInfo(index).sampleID == id else { return }
                self.refreshWave(checkFile: true); self.refresh()
                self.preloadNextWave()
            }
        }
    }
    private func cancelWaveRead() {
        waveToken?.cancel(); waveToken = nil; waveRequested = nil; waveRequestedPad = nil
    }

    private func cacheWave(_ audio: KoalaWaveformAudio) {
        waveCache = waveCache.filter { $0.key.path != audio.signature.path }
        if waveCache.count >= 128 { waveCache.removeAll(keepingCapacity: true) }
        waveCache[audio.signature] = audio
    }

    /// Paper Cut prepares summaries when a project loads. Do the same for
    /// Koala's saved WAVs, with one cancellable job and no backlog of pad work.
    private func preloadNextWave() {
        guard running, let controller, preloadToken == nil, waveToken == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        preloadFailures = preloadFailures.filter { $0.value > now }
        if preloadNeedsScan || now - lastPreloadScan > 2 {
            let ids = Set(controller.session.pads.values.compactMap(\.sampleID)).sorted()
            preloadCandidates = ids.compactMap { id in
                KoalaAudioSignature(url: KoalaSession.folder.appendingPathComponent("sampler/\(id).wav"))
            }
            let live = Set(preloadCandidates)
            waveCache = waveCache.filter { live.contains($0.key) }
            preloadNeedsScan = false; lastPreloadScan = now
        }
        guard let signature = preloadCandidates.first(where: { waveCache[$0] == nil && preloadFailures[$0] == nil }) else {
            if !preloadCandidates.isEmpty, preloadCandidates != preloadReported,
               preloadCandidates.allSatisfy({ waveCache[$0] != nil }) {
                preloadReported = preloadCandidates
                PickerLog.write("Push waveform cache warm: \(preloadCandidates.count) saved samples ready")
            }
            return
        }
        let token = KoalaWaveformReadToken(), runToken = generation
        preloadToken = token
        audioQueue.async {
            let audio = KoalaWaveformReader.read(signature, token: token)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == runToken, self.preloadToken === token else { return }
                self.preloadToken = nil
                if !token.cancelled {
                    if let audio, KoalaAudioSignature(url: URL(fileURLWithPath: signature.path)) == signature {
                        self.cacheWave(audio)
                        self.refreshWave(); self.refresh()
                    } else { self.preloadFailures[signature] = ProcessInfo.processInfo.systemUptime + 1 }
                }
                self.preloadNextWave()
            }
        }
    }

    /// Directory notifications catch atomic JSON/WAV replacement as soon as
    /// Koala saves. Polling remains a fallback when it replaces a whole folder.
    private func updateFolderWatches() {
        guard running else { return }
        for url in [KoalaSession.folder, KoalaSession.folder.appendingPathComponent("sampler")] {
            let path = url.path
            let inode = ((try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber]) as? NSNumber)?.uint64Value
            if let watch = folderWatches[path], watch.inode == inode { continue }
            folderWatches.removeValue(forKey: path)?.source.cancel()
            guard let inode else { continue }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let self, self.running else { return }
                self.preloadNeedsScan = true
                self.refreshSnapshot(); self.refreshWave(checkFile: true); self.refresh(); self.preloadNextWave()
            }
            folderWatches[path] = (inode, source)
            source.resume()
        }
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
