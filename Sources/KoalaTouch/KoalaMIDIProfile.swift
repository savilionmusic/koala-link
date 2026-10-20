import AppKit
import Foundation

/// One-time Koala configuration. Never writes while Koala is running, and
/// retains the user's original files before installing the translated inputs.
enum KoalaMIDIProfile {
    private static let revision = "mpc-64-v1"
    private static func entry(_ address: String, _ channel: Int, _ type: String, _ value: Int) -> [String: Any] {
        ["address": address, "key": ["channel": channel, "type": type, "value": value]]
    }

    static var entries: [[String: Any]] {
        var result: [[String: Any]] = []
        for (bankIndex, bank) in ["A", "B", "C", "D"].enumerated() {
            for slot in 0..<16 {
                result.append(entry("/pads/\(bank)\(slot + 1)", 16, "note", 36 + bankIndex * 16 + slot))
            }
        }
        for (index, address) in ["/currPad/sample/start", "/currPad/sample/length", "/currPad/volume", "/currPad/pitch"].enumerated() {
            result.append(entry(address, 15, "cc", index + 1))
        }
        result.append(entry("/keyboard/toggle", 15, "note", 0x28))
        result.append(entry("/sequencer/record/toggle", 15, "note", 0x49))
        result.append(entry("/sequencer/play/toggle", 15, "note", 0x52))
        return result
    }

    static func prepare() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = home.appendingPathComponent("Music/Koala Sampler/settings", isDirectory: true)
        let receipt = home.appendingPathComponent("Library/Application Support/Koala Touch/\(revision).json")
        if try install(settings: settings, receipt: receipt, isRunning: {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.elf-audio.koala-mac").contains { !$0.isTerminated }
        }) {
            PickerLog.write("Installed Koala 64-pad profile · Ch16 pads, Ch15 controls; original files backed up")
        }
    }

    @discardableResult
    private static func install(settings: URL, receipt: URL, isRunning: () -> Bool) throws -> Bool {
        let fm = FileManager.default
        // Keep later intentional user edits: this is a migration, not an
        // every-launch reset of MIDI Learn or other Koala preferences.
        if fm.fileExists(atPath: receipt.path) { return false }
        guard !isRunning() else { throw failure("Save and quit Koala before installing its MPC mapping.") }
        let defaultsURL = settings.appendingPathComponent("defaults.json")
        let mappingURL = settings.appendingPathComponent("midiMapping.json")
        let oldDefaults = try Data(contentsOf: defaultsURL)
        let oldMapping = fm.fileExists(atPath: mappingURL.path) ? try Data(contentsOf: mappingURL) : nil
        guard var defaults = try JSONSerialization.jsonObject(with: oldDefaults) as? [String: Any] else {
            throw failure("Koala's settings format could not be read; no settings changed.")
        }
        let mapping: [String: Any]
        if let oldMapping {
            guard let decoded = try JSONSerialization.jsonObject(with: oldMapping) as? [String: Any] else {
                throw failure("Koala's MIDI mapping format could not be read; no settings changed.")
            }
            mapping = decoded
        } else {
            mapping = ["type": "midiMap", "mappings": []]
        }
        var replacement = entries
        let replaced = Set(entries.compactMap { $0["address"] as? String })
        func signature(_ item: [String: Any]) -> String {
            guard let key = item["key"] as? [String: Any] else { return "invalid" }
            return "\(key["channel"] ?? "?")/\(key["type"] ?? "?")/\(key["value"] ?? "?")"
        }
        let occupied = Set(entries.map(signature))
        for item in mapping["mappings"] as? [[String: Any]] ?? [] {
            guard let address = item["address"] as? String else { throw failure("An unknown Koala mapping needs review; no settings changed.") }
            if address.hasPrefix("/pads/") || replaced.contains(address) { continue }
            let channel = (item["key"] as? [String: Any])?["channel"] as? Int
            guard let channel, ![0, 1, 10].contains(channel), !occupied.contains(signature(item)) else {
                throw failure("An extra Koala mapping conflicts with the MPC profile; no settings changed.")
            }
            replacement.append(item)
        }
        defaults["useMidiMapping"] = true
        defaults["midiInputChannel"] = 16
        defaults["keyboardMidiChannel"] = 16
        defaults["midiNoteOffset"] = 36
        defaults["midiCanSelectNotes"] = true
        defaults["builtInMidiMappingsEnabled"] = false
        var newMapping = mapping
        newMapping["mappings"] = replacement
        newMapping["type"] = "midiMap"
        let newDefaultsData = try JSONSerialization.data(withJSONObject: defaults, options: [.prettyPrinted, .sortedKeys])
        let newMappingData = try JSONSerialization.data(withJSONObject: newMapping, options: [.prettyPrinted, .sortedKeys])
        let backup = settings.deletingLastPathComponent().appendingPathComponent("Koala Touch backups/\(revision)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try oldDefaults.write(to: backup.appendingPathComponent("defaults.json"), options: .atomic)
        try oldMapping?.write(to: backup.appendingPathComponent("midiMapping.json"), options: .atomic)
        try fm.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !isRunning(), try Data(contentsOf: defaultsURL) == oldDefaults,
              (fm.fileExists(atPath: mappingURL.path) ? try Data(contentsOf: mappingURL) : nil) == oldMapping else {
            throw failure("Koala or its settings changed during preparation; retry after quitting Koala.")
        }
        do {
            try newMappingData.write(to: mappingURL, options: .atomic)
            try newDefaultsData.write(to: defaultsURL, options: .atomic)
            let record = try JSONSerialization.data(withJSONObject: ["revision": revision, "backup": backup.path], options: .prettyPrinted)
            try record.write(to: receipt, options: .atomic)
        } catch {
            if let oldMapping { try oldMapping.write(to: mappingURL, options: .atomic) }
            else if fm.fileExists(atPath: mappingURL.path) { try fm.removeItem(at: mappingURL) }
            try oldDefaults.write(to: defaultsURL, options: .atomic)
            throw error
        }
        return true
    }

    private static func failure(_ text: String) -> NSError {
        NSError(domain: "KoalaTouch.KoalaProfile", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func offlineSelfCheck() throws -> Bool {
        // Check routed messages against the actual Koala assignment, not just
        // the mapper in isolation. No CoreMIDI client or events are created.
        var router = KoalaControlRouter()
        for bank in 0..<4 {
            let selected = router.consume([0x90, UInt8(0x23 + bank), 127, 0x80, UInt8(0x23 + bank), 0], source: 1, role: .publicControl, routing: true)
            guard selected == [.padBank(bank)] else { return false }
            for (slot, raw) in KoalaPadMapper.physicalPadOrder.enumerated() {
                let mapping = entries[bank * 16 + slot]
                guard let key = mapping["key"] as? [String: Any], let value = key["value"] as? Int,
                      key["channel"] as? Int == 16 else { return false }
                let expected: [KoalaControlRouter.Event] = [.midi([0x9F, UInt8(value), 100]), .midi([0x8F, UInt8(value), 0])]
                guard router.consume([0x99, raw, 100, 0x89, raw, 0], source: 1, role: .publicControl, routing: true) == expected else { return false }
            }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("KoalaTouch-Profile-Test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings")
        let receipt = root.appendingPathComponent("receipt.json")
        try fm.createDirectory(at: settings, withIntermediateDirectories: true)
        let defaults = settings.appendingPathComponent("defaults.json")
        let mapping = settings.appendingPathComponent("midiMapping.json")
        let original = Data("{\"audioOutput\":\"keep-me\",\"keyboardMidiChannel\":0}".utf8)
        try original.write(to: defaults)
        try JSONSerialization.data(withJSONObject: ["mappings": [entry("/pads/A1", 10, "note", 37)]]).write(to: mapping)
        do { _ = try install(settings: settings, receipt: receipt, isRunning: { true }); return false }
        catch { guard try Data(contentsOf: defaults) == original else { return false } }
        guard try install(settings: settings, receipt: receipt, isRunning: { false }),
              let configured = try JSONSerialization.jsonObject(with: Data(contentsOf: defaults)) as? [String: Any],
              configured["audioOutput"] as? String == "keep-me",
              configured["keyboardMidiChannel"] as? Int == 16,
              let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: mapping)) as? [String: Any],
              (migrated["mappings"] as? [[String: Any]])?.count == 71,
              let record = try JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: String],
              let backup = record["backup"],
              try Data(contentsOf: URL(fileURLWithPath: backup).appendingPathComponent("defaults.json")) == original else { return false }
        // A second launch must leave intentional edits alone.
        try original.write(to: defaults)
        guard try !install(settings: settings, receipt: receipt, isRunning: { false }),
              try Data(contentsOf: defaults) == original else { return false }
        return true
    }
}
