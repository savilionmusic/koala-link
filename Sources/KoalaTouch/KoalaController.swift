import AppKit

// Koala on the Push 2, kept simple: make the controller, then map it.
// - The controller (this file): Push controls use Koala MIDI addresses or companion actions; the screen
//   and lights show what the controls do and what is going on, the way the Push shows Live.
// - The map (KoalaMap.swift): Koala's MIDI map gets the same keys for the same addresses, written while Koala is closed.
// Koala sends back only its MIDI clock. So the screen shows what the Push sent, Koala's clock (playing, bar, tempo) and
// what Koala's files say (pad names, choppers, the selected pad, starting knob values; Koala writes them at autosave).
// Nothing is captured from the screen or clicked.

final class KoalaController {
    enum Page: Int, CaseIterable { case pad, eq, fx, mixer, seq }
    static let upperLabels = ["PAD", "EQ", "FX", "MIXER", "SEQ", "KEYBOARD", "LOAD", "SETTINGS"]
    /// Koala's keyboard mode as the Push follows it: off, Koala choosing a pad (its CHOOSE…), or on a pad.
    enum Keyboard: Equatable { case off, choosing, on(Int) }

    /// The controller's table: Koala address → the MIDI the Push sends for it. The map writes the same keys into Koala.
    static let table: [String: KoalaKey] = Dictionary(KoalaPushProfile.canonicalMap.map { ($0.address, $0.key) }, uniquingKeysWith: { a, _ in a })
    /// Koala's buttons ignore velocity, but in keyboard mode Koala also plays every note as a key: velocity 1 keeps
    /// that stray key all but silent.
    static let buttonVelocity: UInt8 = 1
    /// Keyboard mode on a chopper: note 60 = chop 1 (tested on Koala).
    static let chopOneNote = 60
    /// Shorter than this an effect press is a tap (latches on or off); longer, the effect lasts only while held.
    static let tapLatch = 0.35

    var send: ([UInt8]) -> Void
    /// SHIFT + USER, twice: quit Koala and its companion.
    var onQuit: (() -> Void)?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Koala's Keyboard Mode MIDI channel (keys go out on it) and the note of 16 Levels key 1 (key 25 = note 60, the
    /// pad's own pitch).
    var keyboardChannel = 16, keyboardOffset = 36

    private(set) var session = KoalaSession()
    private(set) var page: Page = .pad
    /// Koala's selected pad (its file): what the pad knobs and keys edit. Pad hits don't select pads in Koala ("MIDI can
    /// select pads" is off, so keyboard mode stays on its pad).
    private(set) var selected = 0
    private(set) var keyboard: Keyboard = .off
    /// 16 Levels: how far OCTAVE ▲▼ moved the keys, in semitones.
    private(set) var octave = 0
    private(set) var chopPage = 0
    private(set) var fullLevel = false
    private(set) var repeatEnabled = false
    private(set) var detailView = true
    private var chopCountOverride: Int?
    private var pressedButtons = Set<Int>()
    private var heldPadOns: [Int: [UInt8]] = [:]
    private var nextRepeat = 0.0
    private var localPlaying = false
    private var localRecording = false
    var wave: KoalaWave?
    var onChooseController: (() -> Void)?

    // Companion macros record CC movement, never destructive buttons or pad notes.
    private struct MacroPoint { var time: Double; var bytes: [UInt8] }
    private var macro: [MacroPoint] = []
    private var macroRecording = false, macroPlaying = false, applyingMacro = false
    private var macroStarted = 0.0, macroLength = 0.0, macroCursor = 0
    private var macroPad = 0
    private(set) var sequenceBank = 0
    private(set) var shift = false
    private var soloHeld = false
    private var sessionRead = false
    /// What the Push holds down: Push pad → its release; button → its release; lower-row keys down.
    private var heldPads: [Int: [UInt8]] = [:]
    private var heldButtons: [Int: [UInt8]] = [:]
    private var lowerDown: Set<Int> = []
    /// Knob positions (0…127) by address (per pad for /currPad/), and what was sent.
    private var positions: [String: Double] = [:], remainder: [String: Int] = [:], lastSent: [String: Int] = [:]
    private var touched: Int?
    /// On/off switches the Push flipped since Koala last wrote its files, and the sequence it picked.
    private var flipped: [String: Bool] = [:]
    private var sequencePicked: Int?
    /// Effects (by place in `session.fx`): which are on at what amount (0–127), the one the strip sets, each one's
    /// amount for next time, and the buttons pressing them now.
    private(set) var fxOn: [Int: Int] = [:]
    private(set) var fxSelected: Int?
    private var fxAmount: [Int: Double] = [:]
    private enum FXPress { case turnedOn, selectedOnly, wasSelectedOn }
    private var fxPress: [Int: (fx: Int, at: TimeInterval, kind: FXPress)] = [:]
    private var stripHeld = false
    private var stripTarget: Knob?, stripAnchor: Double?
    private var stripStart = 0.0
    private var fxDirty = Set<Int>(), ownedFX = Set<Int>()
    /// Koala's MIDI clock.
    private enum Transport { case unknown, running, stopped }
    private var transport = Transport.unknown, ticks = 0, lastTick = -10.0, tickTimes: [TimeInterval] = []
    /// The status line: the last thing done, for a few seconds.
    private var message = "", messageUntil = -10.0
    private var quitArmedAt = -10.0

    // MARK: Koala's SP-404MKII link (KoalaFeedbackProtocol.swift)
    /// Sends a link payload to Koala (framed by the picker). Nil: no link port.
    var sendLink: (([UInt8]) -> Void)?
    /// What the link learns, for the log (new pad light codes, connect).
    var onLinkNews: ((String) -> Void)?
    /// Koala greeted the link: it answers with its own state, and takes per-pad edits that name the pad.
    private(set) var link = false
    enum KoalaPage: Equatable { case sample, sequence, perform }
    /// Koala's own bank and page, and every pad's light, as Koala reports them over the link.
    private(set) var koalaBank: Int?
    private(set) var koalaPage = KoalaPage.sample
    private(set) var padStates = [UInt8?](repeating: nil, count: 64)
    private(set) var leds: [UInt8: UInt8] = [:]
    private var seenStates: Set<UInt8> = []
    /// With the link: the pad the PAD page edits, the last one hit (Koala's selected pad until then).
    private var lastHit: Int?
    var editPad: Int { link ? (lastHit ?? selected) : selected }
    /// The PAD page knobs the link sets on `editPad` (the rest still act on Koala's selected pad through the map).
    static let linkKnobs: [String: UInt8] = [
        "/currPad/volume": KoalaFeedbackProtocol.volume, "/currPad/pitch": KoalaFeedbackProtocol.pitch, "/currPad/pan": KoalaFeedbackProtocol.pan,
        "/currPad/sample/ampEnvelope/attack": KoalaFeedbackProtocol.attack, "/currPad/sample/ampEnvelope/release": KoalaFeedbackProtocol.release,
        "/currPad/sample/tone": KoalaFeedbackProtocol.tone,
    ]
    /// The pad a /currPad/ address acts on.
    func padFor(_ address: String) -> Int { link && Self.linkKnobs[address] != nil ? editPad : selected }

    init(send: @escaping ([UInt8]) -> Void) { self.send = send }

    private func linkSend(_ payload: [UInt8]) { if link { sendLink?(payload) } }
    /// One message from Koala over the link (its payload).
    func linkReceived(_ payload: [UInt8]) {
        guard let code = payload.first else { return }
        switch code {
        case 0x00:
            if !link { link = true; onLinkNews?("connected: Koala answers as with an SP-404MKII") }
        case 0x02 where payload.count >= 4:
            let pad = Int(payload[1]) * 16 + Int(payload[2])
            guard (0..<64).contains(pad) else { return }
            padStates[pad] = payload[3]
            if seenStates.insert(payload[3]).inserted { onLinkNews?(String(format: "pad light %02X first seen on %@ (Koala page %@)", payload[3], Self.padID(pad), "\(koalaPage)")) }
        case 0x03 where payload.count >= 2:
            koalaBank = Int(payload[1])
        case KoalaFeedbackProtocol.controller where payload.count >= 5:
            leds[payload[3]] = payload[4]
            // Koala's page from its page lights as they change (seen live: SEQUENCE lights on its SEQUENCE page and goes
            // off on SAMPLE; PERFORM lights on PERFORM, but isn't switched off when Koala leaves it).
            switch (payload[3], payload[4]) {
            case (KoalaFeedbackProtocol.patternSelect, KoalaFeedbackProtocol.pressed): koalaMoved(to: .sequence)
            case (KoalaFeedbackProtocol.perform, KoalaFeedbackProtocol.pressed): koalaMoved(to: .perform)
            case (KoalaFeedbackProtocol.patternSelect, 0): koalaMoved(to: .sample)
            case (KoalaFeedbackProtocol.perform, 0) where koalaPage == .perform: koalaMoved(to: .sample)
            default: break
            }
        default: break
        }
        if !link, code != 0x00 { link = true; onLinkNews?("connected (Koala sent its state)") }
    }
    /// The page the Push just sent Koala to: until Koala gets there (or 1 s passes), its lights are only echoes.
    private var steering: (page: KoalaPage, until: TimeInterval)?
    /// Koala reports a page; the Push follows it when Koala moved on its own (a tap on Koala's screen).
    private func koalaMoved(to new: KoalaPage) {
        if let steer = steering, now() < steer.until {
            koalaPage = new
            if new == steer.page { steering = nil }
            return
        }
        steering = nil
        guard new != koalaPage else { return }
        koalaPage = new
        switch new {
        case .sequence where page != .seq: page = .seq; touched = nil
        case .perform where page != .fx: page = .fx; touched = nil
        case .sample where page == .seq || page == .fx: page = .pad; touched = nil
        default: break
        }
    }
    /// Koala to its SAMPLE page: SEQUENCE is let go (from SEQUENCE), or pressed and let go (from PERFORM).
    private func koalaToSample() {
        switch koalaPage {
        case .sample: break
        case .sequence: linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.patternSelect, 0))
        case .perform: linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.patternSelect, KoalaFeedbackProtocol.pressed)); linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.patternSelect, 0))
        }
    }

    static func padID(_ pad: Int) -> String { "\(["A", "B", "C", "D"][max(0, min(3, pad / 16))])\(pad % 16 + 1)" }
    private func padInfo(_ pad: Int) -> KoalaSession.Pad { session.pads[pad] ?? KoalaSession.Pad() }
    /// A chopper's chop count (0: not a chopper, or not chopped yet).
    func chops(_ pad: Int) -> Int { padInfo(pad).chopper ? max(1, min(128, chopCountOverride ?? padInfo(pad).slices.count)) : 0 }
    private func say(_ text: String, seconds: Double = 2.5) { message = text; messageUntil = now() + seconds }
    /// A message on the Push screen's status line.
    func announce(_ text: String, seconds: Double = 10) { say(text, seconds: seconds) }

    // MARK: Koala's files and clock
    func setSession(_ new: KoalaSession) {
        let first = !sessionRead, old = session
        sessionRead = true
        session = new
        if first || old.name != new.name {
            flipped = [:]; positions = [:]; lastSent = [:]; remainder = [:]
            sequencePicked = nil; fxDirty = []; ownedFX = []; chopPage = 0; chopCountOverride = nil; macroPlaying = false; macroRecording = false
        } else {
            func savedFlag(_ flag: String, _ snapshot: KoalaSession) -> Bool? {
                let parts = flag.split(separator: "#")
                if parts.count == 2, let pad = Int(parts[1]), let info = snapshot.pads[pad] {
                    switch parts[0] {
                    case "oneshot": return info.oneShot
                    case "loop": return info.loop
                    case "reverse": return info.reverse
                    case "mute": return info.muted
                    default: return nil
                    }
                }
                if flag == "quantize" { return snapshot.quantizing }
                if flag == "mute.main" { return snapshot.mainMute }
                if let i = Int(flag.split(separator: ".").last ?? ""), (0..<4).contains(i) {
                    if flag.hasPrefix("mute.") { return snapshot.busMute[i] }
                    if flag.hasPrefix("solo.") { return snapshot.busSolo[i] }
                }
                return nil
            }
            for (flag, value) in flipped {
                if savedFlag(flag, new) == value || savedFlag(flag, old) != savedFlag(flag, new) { flipped[flag] = nil }
            }
            if sequencePicked == new.sequence || old.sequence != new.sequence { sequencePicked = nil }
            // Drop local estimates only when Koala's saved field changes. An
            // unchanged autosave is not acknowledgement of a recent movement.
            for address in Self.table.keys {
                let current = initialPosition(address)
                session = old; let previous = initialPosition(address); session = new
                if current != previous { positions[memoryKey(address)] = nil; lastSent[memoryKey(address)] = nil }
            }
        }
        for i in new.fx.indices where new.fxValues.indices.contains(i) {
            let value = max(0, min(127, Int((new.fxValues[i] * 127).rounded())))
            let changed = !old.fxValues.indices.contains(i) || old.fxValues[i] != new.fxValues[i] || old.fx != new.fx
            if first || changed || !fxDirty.contains(i) {
                if !fxPress.values.contains(where: { $0.fx == i }) { fxOn[i] = value > 0 ? value : nil }
                if changed { fxDirty.remove(i) }
            }
        }
        if let s = new.selectedPad, (0..<64).contains(s), s != old.selectedPad || first {
            selected = s; chopPage = 0; chopCountOverride = nil
            // Koala's keyboard pad moved (a tap on Koala's screen): the pads follow it.
            if case .on = keyboard, new.keyboard { keyboard = .on(s); octave = 0 }
        }
        // Keyboard mode, when the file changes it (an unchanged value says nothing about a toggle since).
        if first || new.keyboard != old.keyboard {
            if new.keyboard { keyboard = .on(selected) } else if keyboard != .choosing { keyboard = .off }
        }
    }
    /// Koala's MIDI clock (with Koala's Midi Clock mode on SEND): start, continue, stop, song position, ticks.
    func clock(_ status: UInt8, _ data: [UInt8], at time: TimeInterval) {
        switch status {
        case 0xFA: transport = .running; ticks = 0; tickTimes = []
        case 0xFB: transport = .running
        case 0xFC: transport = .stopped
        case 0xF2 where data.count == 2: ticks = (Int(data[0]) | Int(data[1]) << 7) * 6
        case 0xF8:
            if transport != .stopped { ticks += 1 }
            lastTick = time
            tickTimes.append(time)
            if tickTimes.count > 49 { tickTimes.removeFirst(tickTimes.count - 49) }
        default: break
        }
    }
    var playing: Bool { transport == .unknown ? localPlaying : transport != .stopped && now() - lastTick < 0.5 }
    /// Koala's tempo from its clock (24 ticks a beat) while it runs; else its file's.
    var bpm: Double? {
        if now() - lastTick < 0.5, tickTimes.count >= 25, let a = tickTimes.first, let b = tickTimes.last, b > a {
            return 60 / ((b - a) / Double(tickTimes.count - 1) * 24)
        }
        return session.bpm
    }

    // MARK: Knobs
    /// How a knob reads: a level (%), around a middle (±), pan, a list, a ± pair of buttons, or Koala's units on its
    /// estimated scale (Hz on a log sweep 20 Hz–20 kHz, dB or semitones either side of 0).
    enum Kind: Equatable { case level, bipolar, pan, steps([String]), relative(up: String, down: String), hertz, decibels(Double), semitones(Double) }
    struct Knob: Equatable { var name: String, address: String, kind: Kind }
    static let padKnobs = [
        Knob(name: "VOLUME", address: "/currPad/volume", kind: .level), Knob(name: "PAN", address: "/currPad/pan", kind: .pan),
        Knob(name: "PITCH", address: "/currPad/pitch", kind: .semitones(24)), Knob(name: "TONE", address: "/currPad/sample/tone", kind: .bipolar),
        Knob(name: "ATTACK", address: "/currPad/sample/ampEnvelope/attack", kind: .level),
        Knob(name: "RELEASE", address: "/currPad/sample/ampEnvelope/release", kind: .level),
        Knob(name: "START", address: "/currPad/sample/start", kind: .level), Knob(name: "LENGTH", address: "/currPad/sample/length", kind: .level),
    ]
    static let eqKnobs = [
        Knob(name: "LOW FREQ", address: "/currPad/eq/band0/freq", kind: .hertz), Knob(name: "LOW GAIN", address: "/currPad/eq/band0/gain", kind: .decibels(18)),
        Knob(name: "MID FREQ", address: "/currPad/eq/band1/freq", kind: .hertz), Knob(name: "MID GAIN", address: "/currPad/eq/band1/gain", kind: .decibels(18)),
        Knob(name: "HIGH FREQ", address: "/currPad/eq/band2/freq", kind: .hertz), Knob(name: "HIGH GAIN", address: "/currPad/eq/band2/gain", kind: .decibels(18)),
        Knob(name: "CHOKE", address: "/currPad/sample/chokeGroup", kind: .steps(["OFF", "1", "2", "3", "4", "5", "6"])),
        Knob(name: "BUS", address: "/currPad/bus", kind: .steps(["OFF", "A", "B", "C", "D"])),
    ]
    static let mixerKnobs = ["A", "B", "C", "D"].enumerated().map { Knob(name: "BUS \($1)", address: "/mixer/channels/\($0 + 1)/volume", kind: .level) }
        + [Knob(name: "MAIN", address: "/mixer/channels/main/volume", kind: .level)]
    static let swingKnob = Knob(name: "SWING", address: "/sequencer/swing", kind: .level)
    // Koala's own value bands (its code): scale = value × 11 / 128, beats = value / 8 + 1, snap = value / 32.
    static let seqKnobs = [swingKnob,
                           Knob(name: "BARS", address: "bars", kind: .relative(up: "/currSequence/numBars/++", down: "/currSequence/numBars/--")),
                           Knob(name: "BPM", address: "bpm", kind: .relative(up: "/sequencer/bpm/++", down: "/sequencer/bpm/--")),
                           Knob(name: "SCALE", address: "/keyboard/scale", kind: .steps(["CHROMATIC", "PENTATONIC", "MAJOR", "MINOR", "HARM MINOR",
                                                                                          "WHOLE TONE", "DIMINISHED", "HEXATONIC", "JAPANESE", "PELOG", "YING ZHONG"])),
                           Knob(name: "BEATS/BAR", address: "/sequencer/beatsPerBar", kind: .steps((1...16).map { "\($0)" })),
                           Knob(name: "SNAP", address: "/sequencer/seqSnap", kind: .steps(["1", "2", "3", "4"]))]
    func knobs(_ page: Page) -> [Knob?] {
        let list: [Knob]
        switch page {
        // Over the link Koala's pitch knob spans ±12 semitones (the SP-404's CTRL 2).
        case .pad: list = link ? Self.padKnobs.map { $0.address == "/currPad/pitch" ? Knob(name: $0.name, address: $0.address, kind: .semitones(12)) : $0 } : Self.padKnobs
        case .eq: list = Self.eqKnobs
        case .fx: list = []
        case .mixer: list = Self.mixerKnobs
        case .seq: list = Self.seqKnobs
        }
        return (0..<8).map { $0 < list.count ? list[$0] : nil }
    }
    private func memoryKey(_ address: String) -> String { address.hasPrefix("/currPad/") ? "\(address)#\(padFor(address))" : address }
    /// Where a knob starts: Koala's own value from its files, on the estimated scale; nil when the files don't say (or
    /// don't say on a known scale), so the screen shows "–" until the knob is turned.
    func initialPosition(_ address: String) -> Double? {
        let pad = padInfo(padFor(address))
        func level(_ v: Double) -> Double { max(0, min(127, v * 127)) }
        func centred(_ v: Double, _ range: Double) -> Double { max(0, min(127, 63.5 + v / range * 63.5)) }
        func freq(_ hz: Double) -> Double { max(0, min(127, log(max(20, hz) / 20) / log(1000) * 127)) }
        func dB(_ db: Double) -> Double { db <= -60 ? 0 : max(0, min(127, (db + 60) / 66 * 127)) }
        switch address {
        case "/currPad/volume": return level(pad.vol)
        case "/currPad/pan": return level(pad.pan)
        case "/currPad/pitch": return centred(pad.pitch, link ? 12 : 24)
        case "/currPad/sample/tone": return centred(pad.tone, 1)
        case "/currPad/sample/ampEnvelope/attack": return level(pad.attack / 2)
        case "/currPad/sample/ampEnvelope/release": return level(pad.release / 2)
        case "/currPad/sample/start": return pad.frames.map { level(pad.start / max(1, $0)) } ?? 0
        case "/currPad/sample/length":
            guard let frames = pad.frames, let end = pad.end else { return 127 }
            return level((end - pad.start) / max(1, frames))
        case "/currPad/eq/band0/freq": return freq(pad.eqFreq[0])
        case "/currPad/eq/band1/freq": return freq(pad.eqFreq[1])
        case "/currPad/eq/band2/freq": return freq(pad.eqFreq[2])
        case "/currPad/eq/band0/gain": return centred(pad.eqGain[0], 18)
        case "/currPad/eq/band1/gain": return centred(pad.eqGain[1], 18)
        case "/currPad/eq/band2/gain": return centred(pad.eqGain[2], 18)
        case "/currPad/sample/chokeGroup": return stepPosition(max(0, min(6, pad.choke)), of: 7)
        case "/currPad/bus": return stepPosition(max(0, min(4, pad.bus + 1)), of: 5)
        case "/mixer/channels/1/volume", "/mixer/channels/2/volume", "/mixer/channels/3/volume", "/mixer/channels/4/volume":
            let i = Int(address.split(separator: "/")[2]).map { $0 - 1 } ?? 0
            return dB(session.busVolume[max(0, min(3, i))])
        case "/mixer/channels/main/volume": return dB(session.mainVolume)
        case "/keyboard/scale":
            guard let name = session.scale?.uppercased(), case .steps(let names)? = Self.seqKnobs.first(where: { $0.address == address })?.kind,
                  let i = names.firstIndex(of: name) else { return nil }
            return stepPosition(i, of: names.count)
        case "/sequencer/swing": return level(session.swing)
        case "/sequencer/beatsPerBar": return stepPosition(max(0, min(15, session.beatsPerBar - 1)), of: 16)
        default: return nil
        }
    }
    /// The middle of step `i` of `n` (read the same whether Koala rounds or truncates).
    func stepPosition(_ i: Int, of n: Int) -> Double { min(127, (Double(i) + 0.5) * 128 / Double(n)) }
    func stepIndex(_ position: Double, of n: Int) -> Int { max(0, min(n - 1, Int(position * Double(n) / 128))) }
    /// A knob's position: what the Push sent, else Koala's files, else nil (unknown).
    func position(_ address: String) -> Double? { positions[memoryKey(address)] ?? initialPosition(address) }
    /// Encoder steps per step of a list or ± knob.
    static let stepsPerClick = 6
    private func turn(_ knob: Knob, delta: Int) {
        switch knob.kind {
        case .relative(let up, let down):
            let n = clicks(knob.address, delta)
            for _ in 0..<min(8, abs(n)) { tap(n > 0 ? up : down) }
        case .steps(let names):
            let n = clicks(knob.address, delta)
            guard n != 0 else { return }
            // From unknown, the first step lands on the first or last entry.
            let i = position(knob.address).map { max(0, min(names.count - 1, stepIndex($0, of: names.count) + n)) } ?? (n > 0 ? 0 : names.count - 1)
            setPosition(knob.address, stepPosition(i, of: names.count))
        default:
            // About 250 encoder steps end to end; SHIFT five times finer.
            setPosition(knob.address, (position(knob.address) ?? 63.5) + Double(delta) * (shift ? 0.1 : 0.5))
        }
    }
    private func clicks(_ id: String, _ delta: Int) -> Int {
        let total = (remainder[id] ?? 0) + delta
        let n = total / Self.stepsPerClick
        remainder[id] = total - n * Self.stepsPerClick
        return n
    }
    private func setPosition(_ address: String, _ value: Double) {
        let v = max(0, min(127, value)), memory = memoryKey(address), target = Int(v.rounded())
        positions[memory] = v
        guard lastSent[memory] != target else { return }
        // Over the link the edit names its pad (the one last hit); otherwise the map's CC acts on Koala's selected pad.
        if link, let function = Self.linkKnobs[address] {
            lastSent[memory] = target
            linkSend(KoalaFeedbackProtocol.padEdit(function, pad: editPad, value: UInt8(target)))
            return
        }
        guard let message = Self.table[address]?.set(target) else { return }
        lastSent[memory] = target
        emit(message)
    }
    func knobText(_ knob: Knob) -> String {
        if case .relative = knob.kind {} else if position(knob.address) == nil { return "–" }
        let p = position(knob.address) ?? 63.5
        switch knob.kind {
        case .level: return "\(Int((p / 127 * 100).rounded()))%"
        case .bipolar:
            let v = Int(((p - 63.5) / 63.5 * 100).rounded())
            return v == 0 ? "0" : (v > 0 ? "+\(v)" : "−\(-v)")
        case .pan:
            let v = Int(((p - 63.5) / 63.5 * 100).rounded())
            return v == 0 ? "C" : v < 0 ? "L \(-v)" : "R \(v)"
        case .steps(let names): return names[stepIndex(p, of: names.count)]
        case .hertz:
            let hz = 20 * pow(1000, p / 127)
            return hz < 1000 ? "\(Int(hz.rounded())) HZ" : String(format: "%.1f KHZ", hz / 1000)
        case .decibels(let range), .semitones(let range):
            let v = (p - 63.5) / 63.5 * range
            let unit: String
            if case .decibels = knob.kind { unit = " DB" } else { unit = " ST" }
            return abs(v) < 0.05 ? "0" + unit : String(format: "%+.1f", v).replacingOccurrences(of: "-", with: "−") + unit
        case .relative:
            if knob.address == "bpm" { return bpm.map { String(format: "%.1f", $0) } ?? "–" }
            let bars = session.bars.indices.contains(sequence) ? session.bars[sequence] : 1
            return "\(bars) BAR\(bars == 1 ? "" : "S")"
        }
    }

    // MARK: Buttons
    /// One press and release of a Koala button; `what` goes on the status line.
    private func tap(_ address: String, _ what: String? = nil) {
        guard let key = Self.table[address] else { return }
        if let on = key.press(true, velocity: Self.buttonVelocity) { send(on) }
        if let off = key.press(false) { send(off) }
        if let what { say(what) }
    }
    /// A Koala on/off switch: one press, and the Push shows the new state until Koala's files catch up.
    private func flip(_ address: String, _ flag: String, _ current: Bool, _ name: String) {
        tap(address)
        flipped[flag] = !current
        say("\(name) \(current ? "OFF" : "ON")")
    }
    /// Over the link: an on/off switch set on `editPad` by name (one shot, loop, reverse).
    private func linkSwitch(_ function: UInt8, _ flag: String, _ current: Bool, _ name: String) {
        linkSend(KoalaFeedbackProtocol.padEdit(function, pad: editPad, value: current ? 0 : 127))
        flipped[flag] = !current
        say("\(name) \(current ? "OFF" : "ON") · \(Self.padID(editPad))")
    }
    private func state(_ flag: String, _ file: Bool) -> Bool { flipped[flag] ?? file }
    // ONE SHOT, LOOP and REVERSE act on `editPad` (the link names it; without the link that's Koala's selected pad).
    var oneShot: Bool { state("oneshot#\(editPad)", padInfo(editPad).oneShot) }
    var looping: Bool { state("loop#\(editPad)", padInfo(editPad).loop) }
    var reversed: Bool { state("reverse#\(editPad)", padInfo(editPad).reverse) }
    var muted: Bool { state("mute#\(selected)", padInfo(selected).muted) }
    var quantizing: Bool { state("quantize", session.quantizing) }
    func busMuted(_ i: Int) -> Bool { i == 4 ? state("mute.main", session.mainMute) : state("mute.\(i)", session.busMute[i]) }
    func busSoloed(_ i: Int) -> Bool { state("solo.\(i)", session.busSolo[i]) }
    var sequence: Int { sequencePicked ?? session.sequence }

    func show(_ new: Page) {
        guard new != page else { return }
        if page == .mixer { tap("/mixer/hide") }
        page = new
        if page == .mixer { tap("/mixer/show") }
        touched = nil
        // Over the link Koala's own page follows: SEQ = its SEQUENCE page (held), FX = PERFORM, PAD = SAMPLE. Koala's
        // lights confirm it; until then the page is assumed, so a quick PAD after SEQ still goes back.
        guard link else { return }
        let target: KoalaPage
        switch new {
        case .seq:
            target = .sequence
            if koalaPage != .sequence { linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.patternSelect, KoalaFeedbackProtocol.pressed)) }
        case .fx:
            target = .perform
            if koalaPage != .perform { linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.perform, KoalaFeedbackProtocol.pressed)); linkSend(KoalaFeedbackProtocol.action(KoalaFeedbackProtocol.perform, 0)) }
        case .pad:
            target = .sample
            koalaToSample()
        case .eq, .mixer: return
        }
        if koalaPage != target { steering = (target, now() + 1) }
        koalaPage = target
    }

    /// Same verified toggle as MPC 16 LEVELS: keyboard mode acts on Koala's
    /// selected pad. With MIDI-can-select-pads disabled, a pad hit must not
    /// silently change the keyboard source or pretend it selected a new pad.
    private func keyboardPressed(send sendIt: Bool) {
        if sendIt { tap("/keyboard/toggle") }
        switch keyboard {
        case .off:
            keyboard = .on(selected); octave = 0; chopPage = 0
            show(.pad)
            say(chops(selected) > 0 ? "CHOPS · \(Self.padID(selected)) · MIDI 60 = CHOP 1" : "KEYBOARD · KOALA'S SELECTED PAD \(Self.padID(selected))", seconds: 6)
        case .choosing, .on:
            keyboard = .off
            say("KEYBOARD OFF · THE PADS ARE PADS")
        }
    }
    private func moveOctave(_ by: Int) {
        guard case .on(let pad) = keyboard else { say("NOTE: PLAY KOALA’S SELECTED PAD AS KEYS / CHOPS"); return }
        if chops(pad) > 0 { moveChopPage(by); return }
        octave = max(-keyboardOffset, min(127 - 63 - keyboardOffset, octave + by * 12))
        say("KEYS \(noteName(keyboardOffset + octave))–\(noteName(keyboardOffset + octave + 63))")
    }
    private func movePage(_ by: Int) {
        if case .on(let pad) = keyboard, chops(pad) > 0 { moveChopPage(by) }
        else { show(Page(rawValue: (page.rawValue + by + Page.allCases.count) % Page.allCases.count)!) }
    }
    private func moveChopPage(_ by: Int) {
        guard case .on(let pad) = keyboard, chops(pad) > 0 else { return }
        chopPage = max(0, min(chops(pad) > 64 ? 1 : 0, chopPage + by))
        say("CHOPS \(chopPage * 64 + 1)–\(min(chops(pad), chopPage * 64 + 64)) · \(chopCountOverride == nil ? "SAVED COUNT" : "COUNT OVERRIDE")")
    }
    /// Koala wraps below its MIDI-60 root. Choose a valid equivalent note for
    /// each slice, including chops 69–128 whose direct notes exceed 127.
    static func chopNote(ordinal: Int, count: Int) -> Int {
        let count = max(1, min(128, count))
        var note = chopOneNote + max(0, min(127, ordinal))
        while note > 127 { note -= count }
        return note
    }
    private func noteName(_ n: Int) -> String {
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"][((n % 12) + 12) % 12] + "\(n / 12 - 2)"
    }

    func lowerLabels() -> [String] {
        switch page {
        // MUTE and SOLO act on Koala's selected pad: marked * while that isn't the pad being edited.
        case .pad:
            let mark = link && editPad != selected ? "*" : ""
            return ["ONE SHOT", "LOOP", "REVERSE", "MUTE" + mark, "SOLO" + mark, shift ? "HEADPHONES" : "MIC IN", "RESAMPLE", "FILE IN"]
        case .eq: return ["LOW FLAT", "MID FLAT", "HIGH FLAT", "ALL FLAT", "ONE SHOT", "LOOP", "REVERSE", "MUTE"]
        case .fx: return Array(session.fx.prefix(8))
        case .mixer: return (soloHeld ? ["SOLO A", "SOLO B", "SOLO C", "SOLO D", ""] : ["MUTE A", "MUTE B", "MUTE C", "MUTE D", "MUTE MAIN"]) + ["PAD", "PERFORM", "SEQUENCE"]
        case .seq: return ["PLAY", "REC", "QUANTIZE", "PIANO ROLL", "BARS −", "BARS +", "TEMPO", shift ? "CLEAR SEQ" : "(SHIFT) CLEAR"]
        }
    }
    private func lowerOn() -> Set<Int> {
        var on = Set<Int>()
        switch page {
        case .pad:
            if oneShot, chops(editPad) == 0 { on.insert(0) }
            if looping { on.insert(1) }
            if reversed { on.insert(2) }
            if muted { on.insert(3) }
        case .fx: on = Set(fxOn.keys.filter { $0 < 8 })
        case .mixer: for i in 0..<(soloHeld ? 4 : 5) where soloHeld ? busSoloed(i) : busMuted(i) { on.insert(i) }
        case .seq:
            if playing { on.insert(0) }
            if quantizing { on.insert(2) }
        case .eq: break
        }
        return on
    }
    private func lower(_ i: Int, cc: Int, down: Bool) {
        if page == .fx { fxButton(i, cc: cc, down: down); return }
        guard down else { lowerDown.remove(i); return }
        lowerDown.insert(i)
        switch page {
        case .pad:
            switch i {
            case 0:
                // A chopper's ONE SHOT is its own setting, which Koala has no MIDI (or link) command for.
                if chops(editPad) > 0 { say("A CHOPPER'S ONE SHOT IS ON KOALA'S SCREEN (KOALA HAS NO MIDI FOR IT)", seconds: 4) }
                else if link { linkSwitch(KoalaFeedbackProtocol.oneShot, "oneshot#\(editPad)", oneShot, "ONE SHOT") }
                else { flip("/currPad/sample/oneshot/toggle", "oneshot#\(selected)", oneShot, "ONE SHOT") }
            case 1:
                if link { linkSwitch(KoalaFeedbackProtocol.loop, "loop#\(editPad)", looping, "LOOP") }
                else { flip("/currPad/sample/loop/toggle", "loop#\(selected)", looping, "LOOP") }
            case 2:
                if link { linkSwitch(KoalaFeedbackProtocol.reverse, "reverse#\(editPad)", reversed, "REVERSE") }
                else { flip("/currPad/sample/reverse/toggle", "reverse#\(selected)", reversed, "REVERSE") }
            case 3: flip("/mute/toggle", "mute#\(selected)", muted, "MUTE")
            case 4: tap("/solo/toggle", "SOLO")
            case 5: shift ? tap("/sample/headphone_monitoring", "HEADPHONE MONITORING") : tap("/sample/input/mic", "INPUT: MIC · HOLD AN EMPTY PAD ON KOALA TO RECORD")
            case 6: tap("/sample/input/resample", "INPUT: RESAMPLE · HOLD AN EMPTY PAD ON KOALA TO RECORD")
            default: tap("/sample/input/file", "INPUT: FILE")
            }
        case .mixer:
            let names = ["A", "B", "C", "D", "MAIN"]
            if i < 4, soloHeld { flip("/mixer/channels/\(i + 1)/solo/toggle", "solo.\(i)", busSoloed(i), "SOLO \(names[i])") }
            else if i < 4 { flip("/mixer/channels/\(i + 1)/mute/toggle", "mute.\(i)", busMuted(i), "MUTE \(names[i])") }
            else if i == 4 {
                if soloHeld { say("MAIN HAS NO SOLO; LOWER 1–4 SOLO THE BUSES") }
                else { flip("/mixer/channels/main/mute/toggle", "mute.main", busMuted(4), "MUTE MAIN") }
            }
            else if i == 5 { show(.pad) }
            else if i == 6 { show(.fx) }
            else if i == 7 { show(.seq) }
        case .seq:
            switch i {
            case 0: togglePlay()
            case 1: toggleRecord()
            case 2: flip("/sequencer/recordQuantize/toggle", "quantize", quantizing, "QUANTIZE")
            case 3: tap("/pianoroll/toggle", "PIANO ROLL")
            case 4: tap("/currSequence/numBars/--", "BARS −")
            case 5: tap("/currSequence/numBars/++", "BARS +")
            case 6: tap("/sequencer/bpmMenu/toggle", "TEMPO")
            default: shift ? tap("/currSequence/clear", "SEQUENCE \(sequence + 1) CLEARED · UNDO BRINGS IT BACK") : say("HOLD SHIFT TO CLEAR THE SEQUENCE")
            }
        case .eq:
            if i < 4 {
                for band in 0..<3 where i == 3 || band == i { setPosition("/currPad/eq/band\(band)/gain", 63.5) }
                say(i == 3 ? "ALL EQ GAINS FLAT" : ["LOW", "MID", "HIGH"][i] + " GAIN FLAT")
            } else { lowerPadSwitch(i - 4) }
        case .fx: break
        }
    }
    private func lowerPadSwitch(_ i: Int) {
        switch i {
        case 0:
            if chops(selected) > 0 { say("CHOPPER ONE SHOT: SET IN KOALA") }
            else { flip("/currPad/sample/oneshot/toggle", "oneshot#\(selected)", oneShot, "ONE SHOT") }
        case 1: flip("/currPad/sample/loop/toggle", "loop#\(selected)", looping, "LOOP")
        case 2: flip("/currPad/sample/reverse/toggle", "reverse#\(selected)", reversed, "REVERSE")
        default: flip("/mute/toggle", "mute#\(selected)", muted, "MUTE")
        }
    }
    private func togglePlay() { tap("/sequencer/play/toggle", playing ? "STOP" : "PLAY"); localPlaying = !playing }
    private func toggleRecord() { tap("/sequencer/record/toggle", "RECORD"); localRecording.toggle() }
    /// The side (scene) buttons, top first: sequences of the bank, or on the FX page effects 9–16.
    private func scene(_ i: Int, cc: Int, down: Bool) {
        if page == .fx { fxButton(8 + i, cc: cc, down: down); return }
        guard down else { return }
        let index = sequenceBank * 8 + i
        tap(KoalaPushProfile.sequenceAddress(index), "SEQUENCE \(index + 1)")
        sequencePicked = index
    }

    // MARK: Effects
    func fxLevel(_ i: Int) -> Double {
        if let amount = fxAmount[i] { return amount }
        let v = i < session.fxValues.count ? session.fxValues[i] : 0
        return v > 0.02 ? max(1, min(127, v * 127)) : 100
    }
    /// Koala's effects take a value: 1–127 = on at that amount, 0 = off.
    private func fxSend(_ i: Int, amount: Int) {
        guard i < session.fx.count, let key = Self.table[KoalaPushProfile.fxAddress(session.fx[i])] else { return }
        let level = max(0, min(127, amount))
        let message = key.type == "cc" ? key.set(level) : (level > 0 ? key.press(true, velocity: UInt8(level)) : key.press(false))
        if let message { emit(message) }
        fxOn[i] = level > 0 ? level : nil; fxDirty.insert(i); ownedFX.insert(i)
    }
    /// Tap an effect: on (the strip sets it); tap again: off. Hold one that was off: on only while held. Pressing
    /// another one that's on just picks it for the strip.
    private func fxButton(_ i: Int, cc: Int, down: Bool) {
        if down {
            guard i < session.fx.count else { return }
            let kind: FXPress = fxOn[i] == nil ? .turnedOn : fxSelected == i ? .wasSelectedOn : .selectedOnly
            if kind == .turnedOn { fxSend(i, amount: Int(fxLevel(i).rounded())) }
            fxSelected = i
            fxPress[cc] = (i, now(), kind)
            say(session.fx[i] + (fxOn[i] != nil ? " · THE STRIP SETS IT" : ""))
            return
        }
        guard let press = fxPress.removeValue(forKey: cc) else { return }
        let held = now() - press.at >= Self.tapLatch
        switch press.kind {
        case .turnedOn: if held { fxSend(press.fx, amount: 0) }
        case .wasSelectedOn: if !held { fxSend(press.fx, amount: 0) }
        case .selectedOnly: break
        }
    }
    private func strip(_ value: Double) {
        guard stripHeld else { return }
        if let knob = stripTarget {
            if stripAnchor == nil { stripAnchor = value; return }
            setPosition(knob.address, stripStart + (value - stripAnchor!) * 127)
        } else if let i = fxSelected, page == .fx {
            let amount = max(1, min(127, (value * 127).rounded()))
            fxAmount[i] = amount
            if let on = fxOn[i], on != Int(amount) { fxSend(i, amount: Int(amount)) }
        }
    }
    private func stripTouched(_ down: Bool) {
        stripHeld = down; stripAnchor = nil; stripTarget = nil
        guard down, page != .fx else { return }
        let candidates = knobs(page)
        let focused = touched.flatMap { candidates.indices.contains($0) ? candidates[$0] : nil }
        let defaultKnob: Knob
        switch page {
        case .pad: defaultKnob = keyboard == .off ? Self.padKnobs[0] : Self.padKnobs[2]
        case .eq: defaultKnob = Self.eqKnobs[3]
        case .mixer: defaultKnob = Self.mixerKnobs[4]
        case .seq, .fx: defaultKnob = Self.swingKnob
        }
        let target = focused ?? defaultKnob
        switch target.kind {
        case .relative, .steps: say("TOUCH STRIP: HOLD A CONTINUOUS ENCODER"); return
        default: break
        }
        guard let initial = position(target.address) else { say("STRIP TARGET UNKNOWN: TURN ITS ENCODER FIRST"); return }
        stripTarget = target; stripStart = initial
        say("TOUCH STRIP · \(target.name) · RELATIVE TO TOUCH START")
    }

    // MARK: Events
    func handle(_ event: Push2Event) {
        switch event {
        case .pad(let index, let velocity, let down):
            guard (0..<64).contains(index) else { return }
            if down { padDown(index, velocity: fullLevel ? 127 : max(1, velocity)) }
            else { releasePad(index) }
        case .pressure(let index, let value):
            if let off = heldPads[index] { send([0xA0 | (off[0] & 0x0F), off[1], value]) }
        case .channelPressure(let value):
            for channel in Set(heldPads.values.map { $0[0] & 0x0F }) { send([0xD0 | channel, value]) }
        case .encoder(let encoder, let delta):
            if shift, encoder == 6, case .on(let pad) = keyboard, chops(pad) > 0 {
                chopCountOverride = max(1, min(128, chops(pad) + delta)); chopPage = min(chopPage, chops(pad) > 64 ? 1 : 0)
                say("CHOP COUNT OVERRIDE \(chops(pad)) · MATCH KOALA'S COUNT"); return
            }
            if page == .fx, (0..<8).contains(encoder) {
                let i = encoder + (shift ? 8 : 0)
                fxSelected = i; fxAmount[i] = max(1, min(127, fxLevel(i) + Double(delta) * 0.5))
                fxSend(i, amount: Int(fxAmount[i]!.rounded())); return
            }
            switch encoder {
            case 0..<8: if let knob = knobs(page)[encoder] { turn(knob, delta: delta) }
            case 8: for _ in 0..<min(8, abs(delta)) { tap(delta > 0 ? "/sequencer/bpm/++" : "/sequencer/bpm/--") }
            case 9: turn(Self.swingKnob, delta: delta)
            default: turn(Self.mixerKnobs[4], delta: delta)
            }
        case .encoderTouch(let encoder, let down):
            if encoder < 8 { touched = down ? encoder : (touched == encoder ? nil : touched) }
            else if down {
                if encoder == 10 { say("MASTER · " + knobText(Self.mixerKnobs[4])) }
                else if encoder == 8 { say("TEMPO · " + (bpm.map { String(format: "%.1f BPM", $0) } ?? "UNKNOWN")) }
                else { say("SWING · " + knobText(Self.swingKnob)) }
            }
        case .button(let cc, let down):
            button(cc, down: down)
        case .strip(let value):
            strip(value)
        case .stripTouch(let down):
            stripTouched(down)
        }
    }
    private func padDown(_ index: Int, velocity: UInt8) {
        let pad = Push2Protocol.koalaPad(forPush: index)
        switch keyboard {
        case .choosing:
            // This hit (the pad's own note) puts Koala's keyboard mode on it.
            hold(index, address: KoalaPushProfile.padAddress(pad), velocity: velocity)
            keyboard = .on(pad); selected = pad; octave = 0; chopPage = 0; chopCountOverride = nil; lastHit = pad
            say(chops(pad) > 0 ? "KEYBOARD ON \(Self.padID(pad)): ITS \(chops(pad)) CHOPS ON THE PADS" : "KEYBOARD ON \(Self.padID(pad)): 16 LEVELS · OCTAVE ▲▼", seconds: 4)
        case .on(let keys) where chops(keys) > 0:
            // Same A–D quadrants as MPC; small/odd counts wrap, and page 2
            // reaches all 128 slices using equivalent valid MIDI notes.
            hold(index, note: Self.chopNote(ordinal: chopPage * 64 + pad, count: chops(keys)), velocity: velocity)
        case .on:
            // 16 Levels: rows of 8 from the bottom left, chromatic; key 25 = the pad's own pitch.
            hold(index, note: keyboardOffset + octave + index, velocity: velocity)
        case .off:
            hold(index, address: KoalaPushProfile.padAddress(pad), velocity: velocity)
            // Over the link: this is the pad the PAD page edits now, and Koala's screen shows its bank.
            if link {
                lastHit = pad
                if koalaBank != pad / 16 { linkSend([KoalaFeedbackProtocol.bankSelect, UInt8(pad / 16)]); koalaBank = pad / 16 }
            }
            let info = padInfo(pad)
            say("\(Self.padID(pad)) · \(!info.loaded ? "EMPTY" : info.label.isEmpty ? "—" : info.label)", seconds: 1.5)
        }
    }
    private func hold(_ index: Int, address: String, velocity: UInt8) {
        guard let key = Self.table[address], let on = key.press(true, velocity: velocity), let off = key.press(false) else { return }
        hold(index, on, off)
    }
    private func hold(_ index: Int, note: Int, velocity: UInt8) {
        let ch = UInt8(max(1, min(16, keyboardChannel)) - 1), n = UInt8(max(0, min(127, note)))
        hold(index, [0x90 | ch, n, velocity], [0x80 | ch, n, 0])
    }
    private func hold(_ index: Int, _ on: [UInt8], _ off: [UInt8]) {
        releasePad(index)
        send(on); heldPads[index] = off; heldPadOns[index] = on
    }

    private func releasePad(_ index: Int) {
        guard let off = heldPads.removeValue(forKey: index) else { return }
        heldPadOns[index] = nil
        // Odd/small chop counts can alias physical pads onto the same MIDI
        // note. Keep it sounding until the last owner lets go.
        if !heldPads.values.contains(off) { send(off) }
    }
    private func button(_ cc: Int, down: Bool) {
        if down { guard pressedButtons.insert(cc).inserted else { return } }
        else { pressedButtons.remove(cc) }
        // Whatever a held button pressed is let go with it, whatever page shows by then.
        if !down, let press = fxPress[cc] { fxButton(press.fx, cc: cc, down: false); return }
        if !down, let off = heldButtons.removeValue(forKey: cc) { send(off); return }
        if Push2Button.lowerRow.contains(cc) { lower(cc - Push2Button.lowerRow.lowerBound, cc: cc, down: down); return }
        if Push2Button.scenes.contains(cc) { scene(Push2Button.scenes.upperBound - cc, cc: cc, down: down); return }
        if cc == Push2Button.shift { shift = down; return }
        if cc == Push2Button.solo {
            soloHeld = down
            // SOLO solos the pad; held on the MIXER page it turns the lower row into SOLO keys.
            if down, page != .mixer { tap("/solo/toggle", "SOLO") }
            return
        }
        guard down else { return }
        switch cc {
        case Push2Button.upperRow:
            let i = cc - Push2Button.upperRow.lowerBound
            switch i {
            case 0...4: show(Page(rawValue: i)!)
            case 5: keyboardPressed(send: true)
            case 6: tap("/load/toggle", "LOAD")
            default: tap("/settings/toggle", "SETTINGS")
            }
        case Push2Button.note: keyboardPressed(send: true)
        case Push2Button.play: togglePlay()
        case Push2Button.record: toggleRecord()
        case Push2Button.tapTempo: shift ? tap("/sequencer/bpmMenu/toggle", "TEMPO") : tap("/sequencer/tapTempo", "TAP TEMPO")
        case Push2Button.metronome: tap("/metro/toggle", "METRONOME")
        case Push2Button.undo: shift ? tap("/redo", "REDO") : tap("/undo", "UNDO")
        case Push2Button.quantize: flip("/sequencer/recordQuantize/toggle", "quantize", quantizing, "QUANTIZE")
        case Push2Button.doubleLoop: shift ? tap("/currSequence/numBars/--", "BARS −") : tap("/currSequence/numBars/*2", "SEQUENCE × 2")
        case Push2Button.delete:
            if shift { tap("/delete", "DELETE"); return }
            // Hold a pad, then DELETE. Over the link the delete names the held pad (on Koala's SAMPLE page; on its
            // SEQUENCE page the same command clears something else). Without it Koala clears its selected pad, so only
            // when that's the pad held.
            let held = heldPads.keys.sorted().map { Push2Protocol.koalaPad(forPush: $0) }
            if keyboard != .off { say("TURN KEYBOARD OFF TO CLEAR A PAD") }
            else if held.isEmpty { say("HOLD A PAD, THEN PRESS DELETE TO CLEAR IT") }
            else if link, let pad = held.first {
                guard koalaPage == .sample else { say("GO TO THE PAD PAGE (KOALA'S SAMPLE PAGE) TO CLEAR A PAD"); return }
                linkSend([KoalaFeedbackProtocol.delete, UInt8(pad / 16), UInt8(pad % 16)])
                say("CLEARED \(Self.padID(pad)) · UNDO BRINGS IT BACK", seconds: 4)
            }
            else if !held.contains(selected) { say("KOALA'S SELECTED PAD IS \(Self.padID(selected)): PICK THE PAD ON KOALA'S SCREEN FIRST", seconds: 4) }
            else { tap("/currPad/delete", "CLEARED \(Self.padID(selected)) · UNDO BRINGS IT BACK") }
        case Push2Button.mute: flip("/mute/toggle", "mute#\(selected)", muted, "MUTE")
        case Push2Button.browse: shift ? tap("/export/toggle", "EXPORT") : tap("/load/toggle", "LOAD")
        case Push2Button.select: shift ? tap("/escape", "BACK") : tap("/edit", "EDIT")
        case Push2Button.accent: fullLevel.toggle(); say(fullLevel ? "FULL LEVEL · VELOCITY 127" : "NATURAL PAD VELOCITY")
        case Push2Button.stop:
            if playing { tap("/sequencer/play/toggle", "STOP") }
            localPlaying = false; releaseAll(); macroPlaying = false
        case Push2Button.master: show(.mixer); touched = 4; say("MASTER VOLUME · MASTER ENCODER")
        case Push2Button.layout: detailView.toggle(); say(detailView ? "DETAIL VIEW · SAVED WAVEFORM / NOTES" : "EIGHT ENCODER VIEW")
        case Push2Button.pageLeft: movePage(-1)
        case Push2Button.pageRight: movePage(1)
        case Push2Button.repeatButton: repeatEnabled.toggle(); nextRepeat = now(); say(repeatEnabled ? "REPEAT · HELD PADS · 1/16" : "REPEAT OFF")
        case Push2Button.scale: show(.seq); touched = 3; say("SCALE · ENCODER 4 · SHIFT FOR FINE")
        case Push2Button.convert: show(.pad); detailView = true; say("WAVE / CHOP VIEW · SET CHOPS IN KOALA · NOTE: KEYBOARD", seconds: 6)
        case Push2Button.addDevice: show(.fx); say("PERFORM · 16 EFFECTS · TOUCH STRIP SETS AMOUNT")
        case Push2Button.addTrack: show(.mixer); say("MIXER · BUSES A–D · HOLD SOLO FOR SOLO KEYS")
        case Push2Button.new:
            if let empty = session.notes.indices.first(where: { session.notes[$0].isEmpty && $0 != sequence }) {
                tap(KoalaPushProfile.sequenceAddress(empty), "EMPTY SEQUENCE \(empty + 1)"); sequencePicked = empty; show(.seq)
            } else { show(.seq); say("NO SAVED EMPTY SEQUENCE · SHIFT + LOWER 8 CLEARS CURRENT") }
        case Push2Button.duplicate: tap("/currSequence/numBars/*2", "SEQUENCE × 2"); show(.seq)
        case Push2Button.fixedLength:
            show(.seq); touched = 1; say("RECORD LENGTH · ENCODER 2 SETS BARS")
        case Push2Button.automate: toggleMacro()
        case Push2Button.setup: tap("/settings/toggle", "SETTINGS")
        case Push2Button.device: show(.pad)
        case Push2Button.session: show(.fx)
        case Push2Button.mix: show(.mixer)
        case Push2Button.clip: show(.seq)
        case Push2Button.left: show(Page(rawValue: (page.rawValue + Page.allCases.count - 1) % Page.allCases.count)!)
        case Push2Button.right: show(Page(rawValue: (page.rawValue + 1) % Page.allCases.count)!)
        case Push2Button.octaveUp: moveOctave(1)
        case Push2Button.octaveDown: moveOctave(-1)
        case Push2Button.up: if page == .fx { show(.seq) }; sequenceBank = min(3, sequenceBank + 1); say("SEQUENCES \(sequenceBank * 8 + 1)–\(sequenceBank * 8 + 8)")
        case Push2Button.down: if page == .fx { show(.seq) }; sequenceBank = max(0, sequenceBank - 1); say("SEQUENCES \(sequenceBank * 8 + 1)–\(sequenceBank * 8 + 8)")
        case Push2Button.user:
            guard shift else { onChooseController?(); return }
            if now() - quitArmedAt < 3 { quitArmedAt = -10; onQuit?() } else { quitArmedAt = now(); say("SHIFT + USER AGAIN TO QUIT KOALA") }
        default: break
        }
    }

    /// The MPC's messages to Koala while Koala runs from the Push (watch only): its KEYS and its pads.
    func observeForwarded(_ bytes: [UInt8]) {
        guard bytes.count >= 3 else { return }
        if let press = Self.table["/keyboard/toggle"]?.press(true), bytes[0] == press[0], bytes[1] == press[1], bytes[2] > 0 {
            keyboardPressed(send: false)
            return
        }
        // Koala choosing: the MPC's pad (channel 16) picks the keyboard pad.
        if bytes[0] == 0x9F, bytes[2] > 0, keyboard == .choosing, (36...99).contains(Int(bytes[1])) {
            let pad = Int(bytes[1]) - 36
            keyboard = .on(pad); selected = pad; octave = 0
        }
    }
    /// Lets go of everything held (the Push is given up, or Koala quit).
    func releaseAll() {
        macroRecording = false; macroPlaying = false
        for off in heldPads.values { send(off) }
        for off in heldButtons.values { send(off) }
        for i in Array(ownedFX) where fxOn[i] != nil { fxSend(i, amount: 0) }; ownedFX = []
        heldPads = [:]; heldPadOns = [:]; heldButtons = [:]; fxPress = [:]; lowerDown = []; pressedButtons = []
        shift = false; soloHeld = false; stripHeld = false; stripTarget = nil; stripAnchor = nil
    }

    private func emit(_ bytes: [UInt8]) {
        send(bytes)
        guard macroRecording, !applyingMacro, bytes.count == 3, bytes[0] & 0xF0 == 0xB0 else { return }
        if macro.count < 4000, now() - macroStarted < 30 { macro.append(MacroPoint(time: now() - macroStarted, bytes: bytes)) }
    }
    private func toggleMacro() {
        if shift { macroRecording = false; macroPlaying = false; macro = []; say("CC MACRO CLEARED"); return }
        if macroRecording {
            macroRecording = false; macroLength = max(0.1, min(30, now() - macroStarted))
            macroPlaying = !macro.isEmpty; macroCursor = 0; macroStarted = now()
            say(macroPlaying ? "CC MACRO LOOP · AUTOMATE STOPS · SHIFT CLEARS" : "NO KNOB / STRIP MOVEMENT CAPTURED")
        } else if macroPlaying { macroPlaying = false; say("CC MACRO STOPPED") }
        else { macro = []; macroPad = selected; macroRecording = true; macroStarted = now(); say("CAPTURING CC MACRO · TURN KNOBS / STRIP · AUTOMATE LOOPS", seconds: 10) }
    }
    /// Called by the companion's main timer; input still goes directly to MIDI.
    func tick() {
        let time = now()
        if repeatEnabled, time >= nextRepeat {
            nextRepeat = max(nextRepeat + 60 / max(20, bpm ?? 120) / 4, time + 0.002)
            var retriggered = Set<[UInt8]>()
            for index in heldPadOns.keys.sorted() {
                if let on = heldPadOns[index], let off = heldPads[index], retriggered.insert(off).inserted { send(off); send(on) }
            }
        }
        if macroRecording, time - macroStarted >= 30 { toggleMacro() }
        guard macroPlaying else { return }
        guard selected == macroPad else { macroPlaying = false; say("CC MACRO STOPPED · SELECTED PAD CHANGED"); return }
        let elapsed = time - macroStarted
        applyingMacro = true
        while macroCursor < macro.count, macro[macroCursor].time <= elapsed {
            let bytes = macro[macroCursor].bytes; send(bytes)
            for (address, key) in Self.table where key.type == "cc" && key.channel == Int(bytes[0] & 0x0F) + 1 && key.value == Int(bytes[1]) {
                positions[memoryKey(address)] = Double(bytes[2]); lastSent[memoryKey(address)] = Int(bytes[2])
            }
            for i in session.fx.indices where Self.table[KoalaPushProfile.fxAddress(session.fx[i])]?.value == Int(bytes[1]) && bytes[0] == 0xBD {
                fxOn[i] = bytes[2] > 0 ? Int(bytes[2]) : nil
            }
            macroCursor += 1
        }
        applyingMacro = false
        if elapsed >= macroLength { macroStarted = time; macroCursor = 0 }
    }

    // MARK: What the Push shows
    func view() -> KoalaView {
        var v = KoalaView()
        v.page = page.rawValue; v.wave = page == .pad && detailView ? wave : nil
        if page == .seq, detailView, session.notes.indices.contains(sequence) {
            v.pianoRoll = keyboard != .off
            v.notes = session.notes[sequence].filter { v.pianoRoll ? $0.pad == selected : $0.pad / 16 == selected / 16 }; v.sequenceBeats = Double((session.bars.indices.contains(sequence) ? session.bars[sequence] : 1) * session.beatsPerBar)
        }
        let t = now()
        v.upper = Self.upperLabels
        v.upperOn = [page.rawValue]
        if keyboard != .off { v.upperAlt = [5] }
        v.lower = lowerLabels()
        v.lowerOn = lowerOn()
        v.lowerHeld = page == .fx ? Set(fxPress.values.map(\.fx).filter { $0 < 8 }) : lowerDown
        if page == .pad, chops(editPad) > 0 { v.lowerDim = [0] }
        // The header shows the pad the page edits: the keyboard pad, Koala's selected pad (EQ, through the map), or the
        // pad being edited (over the link, the last one hit).
        let pad: Int
        if case .on(let p) = keyboard { pad = p } else { pad = page == .eq ? selected : editPad }
        v.bank = pad / 16
        v.pad = Self.padID(pad)
        let info = padInfo(pad)
        v.padName = !info.loaded ? "EMPTY" : info.label.isEmpty ? "—" : info.label
        var status: [String] = []
        if playing {
            let beats = max(1, session.beatsPerBar), beat = ticks / 24
            status.append(transport == .running ? "▶ \(beat / beats + 1).\(beat % beats + 1)" : "▶ PLAYING")
        } else if transport == .stopped { status.append("■ STOPPED") }
        status.append("SEQ \(sequence + 1)")
        if let bpm { status.append(String(format: "%.1f BPM", bpm)) }
        status.append(link ? "LINK" : "SAVED / LOCAL")
        if fullLevel { status.append("FULL") }
        if repeatEnabled { status.append("1/16") }
        if macroRecording { status.append("MACRO REC") } else if macroPlaying { status.append("MACRO LOOP") }
        v.status = status.joined(separator: " · ")
        switch keyboard {
        case .off where link && page == .eq: v.mode = "EQ EDITS KOALA'S SELECTED PAD \(Self.padID(selected))"
        case .off where link: v.mode = "PADS: A–D · EDITING \(Self.padID(editPad))" + (editPad != selected ? " · * = KOALA'S \(Self.padID(selected))" : "")
        case .off: v.mode = "PADS: A–D · \(Self.padID(selected)) SELECTED IN KOALA"
        case .choosing: v.mode = "KEYBOARD: CHOOSING A PAD"
        case .on(let p):
            v.mode = chops(p) > 0 ? "CHOPPER \(Self.padID(p)) · \(chops(p)) \(chopCountOverride == nil ? "SAVED" : "OVERRIDE") · PAGE \(chopPage + 1) · CHOPS \(chopPage * 64 + 1)–\(chopPage * 64 + 64)"
                : "KEYBOARD: \(Self.padID(p)) · 16 LEVELS \(noteName(keyboardOffset + octave))–\(noteName(keyboardOffset + octave + 63))"
        }
        if t < messageUntil { v.message = message }
        if keyboard == .choosing {
            v.big = "HIT THE PAD TO PLAY"
            v.hint = "A CHOPPER: ITS CHOPS · ANY OTHER PAD: 16 LEVELS · KEYBOARD AGAIN: CANCEL"
        } else if page == .fx {
            func cell(_ i: Int) -> KoalaView.Cell {
                guard i < session.fx.count else { return KoalaView.Cell() }
                return KoalaView.Cell(name: "\(i + 1) " + session.fx[i], value: "", level: fxLevel(i) / 127, on: fxOn[i] != nil, lit: fxSelected == i)
            }
            v.cells = (0..<8).map(cell)
            v.cellsTop = (8..<16).map(cell)
        } else {
            v.cells = knobs(page).enumerated().map { i, knob in
                guard let knob else { return KoalaView.Cell() }
                let p = position(knob.address)
                var centred = false
                switch knob.kind {
                case .bipolar, .pan, .decibels, .semitones: centred = true
                default: break
                }
                let level: Double?
                if case .relative = knob.kind { level = nil } else { level = p.map { $0 / 127 } }
                // Over the link, a PAD page knob that still acts on Koala's selected pad (START, LENGTH) is marked *.
                let mark = link && page == .pad && knob.address.hasPrefix("/currPad/") && Self.linkKnobs[knob.address] == nil && editPad != selected
                return KoalaView.Cell(name: knob.name + (mark ? "*" : ""), value: knobText(knob), level: level, centred: centred, lit: touched == i)
            }
        }
        return v
    }

    /// Pad colours by Push index.
    func padColors() -> [UInt8] {
        switch keyboard {
        case .on(let p) where chops(p) > 0:
            // Its chops where its pads are, in their bank's colour; white while held; the rest dark.
            let n = chops(p)
            return (0..<64).map { index in
                let ordinal = chopPage * 64 + Push2Protocol.koalaPad(forPush: index)
                return heldPads[index] != nil ? Push2Color.hit.rawValue : Push2Color.koala((ordinal % n) / 16 % 4, dim: ordinal >= n).rawValue
            }
        case .on:
            // 16 Levels: C bright, the pad's own pitch cream, white while held.
            return (0..<64).map { k in
                if heldPads[k] != nil { return Push2Color.hit.rawValue }
                let pitch = octave + k - 24
                if pitch == 0 { return Push2Color.selected.rawValue }
                return (((pitch % 12) + 12) % 12 == 0 ? Push2Color.koalaA : Push2Color.koalaDimA).rawValue
            }
        case .choosing:
            // Choosing: the pads blink, so you see the next hit picks.
            let bright = Int(now() * 3) % 2 == 0
            return (0..<64).map { index in
                if heldPads[index] != nil { return Push2Color.hit.rawValue }
                return Push2Color.koala(Push2Protocol.koalaPad(forPush: index) / 16, dim: !bright).rawValue
            }
        case .off:
            // Koala's banks: bright = a sound, dim = empty; the pad being edited cream; white while held. Over the link
            // "a sound" is Koala's own pad light on its SAMPLE page (01 = empty), so a new recording shows at once.
            return (0..<64).map { index in
                if heldPads[index] != nil { return Push2Color.hit.rawValue }
                let pad = Push2Protocol.koalaPad(forPush: index)
                if pad == editPad { return Push2Color.selected.rawValue }
                let loaded: Bool
                if link, koalaPage == .sample, let state = padStates[pad], state != 0 { loaded = state != 0x01 }
                else { loaded = session.pads[pad]?.loaded == true }
                return Push2Color.koala(pad / 16, dim: !loaded).rawValue
            }
        }
    }
    /// Button LEDs: palette indices for the RGB buttons, brightness for the white ones.
    func buttonLights() -> [Int: UInt8] {
        var out: [Int: UInt8] = [:]
        let white: (Bool) -> UInt8 = { $0 ? 127 : 16 }
        let lower = lowerLabels(), on = lowerOn()
        let held = page == .fx ? Set(fxPress.values.map(\.fx).filter { $0 < 8 }) : lowerDown
        for i in 0..<8 {
            out[Push2Button.upperRow.lowerBound + i] = i == page.rawValue ? Push2Color.selected.rawValue
                : (i == 5 && keyboard != .off) ? Push2Color.koalaB.rawValue : Push2Color.koalaDimA.rawValue
            out[Push2Button.lowerRow.lowerBound + i] = lower[i].isEmpty ? 0 : held.contains(i) ? Push2Color.hit.rawValue
                : on.contains(i) ? Push2Color.koalaB.rawValue : Push2Color.koalaDimB.rawValue
        }
        for i in 0..<8 {
            let cc = Push2Button.scenes.upperBound - i
            if page == .fx {
                let fx = 8 + i, pressed = fxPress.values.contains { $0.fx == fx }
                out[cc] = fx < session.fx.count ? (pressed ? Push2Color.hit.rawValue : fxOn[fx] != nil ? Push2Color.koalaA.rawValue : Push2Color.koalaDimA.rawValue) : 0
            } else {
                out[cc] = sequenceBank * 8 + i == sequence ? Push2Color.koalaB.rawValue : Push2Color.koalaDimB.rawValue
            }
        }
        out[Push2Button.play] = playing ? Push2Color.target.rawValue : Push2Color.playDim.rawValue
        // Koala's record light, over the link.
        out[Push2Button.record] = (link ? leds[KoalaFeedbackProtocol.recPattern] == KoalaFeedbackProtocol.pressed : localRecording) ? Push2Color.accent.rawValue : Push2Color.accentDim.rawValue
        out[Push2Button.mute] = muted ? Push2Color.koalaD.rawValue : Push2Color.koalaDimD.rawValue
        out[Push2Button.solo] = soloHeld ? Push2Color.koalaC.rawValue : Push2Color.koalaDimC.rawValue
        out[Push2Button.shift] = white(shift)
        out[Push2Button.note] = white(keyboard != .off)
        out[Push2Button.delete] = keyboard == .off && !heldPads.isEmpty ? 127 : 16
        out[Push2Button.user] = white(now() - quitArmedAt < 3)
        out[Push2Button.up] = sequenceBank < 3 && page != .fx ? 48 : 0
        out[Push2Button.down] = sequenceBank > 0 && page != .fx ? 48 : 0
        for (cc, p) in [(Push2Button.device, Page.pad), (Push2Button.session, .fx), (Push2Button.mix, .mixer), (Push2Button.clip, .seq)] {
            out[cc] = white(page == p)
        }
        for cc in [Push2Button.tapTempo, Push2Button.metronome, Push2Button.undo, Push2Button.quantize, Push2Button.doubleLoop,
                   Push2Button.browse, Push2Button.setup, Push2Button.left, Push2Button.right, Push2Button.select, Push2Button.accent] {
            out[cc] = 16
        }
        var levels = false
        if case .on(let p) = keyboard, chops(p) == 0 { levels = true }
        out[Push2Button.octaveUp] = levels && keyboardOffset + octave + 63 < 127 ? 48 : 0
        out[Push2Button.octaveDown] = levels && keyboardOffset + octave > 0 ? 48 : 0
        out[Push2Button.pageLeft] = 16; out[Push2Button.pageRight] = 16
        if case .on(let pad) = keyboard, chops(pad) > 0 {
            out[Push2Button.octaveUp] = chops(pad) > 64 && chopPage == 0 ? 48 : 0
            out[Push2Button.octaveDown] = chopPage > 0 ? 48 : 0
            out[Push2Button.pageRight] = out[Push2Button.octaveUp]; out[Push2Button.pageLeft] = out[Push2Button.octaveDown]
        }
        out[Push2Button.accent] = white(fullLevel); out[Push2Button.repeatButton] = white(repeatEnabled)
        out[Push2Button.layout] = white(detailView)
        out[Push2Button.automate] = macroRecording ? Push2Color.accent.rawValue : macroPlaying ? Push2Color.koalaB.rawValue : Push2Color.koalaDimB.rawValue
        for cc in [Push2Button.stop, Push2Button.master, Push2Button.scale, Push2Button.convert, Push2Button.addDevice,
                   Push2Button.addTrack, Push2Button.new, Push2Button.duplicate, Push2Button.fixedLength] { out[cc] = 16 }
        out[Push2Button.stop] = Push2Color.koalaDimA.rawValue
        return out
    }
}

/// The Push screen while Koala runs, as data (drawn by `KoalaScreenArt`).
struct KoalaView: Equatable {
    var page = 0
    var wave: KoalaWave?
    var notes: [KoalaSession.Note]? = nil
    var sequenceBeats = 4.0
    var pianoRoll = false
    /// One of the eight columns over the encoders: a knob, or an effect.
    struct Cell: Equatable {
        var name = "", value = "", level: Double?, centred = false, on = false, lit = false
    }
    var upper: [String] = [], upperOn: Set<Int> = [], upperAlt: Set<Int> = []
    var lower: [String] = [], lowerOn: Set<Int> = [], lowerHeld: Set<Int> = [], lowerDim: Set<Int> = []
    var pad = "", padName = "", bank = 0, status = "", mode = "", message = ""
    var cells: [Cell] = [], cellsTop: [Cell] = []
    var big = "", hint = ""
}

/// Draws `KoalaView` at 960 × 160 in Koala's colours and font, laid out like the Push's own screen in Live: the
/// upper keys' labels on top, the encoders' names and values in the middle, the lower keys' labels at the bottom.
enum KoalaScreenArt {
    static let columnWidth: CGFloat = 120

    private static func text(_ s: String, _ r: NSRect, size: CGFloat, color: NSColor, align: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.alignment = align; style.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(in: r, withAttributes: [.font: KoalaLook.font(size), .foregroundColor: color, .paragraphStyle: style])
    }
    private static func fill(_ r: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        if radius > 0 { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill() } else { r.fill() }
    }

    static func draw(_ v: KoalaView, in b: NSRect) {
        fill(b, KoalaLook.background)
        let white = KoalaLook.foreground, muted = KoalaLook.muted, pink = KoalaLook.pink, blue = KoalaLook.blue
        // The upper keys.
        for (i, label) in v.upper.enumerated() {
            let r = NSRect(x: CGFloat(i) * columnWidth + 4, y: 139, width: columnWidth - 8, height: 20)
            if v.upperOn.contains(i) { fill(r, pink, radius: 10) } else if v.upperAlt.contains(i) { fill(r, blue, radius: 10) }
            text(label, r.offsetBy(dx: 0, dy: -1), size: 15, color: v.upperOn.contains(i) || v.upperAlt.contains(i) ? white : muted, align: .center)
        }
        // The pad: its ID in its bank's colour and its name; Koala's transport on the right.
        let bankColor = KoalaLook.banks[max(0, min(3, v.bank))]
        text(v.pad, NSRect(x: 10, y: 108, width: 60, height: 30), size: 24, color: bankColor)
        text(v.padName, NSRect(x: 70, y: 110, width: 470, height: 26), size: 19, color: white)
        text(v.status, NSRect(x: 540, y: 112, width: 410, height: 22), size: 16, color: white, align: .right)
        // What the pads do (blue), and the last thing done (pink).
        text(v.mode, NSRect(x: 10, y: 92, width: 610, height: 18), size: 13, color: blue)
        text(v.message, NSRect(x: 625, y: 92, width: 325, height: 18), size: 13, color: pink, align: .right)
        fill(NSRect(x: 0, y: 88, width: b.width, height: 1), KoalaLook.grey)
        if !v.big.isEmpty {
            text(v.big, NSRect(x: 0, y: 50, width: b.width, height: 34), size: 28, color: pink, align: .center)
            text(v.hint, NSRect(x: 0, y: 30, width: b.width, height: 18), size: 14, color: muted, align: .center)
        } else if !v.cellsTop.isEmpty {
            // Effects: 9–16 (the side buttons) above, 1–8 (the lower keys) below.
            for (row, cells) in [(1, v.cellsTop), (0, v.cells)] {
                for (i, c) in cells.enumerated() where !c.name.isEmpty {
                    let r = NSRect(x: CGFloat(i) * columnWidth + 6, y: 30 + CGFloat(row) * 28, width: columnWidth - 12, height: 24)
                    if c.on { fill(r, pink, radius: 5) }
                    if c.lit { white.setStroke(); NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke() }
                    text(c.name, NSRect(x: r.minX + 6, y: r.minY + 6, width: r.width - 12, height: 16), size: 12, color: c.on ? white : muted)
                    if let level = c.level {
                        fill(NSRect(x: r.minX + 6, y: r.minY + 3, width: (r.width - 12) * CGFloat(level), height: 2), c.on ? white : KoalaLook.grey)
                    }
                }
            }
        } else if let wave = v.wave {
            let rect = NSRect(x: 8, y: 52, width: 944, height: 34)
            fill(rect, KoalaLook.grey.withAlphaComponent(0.35), radius: 3)
            blue.setStroke(); let path = NSBezierPath(); path.lineWidth = 1
            for (i, peak) in wave.peaks.enumerated() {
                let x = rect.minX + CGFloat(i) / CGFloat(max(1, wave.peaks.count - 1)) * rect.width
                let amplitude = CGFloat(peak) * rect.height * 0.47
                path.move(to: NSPoint(x: x, y: rect.midY - amplitude)); path.line(to: NSPoint(x: x, y: rect.midY + amplitude))
            }
            path.stroke()
            for (i, slice) in wave.slices.enumerated() where slice >= 0 && slice <= 1 {
                let x = rect.minX + CGFloat(slice) * rect.width
                fill(NSRect(x: x, y: rect.minY, width: 1, height: rect.height), pink)
                if wave.slices.count <= 32 { text("\(i + 1)", NSRect(x: x + 2, y: rect.maxY - 12, width: 22, height: 12), size: 9, color: white) }
            }
            for edge in [wave.start, wave.end] {
                fill(NSRect(x: rect.minX + CGFloat(max(0, min(1, edge))) * rect.width, y: rect.minY, width: 2, height: rect.height), white)
            }
            for (i, c) in v.cells.enumerated() where !c.name.isEmpty {
                let r = NSRect(x: CGFloat(i) * columnWidth + 4, y: 30, width: columnWidth - 8, height: 20)
                if c.lit { fill(r, pink, radius: 3) }
                text(c.name + " " + c.value, r, size: 12, color: white, align: .center)
            }
        } else if let notes = v.notes {
            let rect = NSRect(x: 8, y: 32, width: 944, height: 52)
            fill(rect, KoalaLook.grey.withAlphaComponent(0.25), radius: 3)
            for step in 0...32 { fill(NSRect(x: rect.minX + CGFloat(step) * rect.width / 32, y: rect.minY, width: 1, height: rect.height), KoalaLook.grey) }
            let pitches = notes.map(\.pitch)
            let minPitch = floor(pitches.min() ?? -12), maxPitch = max(minPitch + 11, ceil(pitches.max() ?? 12))
            for note in notes where note.beat >= 0 && note.beat < v.sequenceBeats {
                let x = rect.minX + CGFloat(note.beat / max(1, v.sequenceBeats)) * rect.width
                let width = max(3, CGFloat(note.length / max(1, v.sequenceBeats)) * rect.width)
                let y = rect.minY + (v.pianoRoll ? CGFloat((note.pitch - minPitch) / (maxPitch - minPitch + 1)) * rect.height : CGFloat(note.pad % 16) * rect.height / 16)
                fill(NSRect(x: x, y: y, width: min(width, max(0, rect.maxX - x)), height: v.pianoRoll ? 3.5 : 2.5), note.pad / 16 == v.bank ? pink : blue, radius: 1)
            }
            text(v.pianoRoll ? "SAVED PIANO · LAYOUT: ENCODERS" : "BANK \(["A", "B", "C", "D"][v.bank]) · SAVED PATTERN · LAYOUT: ENCODERS", NSRect(x: 650, y: 70, width: 300, height: 14), size: 10, color: white, align: .right)
        } else {
            // The eight encoders: name, value, and a bar (from the middle for ± values).
            for (i, c) in v.cells.enumerated() where !c.name.isEmpty {
                let x = CGFloat(i) * columnWidth
                if c.lit { fill(NSRect(x: x + 2, y: 30, width: columnWidth - 4, height: 56), KoalaLook.grey, radius: 4) }
                text(c.name, NSRect(x: x + 8, y: 66, width: columnWidth - 16, height: 18), size: 13, color: muted)
                text(c.value, NSRect(x: x + 8, y: 40, width: columnWidth - 16, height: 26), size: 20, color: white)
                guard let level = c.level else { continue }
                let track = NSRect(x: x + 8, y: 34, width: columnWidth - 16, height: 4)
                fill(track, KoalaLook.grey)
                let w = track.width, l = CGFloat(max(0, min(1, level)))
                if c.centred {
                    let mid = track.minX + w / 2, end = track.minX + w * l
                    fill(NSRect(x: min(mid, end), y: track.minY, width: max(2, abs(end - mid)), height: track.height), pink)
                } else {
                    fill(NSRect(x: track.minX, y: track.minY, width: w * l, height: track.height), pink)
                }
            }
        }
        // The lower keys.
        fill(NSRect(x: 0, y: 25, width: b.width, height: 1), KoalaLook.grey)
        for (i, label) in v.lower.enumerated() where !label.isEmpty {
            let r = NSRect(x: CGFloat(i) * columnWidth + 4, y: 2, width: columnWidth - 8, height: 20)
            let held = v.lowerHeld.contains(i), on = v.lowerOn.contains(i)
            if held { fill(r, white, radius: 10) } else if on { fill(r, blue, radius: 10) }
            text(label, r.offsetBy(dx: 0, dy: -1), size: 14, color: held ? .black : on ? white : v.lowerDim.contains(i) ? KoalaLook.grey : white, align: .center)
        }
    }
}
