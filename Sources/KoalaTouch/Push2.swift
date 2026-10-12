// Push 2 User-port MIDI and USB display transport adapted from the archived Paper Picker implementation.
// Control decoding and frame transport are kept separate from Koala actions and screen rendering.
import Foundation
import CoreMIDI
import Push2Display
import IOKit

// Ableton Push 2 as Koala Link's controller and second screen. Everything here follows
// Ableton's published "Push 2 MIDI and Display Interface Manual": the User MIDI port in User mode,
// LEDs by note/CC colour index, a few palette entries (read first, restored on exit) and the
// 960×160 display over USB. Only documented messages are sent.

/// What a Push 2 control did.
enum Push2Event: Equatable {
    /// One of the 64 pads by Push note − 36 (0 = bottom left, 63 = top right).
    case pad(Int, velocity: UInt8, down: Bool)
    /// Polyphonic aftertouch for one Push pad, indexed like `pad`.
    case pressure(Int, value: UInt8)
    case channelPressure(UInt8)
    /// An encoder turned: 0–7 the eight over the display, 8 tempo (left), 9 swing, 10 master.
    case encoder(Int, delta: Int)
    case encoderTouch(Int, down: Bool)
    /// A button by its CC number (see `Push2Button`).
    case button(Int, down: Bool)
    /// The touch strip: 0…1 (pitch bend), and touch/release.
    case strip(Double)
    case stripTouch(Bool)
}

/// Push 2 button CC numbers.
enum Push2Button {
    // The manual's mode prose calls USER a note; its mapping chart and
    // push2-python implementation specify CC59. Do not hijack pad note59.
    static let tapTempo = 3, metronome = 9, master = 28, stop = 29, setup = 30, layout = 31
    static let convert = 35, scenes = 36...43, left = 44, right = 45, up = 46, down = 47
    static let select = 48, shift = 49, note = 50, session = 51, addDevice = 52, addTrack = 53
    static let octaveDown = 54, octaveUp = 55, repeatButton = 56, accent = 57, scale = 58, user = 59
    static let mute = 60, solo = 61, pageLeft = 62, pageRight = 63, play = 85, record = 86
    static let new = 87, duplicate = 88, automate = 89, fixedLength = 90, device = 110
    static let browse = 111, mix = 112, clip = 113, quantize = 116, doubleLoop = 117
    static let delete = 118, undo = 119
    static let upperRow = 102...109, lowerRow = 20...27
    /// Buttons with an RGB LED (the rest are white).
    static func isRGB(_ cc: Int) -> Bool {
        upperRow.contains(cc) || lowerRow.contains(cc) || scenes.contains(cc) || [mute, solo, stop, play, record, automate].contains(cc)
    }
}

/// Decoding of the Push's raw MIDI and the pad layout.
enum Push2Protocol {
    static let sysexHeader: [UInt8] = [0xF0, 0x00, 0x21, 0x1D, 0x01, 0x01]
    static func sysex(_ id: UInt8, _ args: [UInt8]) -> [UInt8] { sysexHeader + [id] + args + [0xF7] }
    /// Set MIDI Mode: 0 Live, 1 User.
    static func midiMode(_ mode: UInt8) -> [UInt8] { sysex(0x0A, [mode]) }
    static func setPalette(_ index: UInt8, _ rgbw: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        let v = [rgbw.0, rgbw.1, rgbw.2, rgbw.3]
        return sysex(0x03, [index] + v.flatMap { [$0 & 0x7F, $0 >> 7] })
    }
    static func getPalette(_ index: UInt8) -> [UInt8] { sysex(0x04, [index]) }
    static let reapplyPalette = sysex(0x05, [])
    /// Push 2 manual: touch-strip configuration flags (0x08 = pitch bend, point LEDs, no autoreturn).
    static func setTouchStripConfiguration(_ flags: UInt8) -> [UInt8] { sysex(0x17, [flags & 0x7F]) }
    static let getTouchStripConfiguration = sysex(0x18, [])
    static let pitchBendTouchStripConfiguration: UInt8 = 0x08
    static func touchStripConfigurationReply(_ bytes: [UInt8]) -> UInt8? {
        guard bytes.count == 9, Array(bytes.prefix(6)) == sysexHeader, bytes[6] == 0x18, bytes[7] < 0x80, bytes[8] == 0xF7 else { return nil }
        return bytes[7]
    }
    /// A palette reply: index and r, g, b, w.
    static func paletteReply(_ bytes: [UInt8]) -> (index: UInt8, rgbw: (UInt8, UInt8, UInt8, UInt8))? {
        guard bytes.count == sysexHeader.count + 11, Array(bytes.prefix(6)) == sysexHeader, bytes[6] == 0x04, bytes.last == 0xF7 else { return nil }
        func v(_ i: Int) -> UInt8 { bytes[8 + i * 2] | (bytes[9 + i * 2] << 7) }
        return (bytes[7], (v(0), v(1), v(2), v(3)))
    }
    /// The 7-bit two's complement step of an encoder: 1…63 right, 64…127 left.
    static func encoderDelta(_ raw: UInt8) -> Int { raw < 64 ? Int(raw) : Int(raw) - 128 }

    /// One channel-voice message in, an event out (nil for anything else).
    static func event(_ m: [UInt8]) -> Push2Event? {
        guard let status = m.first, m.count >= 2 else { return nil }
        let kind = status & 0xF0, d1 = Int(m[1]), d2 = m.count > 2 ? m[2] : 0
        switch kind {
        case 0x90, 0x80:
            let down = kind == 0x90 && d2 > 0
            if (36...99).contains(d1) { return .pad(d1 - 36, velocity: down ? d2 : 0, down: down) }
            if (0...7).contains(d1) { return .encoderTouch(d1, down: down) }
            if d1 == 8 { return .encoderTouch(10, down: down) }
            if d1 == 9 { return .encoderTouch(9, down: down) }
            if d1 == 10 { return .encoderTouch(8, down: down) }
            if d1 == 12 { return .stripTouch(down) }
            return nil
        case 0xA0:
            guard (36...99).contains(d1) else { return nil }
            return .pressure(d1 - 36, value: UInt8(d2))
        case 0xD0: return .channelPressure(m[1])
        case 0xB0:
            if (71...78).contains(d1) { return .encoder(d1 - 71, delta: encoderDelta(d2)) }
            if d1 == 14 { return .encoder(8, delta: encoderDelta(d2)) }
            if d1 == 15 { return .encoder(9, delta: encoderDelta(d2)) }
            if d1 == 79 { return .encoder(10, delta: encoderDelta(d2)) }
            return .button(d1, down: d2 > 0)
        case 0xE0:
            return .strip(Double(Int(m[1]) | Int(d2) << 7) / 16383)
        default:
            return nil
        }
    }

    /// Koala pad (0…63, A01…D16) for a Push pad (note − 36): four 4×4 squares, A bottom left,
    /// B bottom right, C top left, D top right; inside each, pad 1 bottom left like the MPC.
    static func koalaPad(forPush index: Int) -> Int {
        let row = index / 8, col = index % 8
        let bank = (row / 4) * 2 + col / 4
        return bank * 16 + (row % 4) * 4 + col % 4
    }
    static func pushIndex(forKoala pad: Int) -> Int {
        let bank = pad / 16, slot = pad % 16
        let row = (bank / 2) * 4 + slot / 4, col = (bank % 2) * 4 + slot % 4
        return row * 8 + col
    }

    /// RGBA8 (premultiplied, alpha ignored) to the Push's 16-bit pixels: red bits 0–4, green 5–10, blue 11–15.
    static func pixel(r: UInt8, g: UInt8, b: UInt8) -> UInt16 {
        UInt16(r >> 3) | UInt16(g >> 2) << 5 | UInt16(b >> 3) << 11
    }
}

/// The Push's own palette slots Koala Link uses for pads and keys. Their original colours are read
/// first and put back when Push Mode ends, so Live finds the Push as it left it.
enum Push2Color: UInt8, CaseIterable {
    case bankA = 100, bankB, bankC, bankD, dimA, dimB, dimC, dimD, selected, hit, target, chop, chopDim, accent, accentDim, keyOn, playDim, gridMark
    /// Koala Link only (additional palette slots): Koala's four skin highlights, bright and dim.
    case koalaA, koalaB, koalaC, koalaD, koalaDimA, koalaDimB, koalaDimC, koalaDimD
    var rgb: (UInt8, UInt8, UInt8) {
        let pink: (UInt8, UInt8, UInt8) = (255, 40, 99)
        let cyan: (UInt8, UInt8, UInt8) = (0, 203, 234)
        let dimPink: (UInt8, UInt8, UInt8) = (35, 5, 13)
        let dimCyan: (UInt8, UInt8, UInt8) = (0, 27, 31)
        switch self {
        case .bankA, .bankB, .bankC, .bankD, .koalaA, .koalaB, .koalaC, .koalaD, .target, .chop: return cyan
        case .dimA, .dimB, .dimC, .dimD, .koalaDimA, .koalaDimB, .koalaDimC, .koalaDimD, .playDim, .chopDim: return dimCyan
        case .selected, .accent: return pink
        case .accentDim: return dimPink
        case .hit, .keyOn: return (255, 255, 255)
        case .gridMark: return (45, 39, 39)
        }
    }
    static func bank(_ bank: Int, dim: Bool) -> Push2Color {
        Push2Color(rawValue: (dim ? Push2Color.dimA.rawValue : Push2Color.bankA.rawValue) + UInt8(bank % 4))!
    }
    static func koala(_ bank: Int, dim: Bool) -> Push2Color {
        Push2Color(rawValue: (dim ? Push2Color.koalaDimA.rawValue : Push2Color.koalaA.rawValue) + UInt8(bank % 4))!
    }
}

/// The Push 2 itself: MIDI on its User port, LEDs, palette and the display.
final class Push2Device {
    var onEvent: ((Push2Event) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onDisplayStateChanged: ((String) -> Void)?
    private(set) var connected = false
    private(set) var displayState = "DISPLAY: NOT OPEN"
    /// When the Push sent the event being handled (its MIDI timestamp, in seconds of host time): encoder
    /// speed is measured from these, so events reaching the main thread in a burst don't look fast.
    private(set) var eventTime: TimeInterval = 0
    /// The same moment as raw MIDI host time (mach units; 0 when the packet had none), for pad hits.
    private(set) var eventHostTime: UInt64 = 0
    private static let hostTimeScale: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    private var client = MIDIClientRef(), inPort = MIDIPortRef(), outPort = MIDIPortRef()
    private var source = MIDIEndpointRef(), destination = MIDIEndpointRef()
    private var watch: Timer?
    private var padColors = [UInt8?](repeating: nil, count: 64)
    private var buttonValues: [Int: UInt8] = [:]
    private var originalPalette: [UInt8: (UInt8, UInt8, UInt8, UInt8)] = [:]
    private var paletteWaiting: [UInt8: (generation: UInt64, callback: () -> Void)] = [:]
    private var originalTouchStripConfiguration: UInt8?
    private var touchStripWaiting: (generation: UInt64, callback: () -> Void)?
    private var generation: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var running = false
    private let lifecycleLock = NSLock()
    private var sysexBuffer: [UInt8] = []
    private var inSysex = false
    /// Display: frames are encoded and sent on their own queue; one in flight at a time.
    private let displayQueue = DispatchQueue(label: "Koala Link Push 2 display", qos: .userInitiated)
    private var sending = false
    private var lastFrame: [UInt16]?
    private var frameRevision: UInt64 = 0
    private var lastSent = 0.0
    private var lastOpenAttempt = 0.0

    static let portName = "Ableton Push 2 User Port"

    func start() {
        guard client == 0 else { return }
        setRunning(true)
        let runToken = currentRunGeneration
        MIDIClientCreateWithBlock("Koala Link Push 2" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isCurrentRun(runToken) else { return }
                self.refreshEndpoints()
            }
        }
        MIDIInputPortCreateWithProtocol(client, "Koala Link Push 2 In" as CFString, ._1_0, &inPort) { [weak self] list, _ in
            let messages = Self.messages(list)
            DispatchQueue.main.async {
                guard let self, self.isCurrentRun(runToken) else { return }
                messages.forEach { self.eventTime = $0.time ?? ProcessInfo.processInfo.systemUptime; self.eventHostTime = $0.host; self.receive($0.bytes) }
            }
        }
        MIDIOutputPortCreate(client, "Koala Link Push 2 Out" as CFString, &outPort)
        refreshEndpoints()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isCurrentRun(runToken) else { return }
            self.refreshEndpoints()
        }
        RunLoop.main.add(timer, forMode: .common); watch = timer
    }

    /// Lights off, known palette/configuration restored, Live mode, display released.
    func stop() {
        guard client != 0 || running else { return }
        setRunning(false)
        watch?.invalidate(); watch = nil
        paletteWaiting = [:]; touchStripWaiting = nil
        if connected {
            for i in 0..<64 { send([0x90, UInt8(36 + i), 0]) }
            for cc in Array(buttonValues.keys) { send([0xB0, UInt8(cc), 0]) }
            for (index, rgbw) in originalPalette { send(Push2Protocol.setPalette(index, rgbw)) }
            if !originalPalette.isEmpty { send(Push2Protocol.reapplyPalette) }
            if let configuration = originalTouchStripConfiguration {
                send(Push2Protocol.setTouchStripConfiguration(configuration))
            }
            send(Push2Protocol.midiMode(0))
        }
        displayQueue.sync { push2_display_close() }
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        if client != 0 { MIDIClientDispose(client) }
        client = 0; inPort = 0; outPort = 0; source = 0; destination = 0
        connected = false; padColors = .init(repeating: nil, count: 64); buttonValues = [:]
        setDisplayState("DISPLAY: NOT OPEN")
    }

    private func setRunning(_ value: Bool) {
        lifecycleLock.lock(); running = value; generation &+= 1; runGeneration &+= 1; lifecycleLock.unlock()
    }
    private func bumpGeneration() {
        lifecycleLock.lock(); generation &+= 1; lifecycleLock.unlock()
    }
    private func isCurrent(_ token: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return running && generation == token
    }
    private var currentGeneration: UInt64 {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return generation
    }
    private var currentRunGeneration: UInt64 {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return runGeneration
    }
    private func isCurrentRun(_ token: UInt64) -> Bool {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        return running && runGeneration == token
    }

    private func refreshEndpoints() {
        guard running, client != 0 else { return }
        let src = Self.endpoint(named: Self.portName, sources: true), dst = Self.endpoint(named: Self.portName, sources: false)
        if src == source && dst == destination { return }
        bumpGeneration()
        let token = currentGeneration
        paletteWaiting = [:]; touchStripWaiting = nil; sending = false
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        source = src ?? 0; destination = dst ?? 0
        if source != 0 { MIDIPortConnectSource(inPort, source, nil) }
        let now = source != 0 && destination != 0
        padColors = .init(repeating: nil, count: 64); buttonValues = [:]
        if now {
            send(Push2Protocol.midiMode(1))
            PickerLog.write("push 2 · connected, user mode")
            configureTouchStrip(token) { [weak self] in self?.loadPalette(token) }
        } else {
            if connected { PickerLog.write("push 2 · disconnected") }
            displayQueue.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                push2_display_close()
            }
            setDisplayState("DISPLAY: NOT OPEN")
        }
        connected = now
        onConnectionChanged?(now)
    }

    /// Reads original palette entries before changing them; slots without replies stay untouched.
    private func loadPalette(_ token: UInt64) {
        guard isCurrent(token), connected else { return }
        var remaining = Push2Color.allCases.map(\.rawValue).filter { originalPalette[$0] == nil }
        func finish() {
            guard self.isCurrent(token), self.connected else { return }
            for color in Push2Color.allCases {
                guard self.originalPalette[color.rawValue] != nil else { continue }
                self.send(Push2Protocol.setPalette(color.rawValue, (color.rgb.0, color.rgb.1, color.rgb.2, 0)))
            }
            if !self.originalPalette.isEmpty { self.send(Push2Protocol.reapplyPalette) }
        }
        func next() {
            guard self.isCurrent(token), self.connected else { return }
            guard let index = remaining.first else { finish(); return }
            remaining.removeFirst()
            var answered = false
            self.paletteWaiting[index] = (token, {
                guard self.isCurrent(token), !answered else { return }
                answered = true; next()
            })
            self.send(Push2Protocol.getPalette(index))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.isCurrent(token), !answered else { return }
                answered = true
                if self.paletteWaiting[index]?.generation == token { self.paletteWaiting[index] = nil }
                next()
            }
        }
        next()
    }

    /// Do not change strip mode unless its prior documented configuration was captured for restoration.
    private func configureTouchStrip(_ token: UInt64, then completion: @escaping () -> Void) {
        guard isCurrent(token), connected else { return }
        if originalTouchStripConfiguration != nil {
            send(Push2Protocol.setTouchStripConfiguration(Push2Protocol.pitchBendTouchStripConfiguration))
            completion()
            return
        }
        touchStripWaiting = (token, { [weak self] in
            guard let self, self.isCurrent(token), self.connected else { return }
            self.send(Push2Protocol.setTouchStripConfiguration(Push2Protocol.pitchBendTouchStripConfiguration))
            completion()
        })
        send(Push2Protocol.getTouchStripConfiguration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isCurrent(token), self.touchStripWaiting?.generation == token else { return }
            // No reply means we cannot safely change a setting we cannot later restore.
            self.touchStripWaiting = nil
            completion()
        }
    }

    // MARK: MIDI in
    private func receive(_ bytes: [UInt8]) {
        for byte in bytes {
            if byte == 0xF0 { inSysex = true; sysexBuffer = [byte]; continue }
            if inSysex {
                sysexBuffer.append(byte)
                if byte == 0xF7 { inSysex = false; sysex(sysexBuffer) }
                continue
            }
        }
        guard !inSysex, bytes.first != 0xF0, let event = Push2Protocol.event(bytes) else { return }
        onEvent?(event)
    }
    private func sysex(_ bytes: [UInt8]) {
        guard running, connected else { return }
        if let reply = Push2Protocol.paletteReply(bytes) {
            if originalPalette[reply.index] == nil { originalPalette[reply.index] = reply.rgbw }
            guard let waiting = paletteWaiting[reply.index], waiting.generation == currentGeneration else { return }
            paletteWaiting.removeValue(forKey: reply.index)
            waiting.callback()
            return
        }
        if let configuration = Push2Protocol.touchStripConfigurationReply(bytes) {
            if originalTouchStripConfiguration == nil { originalTouchStripConfiguration = configuration }
            guard let waiting = touchStripWaiting, waiting.generation == currentGeneration else { return }
            touchStripWaiting = nil
            waiting.callback()
        }
    }
    private static func messages(_ list: UnsafePointer<MIDIEventList>) -> [(bytes: [UInt8], time: TimeInterval?, host: UInt64)] {
        var out: [(bytes: [UInt8], time: TimeInterval?, host: UInt64)] = []
        for packet in list.unsafeSequence() {
            let stamp = packet.pointee.timeStamp
            let time: TimeInterval? = stamp == 0 ? nil : Double(stamp) * hostTimeScale
            let words = Array(packet.words())
            var i = 0
            while i < words.count {
                let w = words[i], type = w >> 28
                switch type {
                case 0x2:   // MIDI 1.0 channel voice
                    let status = UInt8((w >> 16) & 0xFF), d1 = UInt8((w >> 8) & 0x7F), d2 = UInt8(w & 0x7F)
                    let k = status & 0xF0
                    out.append((k == 0xC0 || k == 0xD0 ? [status, d1] : [status, d1, d2], time, stamp)); i += 1
                case 0x3:   // 7-bit sysex in 64-bit chunks
                    guard i + 1 < words.count else { i = words.count; break }
                    let status = (w >> 20) & 0xF, count = Int((w >> 16) & 0xF)
                    var data: [UInt8] = []
                    let bytes = [UInt8((w >> 8) & 0x7F), UInt8(w & 0x7F), UInt8((words[i + 1] >> 24) & 0x7F),
                                 UInt8((words[i + 1] >> 16) & 0x7F), UInt8((words[i + 1] >> 8) & 0x7F), UInt8(words[i + 1] & 0x7F)]
                    data = Array(bytes.prefix(count))
                    if status == 0 || status == 1 { data.insert(0xF0, at: 0) }
                    if status == 0 || status == 3 { data.append(0xF7) }
                    out.append((data, time, stamp)); i += 2
                default:
                    // Universal MIDI Packet sizes in words, by message type 0x0–0xF (never 0: that loops).
                    i += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(type)]
                }
            }
        }
        return out
    }

    // MARK: MIDI out
    private func send(_ bytes: [UInt8]) {
        guard outPort != 0, destination != 0, !bytes.isEmpty else { return }
        var storage = [UInt8](repeating: 0, count: 1024)
        storage.withUnsafeMutableBytes { raw in
            guard let list = raw.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            let packet = MIDIPacketListInit(list)
            _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, raw.count, packet, 0, $0.count, $0.baseAddress!) }
            MIDISend(outPort, destination, list)
        }
    }
    /// A pad's colour (palette index; 0 = off) by Push pad index; only changes are sent.
    func setPad(_ index: Int, _ color: UInt8) {
        guard connected, (0..<64).contains(index), padColors[index] != color else { return }
        padColors[index] = color
        send([0x90, UInt8(36 + index), color])
    }
    /// A button LED: a palette index for RGB buttons, a brightness (0, 16, 48, 127) for white ones.
    func setButton(_ cc: Int, _ value: UInt8) {
        guard connected, buttonValues[cc] != value else { return }
        buttonValues[cc] = value
        send([0xB0, UInt8(cc), value])
    }

    // MARK: Display
    /// Queues a frame (960×160 Push pixels). Frames are dropped while one is still being sent;
    /// `keepAlive` re-sends the last one so the display doesn't go dark (it blanks after 2 s).
    func show(_ frame: [UInt16]) {
        guard frame.count == PUSH2_WIDTH * PUSH2_HEIGHT else { return }
        lastFrame = frame; frameRevision &+= 1
        pump()
    }
    func keepAlive() {
        if running, ProcessInfo.processInfo.systemUptime - lastSent > 0.5 { pump() }
    }
    private func pump() {
        guard running, connected, !sending, let frame = lastFrame else { return }
        let token = currentGeneration
        let revision = frameRevision
        let now = ProcessInfo.processInfo.systemUptime
        sending = true; lastSent = now
        let mayOpen = now - lastOpenAttempt > 2
        if mayOpen { lastOpenAttempt = now }
        displayQueue.async { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            var state: String?
            if push2_display_is_open() == 0 && mayOpen {
                switch push2_display_open() {
                case 0: state = "DISPLAY: ON"
                case -1: state = "DISPLAY: NOT FOUND ON USB"
                case -2: state = "DISPLAY: IN USE BY ANOTHER APP (CLOSE ABLETON LIVE)"
                default: state = "DISPLAY: COULD NOT OPEN"
                }
            }
            if push2_display_is_open() != 0 {
                let ok = frame.withUnsafeBufferPointer { push2_display_send($0.baseAddress!) } == 0
                if !ok { state = "DISPLAY: LOST, RETRYING" }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                self.sending = false
                if let state { self.setDisplayState(state) }
                // Send the newest replacement as soon as USB is free. The
                // keepalive deadline must not delay a just-rendered waveform.
                if state == nil || state == "DISPLAY: ON", self.frameRevision != revision { self.pump() }
            }
        }
    }

    private func setDisplayState(_ state: String) {
        guard state != displayState else { return }
        displayState = state
        PickerLog.write("push 2 · \(state.lowercased())")
        onDisplayStateChanged?(state)
    }

    private static func endpoint(named name: String, sources: Bool) -> MIDIEndpointRef? {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let e = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            var value: Unmanaged<CFString>?
            guard MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &value) == noErr, let text = value?.takeRetainedValue() as String? else { continue }
            let normalized = text.lowercased()
            guard normalized.contains(name.lowercased()), !normalized.contains("live port") else { continue }
            return e
        }
        return nil
    }
}

/// Whether a Push 2 is plugged in.
enum Push2Present {
    static var onUSB: Bool {
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return false }
        matching["idVendor"] = 0x2982; matching["idProduct"] = 0x1967
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        if device != 0 { IOObjectRelease(device); return true }
        return false
    }
}
