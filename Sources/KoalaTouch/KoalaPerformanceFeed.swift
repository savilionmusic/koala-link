import AVFoundation
import Foundation

/// What Koala is being told to play, for the webcam's overlay and video effects. Every message either bridge sends
/// Koala passes through `observe` after it is published: it only reads the bytes, so nothing Koala hears changes.
final class KoalaPerformanceFeed {
    static let shared = KoalaPerformanceFeed()
    struct Hit: Equatable { var pad: Int, chop: Bool, keys: Bool, note: Int, time: Double }
    struct Snapshot {
        var lastHit: Hit?
        /// Pads (or keyboard notes) held now, with when each began.
        var held: [Int: Double] = [:]
        /// Perform effects that are on, by name, with their amount (1–127).
        var fx: [String: Int] = [:]
        var chopperMode = false
        /// STUTTER from the webcam window's own button, and from touching Koala's own STUTTER (KoalaStutterTouch).
        var manualStutter = false, touchStutter = false
        var stutterOn: Bool { manualStutter || touchStutter || fx["STUTTER"] != nil }
        /// When the stutter began (host seconds), for the video's repeats.
        var stutterSince: Double?
        /// Koala's page as the touch overlay last saw it ("sample", "sequence", "perform"); nil = not known.
        var page: String?
    }
    private let lock = NSLock()
    private var state = Snapshot()
    /// Koala's effect keys: status byte & 0xF0, channel nibble, number → effect name.
    private var fxKeys: [UInt32: String] = [:]

    private init() { reloadKeys() }
    static func now() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

    /// The controller's effect keys as written into Koala's map (`canonicalMap`).
    func reloadKeys() {
        var keys: [UInt32: String] = [:]
        for (address, key) in KoalaPushProfile.canonicalMap {
            guard let name = KoalaPushProfile.fxNames.first(where: { KoalaPushProfile.fxAddress($0) == address }) else { continue }
            let nibble = UInt32(max(1, min(16, key.channel)) - 1)
            keys[(key.type == "cc" ? 0xB0 : 0x90) << 16 | nibble << 8 | UInt32(key.value & 0x7F)] = name
        }
        lock.lock(); fxKeys = keys; lock.unlock()
    }

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return state }
    func setChopperMode(_ on: Bool) { lock.lock(); state.chopperMode = on; lock.unlock() }
    func setManualStutter(_ on: Bool) { lock.lock(); state.manualStutter = on; settle(); lock.unlock() }
    func setTouchStutter(_ on: Bool) { lock.lock(); state.touchStutter = on; settle(); lock.unlock() }
    func setPage(_ page: String?) { lock.lock(); state.page = page; lock.unlock() }
    /// Notes when the stutter begins and ends (lock held).
    private func settle() {
        if !state.stutterOn { state.stutterSince = nil } else if state.stutterSince == nil { state.stutterSince = Self.now() }
    }

    func observe(_ bytes: [UInt8]) {
        var i = 0
        let keyboardChannel = UInt8(KoalaPushProfile.pushKeyboardChannel - 1)
        lock.lock(); defer { lock.unlock() }
        while i < bytes.count {
            let status = bytes[i]
            guard status & 0x80 != 0 else { i += 1; continue }
            let length = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 2 : status >= 0xF0 ? 1 : 3
            guard status < 0xF0, i + length <= bytes.count else { i += length; continue }
            let kind = status & 0xF0, channel = status & 0x0F, number = bytes[i + 1], value = length == 3 ? bytes[i + 2] : 0
            let on = kind == 0x90 && value > 0, off = kind == 0x80 || (kind == 0x90 && value == 0)
            if on || off, let name = fxKeys[0x90 << 16 | UInt32(channel) << 8 | UInt32(number)] {
                state.fx[name] = on ? Int(value) : nil
            } else if kind == 0xB0, let name = fxKeys[0xB0 << 16 | UInt32(channel) << 8 | UInt32(number)] {
                state.fx[name] = value > 0 ? Int(value) : nil
            } else if on || off, channel == 15 || channel == keyboardChannel {
                // Channel 16: the pads (36–99) or, in Chopper keyboard mode, chops 1–64 (60–123). The Push's keyboard: notes.
                let keys = channel == keyboardChannel, chop = !keys && state.chopperMode
                let first = chop ? KoalaPadMapper.chopperFirstNote : KoalaPadMapper.sampleFirstNote
                let pad = keys ? Int(number) : Int(number) - first
                if on, keys || (0..<64).contains(pad) {
                    let now = Self.now()
                    state.lastHit = Hit(pad: pad, chop: chop, keys: keys, note: Int(number), time: now)
                    state.held[Int(number)] = now
                } else if off { state.held[Int(number)] = nil }
            }
            i += length
        }
        settle()
    }
}
