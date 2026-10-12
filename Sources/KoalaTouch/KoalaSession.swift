import AppKit

/// What Koala's session files say (the "default" folder Koala keeps its current song in). Koala writes them when it
/// autosaves, so they lag what Koala shows; the Push uses them for pad names, choppers and starting knob values.
struct KoalaSession: Equatable {
    struct Pad: Equatable {
        var label = "", loaded = false, chopper = false
        var vol = 1.0, pan = 0.5, pitch = 0.0, tone = 0.0, attack = 0.0, release = 0.0
        var start = 0.0, end: Double?, frames: Double?
        var eqFreq = [100.0, 1000.0, 8000.0], eqGain = [0.0, 0.0, 0.0]
        var choke = 0, bus = -1
        var oneShot = false, loop = false, reverse = false, muted = false
        /// The sample file (`sampler/<id>.wav`), Koala's waveform zoom (frames), and a CHOPPER's slices.
        var sampleID: Int?, zoomStart: Double?, zoomEnd: Double?
        var slices: [Double] = [], nextMode = false
        var eqTypes = ["lowshelf", "peaking", "highshelf"], eqQ = [1.0, 1.0, 1.0], eqOn = false
    }
    /// A sequence note: the pad, where it starts and how long it is (beats), its pitch and velocity, and
    /// the chop it plays when Koala stored one.
    struct Note: Equatable {
        var pad: Int, beat: Double, length: Double, pitch = 0.0, velocity = 100.0, slice: Int? = nil
    }
    var pads: [Int: Pad] = [:]
    var bpm: Double?, swing = 0.0, sequence = 0, bars: [Int] = [], quantizing = false
    var notes: [[Note]] = [], beatsPerBar = 4
    var quantizeDivision = 16, sequenceSnap = "None", countInBars = 0
    var busVolume = [0.0, 0.0, 0.0, 0.0], mainVolume = 0.0
    var busMute = [false, false, false, false], busSolo = [false, false, false, false], mainMute = false
    /// The effects in each bus's chain (and the main bus's), by name; a bypassed one ends in " ·OFF".
    var busFX: [[String]] = [[], [], [], []], mainFX: [String] = []
    var fx = KoalaPushProfile.fxNames, fxHold = false
    /// Each Perform effect's amount (0…1), in `fx` order.
    var fxValues: [Double] = Array(repeating: 0, count: 16)
    var keyboard = false, selectedPad: Int?, name = ""
    /// Koala's keyboard scale by name (song.json), e.g. "Chromatic".
    var scale: String?

    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Koala Sampler/default", isDirectory: true) }
    static let files = ["sampler/sampler.json", "sequence.json", "mixer.json", "fx.json", "song.json"]

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
    private static func flag(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" ? true : s == "false" ? false : nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    /// `frames` gives a sample's length (by its id) for start/length.
    static func read(_ folder: URL = folder, frames: (Int) -> Double? = { _ in nil }) -> KoalaSession {
        readSaved(folder, frames: frames) ?? KoalaSession()
    }

    /// Koala writes several files per save. Keep the previous display if any
    /// document is missing or halfway through a write.
    static func readSaved(_ folder: URL = folder, frames: (Int) -> Double? = { _ in nil }) -> KoalaSession? {
        var documents: [String: [String: Any]] = [:]
        for name in files {
            guard let document = json(folder.appendingPathComponent(name)) else { return nil }
            documents[name] = document
        }
        var s = KoalaSession()
        if let sampler = documents["sampler/sampler.json"] {
            var names: [Int: String] = [:]
            for sample in sampler["samples"] as? [[String: Any]] ?? [] {
                guard let id = number(sample["id"]).map({ Int($0) }), let path = (sample["metadata"] as? [String: Any])?["originalPath"] as? String, !path.isEmpty else { continue }
                names[id] = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            }
            for entry in sampler["pads"] as? [[String: Any]] ?? [] {
                guard let index = number(entry["pad"]).map({ Int($0) }), (0..<64).contains(index) else { continue }
                let chopper = (entry["synth"] as? String)?.uppercased() == "CHOPPER"
                let synth = entry["synthParams"] as? [String: Any]
                let params = chopper ? (synth?["padParams"] as? [String: Any] ?? entry) : entry
                var pad = Pad()
                pad.chopper = chopper
                let id = number(entry["sampleId"]).map { Int($0) }
                pad.loaded = id != nil || (entry["type"] as? String) == "synth"
                let raw = ((params["label"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                pad.label = (raw.isEmpty ? nil : (raw as NSString).deletingPathExtension).flatMap { $0.isEmpty ? nil : $0 }
                    ?? id.flatMap { names[$0] } ?? (chopper ? "CHOPPER" : (entry["synth"] as? String) ?? "")
                pad.vol = number(params["vol"]) ?? 1
                pad.pan = number(params["pan"]) ?? 0.5
                pad.pitch = number(params["pitch"]) ?? 0
                pad.tone = number(params["tone"]) ?? number(entry["tone"]) ?? 0
                pad.attack = number(entry["attack"]) ?? 0
                pad.release = number(entry["release"]) ?? 0
                pad.start = number(entry["start"]) ?? 0
                pad.end = number(entry["end"])
                pad.frames = id.flatMap(frames)
                pad.sampleID = id
                pad.zoomStart = number(entry["zoomStart"])
                pad.zoomEnd = number(entry["zoomEnd"])
                if chopper {
                    pad.slices = ((entry["chops"] as? [String: Any])?["slices"] as? [[String: Any]] ?? []).compactMap { number($0["start"]) }.sorted()
                    pad.nextMode = (number(synth?["TRIGGER MODE"]) ?? 0) >= 0.5
                    pad.oneShot = (number(synth?["ONE SHOT"]) ?? 1) >= 0.5
                }
                if let eq = params["eq"] as? [String: Any] {
                    pad.eqOn = flag(eq["enabled"]) ?? false
                    for (i, band) in ["lo", "mid", "hi"].enumerated() {
                        if let b = eq[band] as? [String: Any] {
                            if let f = number(b["freq"]) { pad.eqFreq[i] = f }
                            if let g = number(b["gain"]) { pad.eqGain[i] = g }
                            if let q = number(b["q"]) { pad.eqQ[i] = q }
                            if let t = b["type"] as? String { pad.eqTypes[i] = t }
                        }
                    }
                }
                pad.choke = Int(number(entry["chokeGroup"]) ?? 0)
                pad.bus = Int(number(params["bus"]) ?? -1)
                if !chopper { pad.oneShot = flag(entry["oneshot"]) ?? false }
                pad.loop = flag(entry["looping"]) ?? false
                pad.reverse = flag(entry["reverse"]) ?? false
                pad.muted = flag(params["muted"]) ?? false
                s.pads[index] = pad
            }
        }
        if let seq = documents["sequence.json"] {
            s.bpm = number(seq["bpm"])
            s.swing = number(seq["swing"]) ?? 0
            s.sequence = Int(number(seq["currSequenceId"]) ?? 0)
            s.quantizing = flag(seq["quantizing"]) ?? false
            s.beatsPerBar = max(1, Int(number(seq["beatsPerBar"]) ?? 4))
            s.quantizeDivision = max(1, Int(number(seq["quantizeDivision"]) ?? 16))
            s.sequenceSnap = seq["seqSnap"] as? String ?? "None"
            for entry in seq["sequences"] as? [[String: Any]] ?? [] {
                let pattern = ((entry["noteSequence"] as? [String: Any])?["pattern"] as? [String: Any]) ?? [:]
                s.bars.append(max(1, Int(number(pattern["numBars"]) ?? 1)))
                // Koala counts 4096 ticks a beat.
                s.notes.append((pattern["notes"] as? [[String: Any]] ?? []).compactMap { n in
                    guard let pad = number(n["num"]).map({ Int($0) }), (0..<64).contains(pad), let offset = number(n["timeOffset"]) else { return nil }
                    let slice = number(n["subPad"]).map { Int($0) }.flatMap { $0 >= 0 ? $0 : nil }
                    return Note(pad: pad, beat: offset / 4096, length: max(1, number(n["length"]) ?? 1024) / 4096,
                                pitch: number(n["pitch"]) ?? 0, velocity: number(n["vel"]) ?? 100, slice: slice)
                }.sorted { $0.beat < $1.beat })
            }
        }
        if let mixer = documents["mixer.json"] {
            func chain(_ bus: [String: Any]) -> [String] {
                (bus["chain"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { fx in
                    guard let name = fx["name"] as? String else { return nil }
                    return flag(fx["bypass"]) == true ? name + " ·OFF" : name
                }
            }
            for (i, bus) in (mixer["buses"] as? [[String: Any]] ?? []).prefix(4).enumerated() {
                s.busVolume[i] = number(bus["volume"]) ?? 0
                s.busMute[i] = flag(bus["mute"]) ?? false
                s.busSolo[i] = flag(bus["solo"]) ?? false
                s.busFX[i] = chain(bus)
            }
            if let main = mixer["master"] as? [String: Any] {
                s.mainVolume = number(main["volume"]) ?? 0
                s.mainMute = flag(main["mute"]) ?? false
                s.mainFX = chain(main)
            }
        }
        if let fx = documents["fx.json"] {
            s.fxHold = flag(fx["hold"]) ?? false
            if let buses = fx["buses"] as? [String: Any] {
                let entries = ["vanilla", "strawberry"].flatMap { buses[$0] as? [[String: Any]] ?? [] }
                let names = entries.compactMap { $0["name"] as? String }
                if names.count == 16, names.allSatisfy({ KoalaPushProfile.fxNames.contains($0.uppercased()) }) {
                    s.fx = names.map { $0.uppercased() }
                    s.fxValues = entries.map { number($0["value"]) ?? 0 }
                }
            }
        }
        if let song = documents["song.json"] {
            s.keyboard = flag(song["keyboardMode"]) ?? false
            s.selectedPad = number(song["selectedPad"]).map { Int($0) }
            s.name = song["name"] as? String ?? ""
            s.scale = song["keyboardScale"] as? String
        }
        if let settings = json(KoalaPushProfile.settingsFolder.appendingPathComponent("defaults.json")) {
            s.countInBars = max(0, Int(number(settings["countInBars"]) ?? 0))
        }
        return s
    }
}
