import AppKit

// Koala's MIDI map and MIDI settings for Koala Link (copied from Paper Picker 1.14, where it also served the Push): the
// keys the MPC's bridge sends are written into Koala's map, and Koala's MIDI settings are set, while Koala is closed.

/// One key in Koala's MIDI map (midiMapping.json): channel 1–16 (0 = any), "note" or "cc", number.
struct KoalaKey: Hashable {
    var channel: Int, type: String, value: Int
    private var nibble: UInt8 { UInt8(max(1, min(16, channel)) - 1) }
    /// A button press or release as Koala expects it on this key.
    func press(_ down: Bool, velocity: UInt8 = 127) -> [UInt8]? {
        let number = UInt8(max(0, min(127, value)))
        switch type {
        case "note": return down ? [0x90 | nibble, number, max(1, velocity)] : [0x80 | nibble, number, 0]
        case "cc": return [0xB0 | nibble, number, down ? 127 : 0]
        default: return nil
        }
    }
    /// A knob position (0–127); only a CC key carries one.
    func set(_ position: Int) -> [UInt8]? {
        guard type == "cc" else { return nil }
        return [0xB0 | nibble, UInt8(max(0, min(127, value))), UInt8(max(0, min(127, position)))]
    }
}

/// Koala's MIDI settings, and its MIDI map holding the MPC's keys (`canonicalMap`; it also carries the parked Push
/// controller's keys, which do nothing without it). Both are written at every launch, while Koala is closed, backed up first.
enum KoalaPushProfile {
    enum Mode { case mpcTouch, push2 }
    static let pushKeyboardChannel = 13
    /// Koala's 16 Perform effects in its own order (fx.json: the "vanilla" eight, then "strawberry").
    static let fxNames = ["CRUSH", "PITCH", "COMB", "RING", "REVERB", "STUTTER", "GATE", "FILTER",
                          "CUTTER", "REVERSE", "DUB", "TEMPO DELAY", "TALKBOX", "VIBROFLANGE", "DIRTY", "COMPRESSOR"]
    static func fxAddress(_ name: String) -> String { "/perform/fx/" + name.lowercased().replacingOccurrences(of: " ", with: "") }
    static func padAddress(_ pad: Int) -> String { "/pads/\(["A", "B", "C", "D"][max(0, min(3, pad / 16))])\(pad % 16 + 1)" }
    static func sequenceAddress(_ index: Int) -> String { "/sequencer/sequences/\(index)" }

    /// Buttons: note on to press, note off to let go. Default key: channel 14, note = position here.
    static let buttons: [String] = [
        "/sequencer/tapTempo", "/metro/toggle", "/undo", "/sequencer/recordQuantize/toggle",
        "/sequencer/bpm/++", "/sequencer/bpm/--", "/currSequence/numBars/++", "/currSequence/numBars/--",
        "/currSequence/clear", "/pianoroll/toggle", "/load/toggle", "/settings/toggle",
        "/mixer/show", "/mixer/hide", "/perform/hold/toggle", "/mute/toggle", "/solo/toggle",
        "/currPad/sample/oneshot/toggle", "/currPad/sample/loop/toggle", "/currPad/sample/reverse/toggle",
        "/sample/input/mic", "/sample/input/resample",
        "/mixer/channels/1/mute/toggle", "/mixer/channels/2/mute/toggle", "/mixer/channels/3/mute/toggle",
        "/mixer/channels/4/mute/toggle", "/mixer/channels/main/mute/toggle",
        "/mixer/channels/1/solo/toggle", "/mixer/channels/2/solo/toggle", "/mixer/channels/3/solo/toggle",
        "/mixer/channels/4/solo/toggle", "/sequencer/bpmMenu/toggle",
        "/sequencer/play/toggle", "/sequencer/record/toggle", "/keyboard/toggle",
    ] + fxNames.map(fxAddress) + (0..<32).map(sequenceAddress) + ["/currPad/delete", "/currSequence/numBars/*2"]
        // Koala 2.0.12's other buttons (from its code), so every function it offers over MIDI is on the Push.
        + ["/redo", "/edit", "/escape", "/delete", "/export/toggle", "/midi/velocity/toggle", "/sample/input/file", "/sample/headphone_monitoring"]
    /// Knobs: absolute CC positions. Default key: channel 14, CC = position here + 1.
    static let knobs: [String] = [
        "/currPad/volume", "/currPad/pan", "/currPad/pitch", "/currPad/sample/tone",
        "/currPad/sample/ampEnvelope/attack", "/currPad/sample/ampEnvelope/release", "/currPad/sample/start", "/currPad/sample/length",
        "/currPad/eq/band0/freq", "/currPad/eq/band0/gain", "/currPad/eq/band1/freq", "/currPad/eq/band1/gain",
        "/currPad/eq/band2/freq", "/currPad/eq/band2/gain", "/currPad/sample/chokeGroup", "/currPad/bus",
        "/mixer/channels/1/volume", "/mixer/channels/2/volume", "/mixer/channels/3/volume", "/mixer/channels/4/volume",
        "/mixer/channels/main/volume", "/sequencer/swing",
        // Koala 2.0.12's value controls, read from its code: beats per bar = value / 8 + 1 (1–16), seq snap = value / 32
        // (4 settings), keyboard scale = value × 11 / 128 (11 scales).
        "/sequencer/beatsPerBar", "/sequencer/seqSnap", "/keyboard/scale",
    ]
    static let channel = 14
    /// Each address's own key if Koala's map has none.
    static var defaults: [(address: String, key: KoalaKey)] {
        buttons.enumerated().map { ($1, KoalaKey(channel: channel, type: "note", value: $0)) }
            // Knob n is CC n + 1; from the 23rd on, CC 40… (CC 23–38 are the effects).
            + knobs.enumerated().map { ($1, KoalaKey(channel: channel, type: "cc", value: $0 < 22 ? $0 + 1 : 40 + $0 - 22)) }
    }

    static var settingsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Koala Sampler/settings", isDirectory: true) }
    static var songMappingURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Koala Sampler/default/midiMapping.json") }

    private static func key(of item: [String: Any]) -> KoalaKey? {
        guard let key = item["key"] as? [String: Any], let channel = key["channel"] as? Int,
              let type = key["type"] as? String, let value = key["value"] as? Int else { return nil }
        return KoalaKey(channel: channel, type: type, value: value)
    }
    /// Koala's map as address → key (later entries win, as a JSON object would keep them).
    static func mapping(at url: URL) -> [String: KoalaKey] {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: KoalaKey] = [:]
        for item in root["mappings"] as? [[String: Any]] ?? [] {
            if let address = item["address"] as? String, let key = key(of: item) { out[address] = key }
        }
        return out
    }
    /// The keys the Push sends: Koala's global map, with the song's own map over it.
    static func currentKeys() -> [String: KoalaKey] {
        mapping(at: settingsFolder.appendingPathComponent("midiMapping.json")).merging(mapping(at: songMappingURL)) { $1 }
    }

    /// Koala's effects take a value (0 = off, 1–127 = on at that amount), so v3 moves each effect that still
    /// has the Push's v2 note to a CC on channel 14 (23–38): then the touch strip can set its amount.
    static let fxCCBase = 23

    /// Every launch (Koala closed): Koala's MIDI settings, then its map, as the controller needs them.
    /// Koala writes its settings back when it quits and its MIDI Learn can grab any port's notes, so a one-time change
    /// doesn't last.
    static func prepare(mode: Mode = .mpcTouch) throws {
        let running = { NSRunningApplication.runningApplications(withBundleIdentifier: "com.elf-audio.koala-mac").contains { !$0.isTerminated } }
        if let repaired = try repairMap(settings: settingsFolder, isRunning: running), !repaired.isEmpty {
            PickerLog.write("Koala's MIDI map: the controller's keys written (\(repaired.count): \(repaired.prefix(12).joined(separator: ", "))\(repaired.count > 12 ? "…" : "")); backed up first")
        }
        if mode == .push2, let conflict = pushInputConflict() { throw failure(conflict) }
        if let changed = try enforceSettings(settings: settingsFolder, isRunning: running, mode: mode), !changed.isEmpty {
            PickerLog.write("Koala's MIDI settings set: \(changed.joined(separator: ", ")); defaults.json backed up first")
        }
        if mode == .push2, !settingsMatch(mode: mode) {
            throw failure("Koala's Push settings could not be prepared. Open Koala once to create its settings, then quit and choose Push again.")
        }
    }

    private static func pushInputConflict() -> String? {
        for (address, key) in currentKeys().sorted(by: { $0.key < $1.key }) {
            if key.channel == pushKeyboardChannel && key.type == "note" {
                return "Koala maps \(address) to keyboard channel \(pushKeyboardChannel). Reassign that learned mapping before starting Push to keep Chopper notes separate."
            }
            if key.channel == 1 && (key.type == "note" || key.type == "cc") {
                return "Koala maps \(address) to raw Push channel 1. Reassign that learned mapping before starting Push to avoid duplicate actions."
            }
        }
        return nil
    }

    /// Koala's MIDI settings the Push and the MPC need (tested on Koala, 2026-10-03): MIDI mapping on, the pads and the
    /// keyboard on channel 16 (keyboard keys only play on Koala's keyboard channel), "MIDI can select pads" off (on, pad
    /// hits moved keyboard mode to other pads), snap to scale off (it scrambled chops), Koala's built-in device maps off.
    /// Velocity stays enabled in sample and keyboard modes; FULL LEVEL controls the pad strike velocity in the bridge.
    static let requiredSettings: [(key: String, value: Any)] = [
        ("useMidiMapping", true), ("midiInputChannel", 16), ("keyboardMidiChannel", 16), ("midiNoteOffset", 36),
        // Built-in device maps off: Koala Link has no SP-404MKII link (that was Paper Picker's parked Push work).
        ("midiCanSelectNotes", false), ("keyboardMidiSnapToScale", false), ("builtInMidiMappingsEnabled", false),
        ("enableMidiVelocity", true), ("keyboardVelocityEnabled", true),
    ]
    static func requiredSettings(for mode: Mode) -> [(key: String, value: Any)] {
        requiredSettings.map { entry in
            guard mode == .push2 else { return entry }
            switch entry.key {
            case "keyboardMidiChannel": return (entry.key, pushKeyboardChannel)
            case "midiCanSelectNotes": return (entry.key, true)
            default: return entry
            }
        }
    }

    static func settingsMatch(mode: Mode) -> Bool {
        let keys = currentKeys()
        guard canonicalMap.allSatisfy({ keys[$0.address] == $0.key }) else { return false }
        if mode == .push2, pushInputConflict() != nil { return false }
        guard let data = try? Data(contentsOf: settingsFolder.appendingPathComponent("defaults.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return requiredSettings(for: mode).allSatisfy { entry in
            if let value = entry.value as? Bool { return d[entry.key] as? Bool == value }
            if let value = entry.value as? Int { return d[entry.key] as? Int == value }
            return false
        }
    }
    /// At every launch (Koala closed): `requiredSettings` written into defaults.json where they differ; the rest kept.
    /// Returns the settings changed (empty: nothing to do).
    @discardableResult
    static func enforceSettings(settings: URL, isRunning: () -> Bool, mode: Mode = .mpcTouch) throws -> [String]? {
        let fm = FileManager.default
        let url = settings.appendingPathComponent("defaults.json")
        guard let old = try? Data(contentsOf: url), var d = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { return nil }
        guard !isRunning() else { throw failure("Save and quit Koala before Koala Link sets its MIDI settings.") }
        var changed: [String] = []
        for (key, value) in requiredSettings(for: mode) {
            let same: Bool
            if let b = value as? Bool { same = (d[key] as? Bool) == b } else if let i = value as? Int { same = (d[key] as? Int) == i } else { same = false }
            if !same { d[key] = value; changed.append("\(key) = \(value)") }
        }
        guard !changed.isEmpty else { return [] }
        let backup = settings.deletingLastPathComponent().appendingPathComponent("Koala Touch backups/settings-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try old.write(to: backup.appendingPathComponent("defaults.json"), options: .atomic)
        guard !isRunning(), try Data(contentsOf: url) == old else { throw failure("Koala or its settings changed meanwhile; quit Koala and try again.") }
        try JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return changed
    }

    /// The keys the Push and the MPC send, address → key: the MPC profile (64 pads ch16 36–99, Q-Links, KEYS = E1/15,
    /// REC, PLAY), then the Push's buttons (channel 14 notes) and knobs and effects (channel 14 CCs).
    static var canonicalMap: [(address: String, key: KoalaKey)] {
        var out: [(String, KoalaKey)] = KoalaMIDIProfile.entries.compactMap { item in
            guard let address = item["address"] as? String, let key = key(of: item) else { return nil }
            return (address, key)
        }
        var addresses = Set(out.map(\.0)), used = Set(out.map(\.1))
        for (address, key) in defaults {
            let wanted = fxNames.map(fxAddress).firstIndex(of: address).map { KoalaKey(channel: channel, type: "cc", value: fxCCBase + $0) } ?? key
            guard !addresses.contains(address), !used.contains(wanted) else { continue }
            out.append((address, wanted)); addresses.insert(address); used.insert(wanted)
        }
        return out
    }

    /// At every launch (Koala closed): each address the Push or the MPC uses gets its key back if Koala lost it or
    /// relearned it. Koala hears every MIDI port (the Push's own, SoundFlow's HUI pings), so its MIDI Learn picks up
    /// those raw notes (2026-10-03: KEYS learned as SoundFlow's C-2/1, 44 pads as the Push's raw channel 1 notes). An
    /// entry another address learned onto one of these keys is removed; anything else learned stays. Backed up first.
    /// Returns the addresses put back (empty: nothing to do).
    @discardableResult
    static func repairMap(settings: URL, isRunning: () -> Bool) throws -> [String]? {
        let fm = FileManager.default
        let mappingURL = settings.appendingPathComponent("midiMapping.json")
        let old = fm.fileExists(atPath: mappingURL.path) ? try Data(contentsOf: mappingURL) : nil
        var root: [String: Any]
        if let old {
            guard let decoded = try JSONSerialization.jsonObject(with: old) as? [String: Any] else {
                throw failure("Koala's MIDI mapping format could not be read; no mapping changed.")
            }
            root = decoded
        } else {
            root = ["type": "midiMap", "mappings": []]
        }
        guard !isRunning() else { throw failure("Save and quit Koala before Koala Link checks its MIDI map.") }
        var list = root["mappings"] as? [[String: Any]] ?? []
        var repaired: [String] = []
        for (address, wanted) in canonicalMap {
            let matches = list.filter { $0["address"] as? String == address }
            let conflict = list.contains { $0["address"] as? String != address && key(of: $0) == wanted }
            if matches.count == 1, key(of: matches[0]) == wanted, !conflict { continue }
            // Keep exactly one owner per address/key; stale duplicates must not
            // override a correct entry later in Koala's saved mapping array.
            list.removeAll { $0["address"] as? String == address || key(of: $0) == wanted }
            let entry: [String: Any] = ["address": address, "key": ["channel": wanted.channel, "type": wanted.type, "value": wanted.value]]
            list.append(entry)
            repaired.append(address)
        }
        guard !repaired.isEmpty else { return [] }
        root["mappings"] = list
        let backup = settings.deletingLastPathComponent().appendingPathComponent("Koala Touch backups/repair-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try old?.write(to: backup.appendingPathComponent("midiMapping.json"), options: .atomic)
        guard !isRunning(), (fm.fileExists(atPath: mappingURL.path) ? try Data(contentsOf: mappingURL) : nil) == old else { throw failure("Koala or its MIDI map changed meanwhile; quit Koala and try again.") }
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: mappingURL, options: .atomic)
        return repaired
    }

    /// Koala's Keyboard Mode MIDI channel and note offset (defaults.json): where KEYS/CHOPS notes go.
    static func keyboardSettings(_ settings: URL = settingsFolder) -> (channel: Int, offset: Int, padChannel: Int) {
        guard let data = try? Data(contentsOf: settings.appendingPathComponent("defaults.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (16, 36, 16) }
        return ((d["keyboardMidiChannel"] as? Int) ?? 16, (d["midiNoteOffset"] as? Int) ?? 36, (d["midiInputChannel"] as? Int) ?? 16)
    }
    /// Koala's "MIDI can select pads" (defaults.json).
    static func canSelectPads(_ settings: URL = settingsFolder) -> Bool {
        guard let data = try? Data(contentsOf: settings.appendingPathComponent("defaults.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return (d["midiCanSelectNotes"] as? Bool) ?? true
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "KoalaTouch.KoalaPushProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    /// The map and the settings in a temporary folder. The map: what MIDI Learn did (KEYS learned as SoundFlow's C-2/1,
    /// a pad as the Push's raw channel 1 note, a pad dropped, an entry learned onto a controller key) is put back to the
    /// controller's keys, anything else learned stays, no key is used twice. The settings: Koala's own written back on
    /// quit are set again, the rest kept. Both refuse a running Koala, back up, and have nothing to do the second time.
    static func offlineSelfCheck() throws -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("paper-picker-map-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings", isDirectory: true)
        try fm.createDirectory(at: settings, withIntermediateDirectories: true)
        let mappingURL = settings.appendingPathComponent("midiMapping.json"), defaultsURL = settings.appendingPathComponent("defaults.json")
        var items = KoalaMIDIProfile.entries.filter { $0["address"] as? String != padAddress(0) }
        for i in items.indices {
            switch items[i]["address"] as? String {
            case "/keyboard/toggle": items[i]["key"] = ["channel": 1, "type": "note", "value": 0]
            case padAddress(8): items[i]["key"] = ["channel": 1, "type": "note", "value": 36]
            default: break
            }
        }
        items.append(["address": "/learned/elsewhere", "key": ["channel": 1, "type": "note", "value": 120]])
        items.append(["address": "/stole/undo", "key": ["channel": 14, "type": "note", "value": buttons.firstIndex(of: "/undo")!]])
        try JSONSerialization.data(withJSONObject: ["mappings": items, "type": "midiMap"]).write(to: mappingURL)
        let before = try Data(contentsOf: mappingURL)
        do { _ = try repairMap(settings: settings, isRunning: { true }); return false } catch { guard try Data(contentsOf: mappingURL) == before else { return false } }
        guard let fixed = try repairMap(settings: settings, isRunning: { false }),
              Set(fixed).isSuperset(of: ["/keyboard/toggle", padAddress(0), padAddress(8), "/undo"]) else { return false }
        let r = mapping(at: mappingURL)
        guard canonicalMap.allSatisfy({ r[$0.address] == $0.key }), r["/keyboard/toggle"] == KoalaKey(channel: 15, type: "note", value: 40),
              r[padAddress(8)] == KoalaKey(channel: 16, type: "note", value: 44),
              r["/learned/elsewhere"] == KoalaKey(channel: 1, type: "note", value: 120), r["/stole/undo"] == nil,
              Set(r.values).count == r.count,
              try repairMap(settings: settings, isRunning: { false }) == [] else { return false }
        let backups = root.appendingPathComponent("Koala Touch backups", isDirectory: true)
        guard let saved = try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil),
              saved.contains(where: { (try? Data(contentsOf: $0.appendingPathComponent("midiMapping.json"))) == before }) else { return false }
        try JSONSerialization.data(withJSONObject: ["midiCanSelectNotes": true, "keyboardMidiSnapToScale": true, "keyboardMidiChannel": 13,
                                                    "audioOutput": "keep-me"]).write(to: defaultsURL)
        do { _ = try enforceSettings(settings: settings, isRunning: { true }); return false } catch {}
        guard let set = try enforceSettings(settings: settings, isRunning: { false }), set.count == 9, !canSelectPads(settings),
              keyboardSettings(settings) == (16, 36, 16),
              let ds = try JSONSerialization.jsonObject(with: Data(contentsOf: defaultsURL)) as? [String: Any],
              ds["keyboardMidiSnapToScale"] as? Bool == false, ds["useMidiMapping"] as? Bool == true, ds["builtInMidiMappingsEnabled"] as? Bool == false, ds["audioOutput"] as? String == "keep-me",
              try enforceSettings(settings: settings, isRunning: { false }) == [] else { return false }
        return true
    }
}
