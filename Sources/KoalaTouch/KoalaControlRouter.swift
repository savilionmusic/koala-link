import Foundation

/// Paper Cut's raw Public/Private bank model, with a decoder per connection.
/// The 16 physical pad IDs stay the same in every bank; software assigns the
/// bank at note-on and keeps that assignment until note-off.
struct KoalaControlRouter {
    enum Role { case publicControl, privateSelector }
    enum Event: Equatable { case midi([UInt8]), padBank(Int), qlinkBank(Int), chopperMode(Bool), fullLevel(Bool) }

    private struct Stream {
        var status: UInt8 = 0
        var data: [UInt8] = []
        var inSysEx = false
        var selectors = Set<UInt8>()
        var buttons = Set<UInt8>()

        mutating func decode(_ bytes: [UInt8]) -> [[UInt8]] {
            var messages: [[UInt8]] = []
            for byte in bytes {
                if byte >= 0xF8 { continue } // Realtime may interrupt any message.
                if byte == 0xF0 { inSysEx = true; status = 0; data.removeAll(); continue }
                if byte == 0xF7 { inSysEx = false; status = 0; data.removeAll(); continue }
                if inSysEx { continue }
                if byte & 0x80 != 0 {
                    // System common cancels running status; it is not a control.
                    status = byte < 0xF0 ? byte : 0
                    data.removeAll(keepingCapacity: true)
                    continue
                }
                guard status != 0 else { continue }
                data.append(byte)
                let kind = status & 0xF0
                let needed = kind == 0xC0 || kind == 0xD0 ? 1 : 2
                if data.count == needed {
                    messages.append([status] + data)
                    data.removeAll(keepingCapacity: true)
                }
            }
            return messages
        }
    }

    private var streams: [UInt32: Stream] = [:]
    private var pads = KoalaPadMapper()
    private var heldLinks: [UInt8: UInt8] = [:]
    private var heldButtons = Set<UInt8>()
    private(set) var padBank = 0
    private(set) var qlinkBank = 0
    private static let shift: UInt8 = 0x31
    private var soloSelectors = Set<UInt8>()
    private static func soloKey(_ bus: Int) -> KoalaKey {
        let address = "/mixer/channels/\(bus + 1)/solo/toggle"
        return KoalaPushProfile.defaults.first { $0.address == address }!.key
    }
    /// Each physical Q-Link's last reported position, and each bank-D effect's amount as last sent Koala.
    private var knobRaw: [UInt8: UInt8] = [:], fxAmounts: [Int: Int] = [:]
    private static let fxKnobGain = 4
    private static let bankDEffects: [Int?] = ["STUTTER", "TALKBOX", "FILTER", "CUTTER"].map { KoalaPushProfile.fxNames.firstIndex(of: $0) }
    private(set) var chopperMode = false
    private(set) var fullLevel = false
    private var sampleBank = 0

    mutating func selectPadBank(_ bank: Int) -> [Event] {
        guard (0..<4).contains(bank) else { return [] }
        padBank = bank
        if !chopperMode { sampleBank = bank }
        return [.padBank(bank)]
    }

    mutating func setChopperMode(_ enabled: Bool) -> [Event] {
        guard enabled != chopperMode else { return [] }
        chopperMode = enabled
        // Start at chop 1 in bank A without losing the selected sample bank.
        padBank = enabled ? 0 : sampleBank
        return [.chopperMode(enabled), .padBank(padBank)]
    }

    mutating func restoreSongControls(sampleBank: Int, keyboardMode: Bool) -> [Event] {
        self.sampleBank = max(0, min(3, sampleBank))
        chopperMode = keyboardMode
        padBank = keyboardMode ? 0 : self.sampleBank
        return [.chopperMode(keyboardMode), .padBank(padBank)]
    }

    mutating func releaseHeld() -> [Event] {
        var events = pads.releaseAll().map { Event.midi([0x8F, $0, 0]) }
        events += heldLinks.values.map { Event.midi([0x8E, $0, 0]) }
        events += heldButtons.map { Event.midi([0x8E, $0, 0]) }
        heldLinks.removeAll()
        heldButtons.removeAll()
        return events
    }

    mutating func resetConnections() -> [Event] {
        let releases = releaseHeld()
        streams.removeAll()
        return releases
    }

    mutating func consume(_ bytes: [UInt8], source: UInt32, role: Role, routing: Bool) -> [Event] {
        var stream = streams[source] ?? Stream()
        let messages = stream.decode(bytes)
        streams[source] = stream
        return messages.flatMap { process($0, source: source, role: role, routing: routing) }
    }

    private mutating func process(_ message: [UInt8], source: UInt32, role: Role, routing: Bool) -> [Event] {
        let status = message[0], kind = status & 0xF0, channel = status & 0x0F
        let number = message[1], value = message.count > 2 ? message[2] : 0
        let down = kind == 0x90 && value > 0
        let up = kind == 0x80 || (kind == 0x90 && value == 0)

        // Public owns the two latched level buttons. Delayed Private copies
        // must not toggle either state again after Public has released.
        if role == .privateSelector, channel == 0, [UInt8(0x27), 0x28].contains(number), down || up { return [] }

        // FULL LEVEL is local velocity control, not a MIDI Learn note. Track
        // its press through release so holding it cannot repeatedly toggle.
        if channel == 0, number == 0x27, down || up {
            let wasDown = streams.values.contains { $0.buttons.contains(number) }
            if down { streams[source]?.buttons.insert(number) }
            else { streams[source]?.buttons.remove(number) }
            let isDown = streams.values.contains { $0.buttons.contains(number) }
            guard routing, isDown, !wasDown else { return [] }
            fullLevel.toggle()
            return [.fullLevel(fullLevel)]
        }

        if channel == 0, (down || up), number == 0 || (0x23...0x26).contains(number) {
            let wasDown = streams.values.contains { $0.selectors.contains(number) }
            if down { streams[source]?.selectors.insert(number) }
            else { streams[source]?.selectors.remove(number) }
            // SHIFT + A–D: solo Koala's buses 1–4 (its mixer's tracks), on any page; the bank stays. The press decides
            // until its release.
            if (0x23...0x26).contains(number) {
                let key = Self.soloKey(Int(number - 0x23))
                if up, !streams.values.contains(where: { $0.selectors.contains(number) }), soloSelectors.remove(number) != nil {
                    return key.press(false).map { [.midi($0)] } ?? []
                }
                if down, !wasDown, routing, heldButtons.contains(Self.shift) {
                    soloSelectors.insert(number)
                    return key.press(true).map { [.midi($0)] } ?? []
                }
            }
            guard down && !wasDown else { return [] }
            if number == 0 {
                qlinkBank = (qlinkBank + 1) % 4
                return [.qlinkBank(qlinkBank)]
            }
            return selectPadBank(Int(number - 0x23))
        }

        // Paper Cut's measured transport/function buttons can arrive on either
        // port. Match combined held state, rather than an arbitrary time limit.
        if channel == 0, (down || up),
           [UInt8(0x31), 0x49, 0x51, 0x52, 0x53, 0x6F, 0x28, 0x35, 0x0B, 0x09].contains(number) {
            let wasDown = streams.values.contains { $0.buttons.contains(number) }
            if down { streams[source]?.buttons.insert(number) }
            else { streams[source]?.buttons.remove(number) }
            let isDown = streams.values.contains { $0.buttons.contains(number) }
            guard routing, wasDown != isDown else { return [] }
            if isDown { heldButtons.insert(number) }
            else if heldButtons.remove(number) == nil { return [] }
            // 16 LEVELS toggles Koala's keyboard and the 64 chromatic chop notes
            // together. Combined port state makes a mirrored press toggle once.
            if number == 0x28, isDown {
                return [.midi(Self.button(number, down: true, velocity: value))] + setChopperMode(!chopperMode)
            }
            return [.midi(Self.button(number, down: isDown, velocity: value))]
        }

        // Private is for selectors and the known buttons above, never a second
        // musical input. In particular, a Private pad-off cannot release Public.
        guard role == .publicControl, routing else { return [] }
        if channel == 9, KoalaPadMapper.physicalPadOrder.contains(number) {
            if down, let note = pads.noteOn(number, bank: padBank, chopperMode: chopperMode) { return [.midi([0x9F, note, fullLevel ? 127 : value])] }
            if up, let note = pads.noteOff(number) { return [.midi([0x8F, note, value])] }
            if kind == 0xA0, let note = pads.mappedHeldNote(for: number) { return [.midi([0xAF, note, value])] }
            return []
        }

        if channel == 0, kind == 0xB0, (0x10...0x13).contains(number) {
            let knob = number - 0x10
            let assignment = heldLinks[knob].map { $0 - 84 } ?? UInt8(qlinkBank * 4) + knob
            let previous = knobRaw.updateValue(value, forKey: knob)
            // Q-Link bank D drives Perform effects: STUTTER, TALKBOX, FILTER, CUTTER (Koala's effect CCs on Ch14; 0 = off).
            // The knob reports 0–127 over several turns, so its movement counts 4× (a quarter of its travel covers the
            // effect), and its ends are the effect's: all the way down is always off.
            if assignment >= 12, let fx = Self.bankDEffects[Int(assignment) - 12] {
                let delta = Int(value) - Int(previous ?? value)
                var amount = max(0, min(127, (fxAmounts[fx] ?? 0) + delta * Self.fxKnobGain))
                if value == 0 { amount = 0 } else if value == 127 { amount = 127 }
                guard amount != fxAmounts[fx] ?? 0 else { return [] }
                fxAmounts[fx] = amount
                return [.midi([0xBD, UInt8(KoalaPushProfile.fxCCBase + fx), UInt8(amount)])]
            }
            return [.midi([0xBE, assignment + 1, value])]
        }
        if channel == 0, (down || up), (0x54...0x57).contains(number) {
            let knob = number - 0x54
            if down {
                guard heldLinks[knob] == nil else { return [] }
                let note = UInt8(84 + qlinkBank * 4) + knob
                heldLinks[knob] = note
                return [.midi(Self.button(note, down: true, velocity: value))]
            }
            if let note = heldLinks.removeValue(forKey: knob) { return [.midi(Self.button(note, down: false, velocity: value))] }
            return []
        }
        // Unassigned Public controls remain available to Koala's MIDI Learn.
        // Channel 15 separates them from the automatic 64 pads on channel 16.
        if kind == 0x90 || kind == 0x80 { return [.midi(Self.button(number, down: down, velocity: value))] }
        var forwarded = message
        forwarded[0] = kind | 0x0E
        return [.midi(forwarded)]
    }

    /// A button (or a Q-Link touch): a note on channel 15, as the MPC profile maps them.
    static func button(_ number: UInt8, down: Bool, velocity: UInt8) -> [UInt8] {
        [down ? 0x9E : 0x8E, number, down ? velocity : 0]
    }

    static func offlineSelfCheck() -> Bool {
        var router = Self()
        func feed(_ bytes: [UInt8], _ source: UInt32 = 1, _ role: Role = .publicControl) -> [Event] {
            router.consume(bytes, source: source, role: role, routing: true)
        }
        // Selector press and release in one packet, plus a split pad message.
        guard feed([0x90, 0x24, 127, 0x80, 0x24, 0], 2, .privateSelector) == [.padBank(1)],
              feed([0x99, 0x25]).isEmpty,
              feed([100, 0xF8]) == [.midi([0x9F, 52, 100])] else { return false }
        guard feed([0x90, 0x25, 127, 0x80, 0x25, 0], 2, .privateSelector) == [.padBank(2)],
              feed([0x89, 0x25, 0], 2, .privateSelector).isEmpty,
              feed([0xA9, 0x25, 70, 0x89, 0x25, 0]) == [.midi([0xAF, 52, 70]), .midi([0x8F, 52, 0])] else { return false }
        // Per-source selector holds: duplicate Public/Private copies and releases.
        guard feed([0x90, 0, 127]) == [.qlinkBank(1)],
              feed([0x90, 0, 127, 0x80, 0, 0], 2, .privateSelector).isEmpty,
              feed([0x90, 0, 0]).isEmpty,
              feed([0x90, 0, 127, 0x80, 0, 0]) == [.qlinkBank(2)] else { return false }
        // Contact captures its knob assignment until lift-off across a bank change.
        guard feed([0x90, 0x54, 127, 0x90, 0, 127, 0x80, 0, 0]) == [.midi([0x9E, 92, 127]), .qlinkBank(3)],
              feed([0xB0, 0x10, 42, 0x80, 0x54, 0, 0xB0, 0x10, 70]) == [.midi([0xBE, 9, 42]), .midi([0x8E, 92, 0]), .midi([0xBD, 28, 112])] else { return false }
        // Down to the knob's end: the effect goes off.
        guard feed([0xB0, 0x10, 60]) == [.midi([0xBD, 28, 72])], feed([0xB0, 0x10, 0]) == [.midi([0xBD, 28, 0])],
              feed([0xB0, 0x10, 0]).isEmpty else { return false }
        // SHIFT + B solos bus 2 and keeps the bank; C alone still picks bank C.
        let bank = router.padBank, solo2 = Self.soloKey(1)
        guard feed([0x90, 0x31, 127]) == [.midi(Self.button(0x31, down: true, velocity: 127))],
              feed([0x90, 0x24, 127]) == [.midi(solo2.press(true)!)],
              feed([0x80, 0x31, 0]) == [.midi(Self.button(0x31, down: false, velocity: 0))],
              feed([0x80, 0x24, 0]) == [.midi(solo2.press(false)!)], router.padBank == bank,
              feed([0x90, 0x25, 127, 0x80, 0x25, 0]) == [.padBank(2)] else { return false }
        // Long/split SysEx must not interpret embedded status bytes as strikes.
        guard feed([0xF0, 0x47] + Array(repeating: 0x25, count: 600) + [0x99, 0x25, 100]).isEmpty,
              feed([0xF7, 0x99, 0x25, 100, 0x24, 90, 0x89, 0x25, 0, 0x24, 0]) == [.midi([0x9F, 68, 100]), .midi([0x9F, 69, 90]), .midi([0x8F, 68, 0]), .midi([0x8F, 69, 0])] else { return false }
        guard feed([0x90, 0x52, 127], 2, .privateSelector) == [.midi([0x9E, 0x52, 127])],
              feed([0x90, 0x52, 127, 0x80, 0x52, 0]).isEmpty,
              feed([0x80, 0x52, 0], 2, .privateSelector) == [.midi([0x8E, 0x52, 0])] else { return false }
        // Every bank/slot follows the exact Paper Cut raw table. Selectors never
        // publish MIDI notes; only Public channel-10 pads do.
        for bank in 0..<4 {
            guard feed([0x90, UInt8(0x23 + bank), 127, 0x80, UInt8(0x23 + bank), 0]) == [.padBank(bank)] else { return false }
            for (slot, raw) in KoalaPadMapper.physicalPadOrder.enumerated() {
                let note = UInt8(36 + bank * 16 + slot)
                guard feed([0x99, raw, 99, 0x89, raw, 0]) == [.midi([0x9F, note, 99]), .midi([0x8F, note, 0])] else { return false }
            }
        }
        return true
    }
}
