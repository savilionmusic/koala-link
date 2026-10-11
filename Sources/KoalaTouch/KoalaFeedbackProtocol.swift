import Foundation

// Koala's SP-404MKII link ("Koala Controller Mode"), decoded from Koala 2.0.12 and tested live on 2026-10-03
// (KOALA_SP404_RESEARCH.md). Koala treats any MIDI port pair whose name contains "SP-404MKII" as a Roland SP-404MKII
// (with its setting "Use built-in midi mappings" on), and then talks Roland SysEx with it, both ways:
// - Koala sends its greeting, its bank, its button lights and every pad's light;
// - the device sends per-pad edits that name the pad, bank select, and page buttons.
// Paper Picker opens such a pair for the Push. Pad notes, keyboard mode and chops still go through the MIDI map.

enum KoalaFeedbackProtocol {
    /// The port pair's name: "SP-404MKII" in it is what Koala looks for.
    static let portName = "Koala Link SP-404MKII"
    /// Device → Koala, and Koala → device: Roland SysEx headers (no checksum).
    static let toKoala: [UInt8] = [0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x00, 0x08, 0x12, 0x31]
    static let fromKoala: [UInt8] = [0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0x00, 0x08, 0x12, 0x30]

    // Device → Koala functions (the payload's first byte).
    static let requestUpdate: UInt8 = 0x01, oneShot: UInt8 = 0x03, reverse: UInt8 = 0x04, loop: UInt8 = 0x05
    static let volume: UInt8 = 0x06, pitch: UInt8 = 0x07, pan: UInt8 = 0x08, attack: UInt8 = 0x09, release: UInt8 = 0x0A
    static let tone: UInt8 = 0x0B, delete: UInt8 = 0x0C, controller: UInt8 = 0x0D, bankSelect: UInt8 = 0x10
    // Controller actions (`0D 00 00 action value`; 0x3F = pressed). Koala lights them back the same way.
    static let patternSelect: UInt8 = 0x20, subPad: UInt8 = 0x22, recPattern: UInt8 = 0x23, perform: UInt8 = 0x30
    static let pressed: UInt8 = 0x3F

    /// A message to Koala.
    static func message(_ payload: [UInt8]) -> [UInt8] { toKoala + payload.map { $0 & 0x7F } + [0xF7] }
    static func action(_ action: UInt8, _ value: UInt8) -> [UInt8] { [controller, 0, 0, action, value] }
    static func padEdit(_ function: UInt8, pad: Int, value: UInt8) -> [UInt8] {
        [function, UInt8(max(0, min(3, pad / 16))), UInt8(pad % 16), value & 0x7F]
    }

    /// Collects SysEx from a byte stream (CoreMIDI may split or join packets) and returns each message from Koala as
    /// its payload (header and F7 removed).
    struct Reader {
        private var buffer: [UInt8] = [], inside = false
        mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            var out: [[UInt8]] = []
            for b in bytes {
                if b == 0xF0 { buffer = [b]; inside = true; continue }
                guard inside else { continue }
                if b >= 0xF8 { continue }                     // real-time bytes may sit inside SysEx
                buffer.append(b)
                if b == 0xF7 {
                    inside = false
                    if buffer.count > fromKoala.count, Array(buffer.prefix(fromKoala.count)) == fromKoala {
                        out.append(Array(buffer[fromKoala.count..<(buffer.count - 1)]))
                    }
                    buffer = []
                } else if b & 0x80 != 0 || buffer.count > 256 {
                    inside = false; buffer = []              // a status byte ends a broken message
                }
            }
            return out
        }
    }

}
