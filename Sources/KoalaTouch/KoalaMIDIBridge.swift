import CoreFoundation
import CoreMIDI
import Foundation
import MPCControllerSetup

/// Pure MIDI note assignment logic. Kept independent of CoreMIDI so its mapping
/// and held-note behavior can be checked without connecting to a device.
struct KoalaPadMapper {
    static let sampleFirstNote = 36
    // Koala's Chopper starts at its untransposed keyboard note, MIDI 60 (C3).
    // A lower C happens to wrap to chop 1 at some chop counts, but rotates
    // the slices at others. Confirmed with a 128-chop sample on 2026-10-11.
    static let chopperFirstNote = 60
    static let physicalPadOrder: [UInt8] = [0x25,0x24,0x2A,0x52, 0x28,0x26,0x2E,0x2C,
                                           0x30,0x2F,0x2D,0x2B, 0x31,0x37,0x33,0x35]
    private(set) var heldNotes: [UInt8: UInt8] = [:]

    static func mappedNote(for rawNote: UInt8, bank: Int, chopperMode: Bool = false) -> UInt8? {
        guard (0..<4).contains(bank), let index = physicalPadOrder.firstIndex(of: rawNote) else { return nil }
        return UInt8((chopperMode ? chopperFirstNote : sampleFirstNote) + bank * 16 + index)
    }

    mutating func noteOn(_ rawNote: UInt8, bank: Int, chopperMode: Bool = false) -> UInt8? {
        guard let mapped = Self.mappedNote(for: rawNote, bank: bank, chopperMode: chopperMode) else { return nil }
        // A repeated note-on must not replace the captured bank/mode assignment.
        guard heldNotes[rawNote] == nil else { return nil }
        heldNotes[rawNote] = mapped
        return mapped
    }

    mutating func noteOff(_ rawNote: UInt8) -> UInt8? { heldNotes.removeValue(forKey: rawNote) }
    func mappedHeldNote(for rawNote: UInt8) -> UInt8? { heldNotes[rawNote] }
    mutating func releaseAll() -> [UInt8] {
        let notes = Array(heldNotes.values)
        heldNotes.removeAll()
        return notes
    }

    static func offlineSelfCheck() -> Bool {
        for bank in 0..<4 {
            for (index, rawNote) in physicalPadOrder.enumerated() {
                guard mappedNote(for: rawNote, bank: bank) == UInt8(36 + bank * 16 + index) else { return false }
            }
        }
        var tracker = KoalaPadMapper()
        guard tracker.noteOn(0x25, bank: 0) == 36 else { return false }
        // The bank may change before release; the captured assignment survives.
        guard mappedNote(for: 0x25, bank: 1) == 52 else { return false }
        guard tracker.noteOn(0x25, bank: 1) == nil else { return false }
        return tracker.noteOff(0x25) == 36 && tracker.heldNotes.isEmpty
    }
}

/// Owns a raw MPC session only while Paper Cut is closed. Public and hidden
/// Private use separate decode/held state, just as in Paper Cut's MIDIInput.
final class KoalaMIDIBridge {
    var onStatus: ((String) -> Void)?
    var onPadBankChanged: ((Int) -> Void)?
    var onChopperModeChanged: ((Bool) -> Void)?
    /// Every message the bridge sends Koala, on the main queue. Watching only: the Push shows the MPC's
    /// hits and follows its 16 LEVELS button.
    var onForward: (([UInt8]) -> Void)?
    var currentPadBank: Int { queue.sync { router.padBank } }
    var currentChopperMode: Bool { queue.sync { router.chopperMode } }

    private final class Connection {
        weak var owner: KoalaMIDIBridge?
        let endpoint: MIDIEndpointRef
        let role: KoalaControlRouter.Role
        init(owner: KoalaMIDIBridge, endpoint: MIDIEndpointRef, role: KoalaControlRouter.Role) {
            self.owner = owner; self.endpoint = endpoint; self.role = role
        }
    }
    private let queue = DispatchQueue(label: "KoalaTouch.MIDIInput", qos: .userInteractive)
    // LED sends contain 20 ms pacing. Never block pad decoding behind them.
    private let controllerQueue = DispatchQueue(label: "KoalaTouch.ControllerOutput", qos: .userInitiated)
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var virtualSource = MIDIEndpointRef()
    private var reconnectTimer: DispatchSourceTimer?
    private var connections: [Connection] = []
    private var retiredConnections: [Connection] = []
    private var router = KoalaControlRouter()
    private var isStarted = false
    private var setupGeneration = 0
    private var controllerReady = false
    private var controllerSetupPending = false
    private var ledRefreshPending = false
    private var readyHandlers: [() -> Void] = []
    private var routingEnabled = false

    func selectPadBank(_ bank: Int) {
        queue.async { [weak self] in
            guard let self, self.isStarted, self.routingEnabled else { return }
            self.handle(self.router.selectPadBank(bank))
        }
    }

    /// A native touchscreen keyboard press already toggles Koala. Update only
    /// our note/bank state; sending a second MIDI toggle would undo the press.
    func keyboardToggledOnScreen() {
        queue.async { [weak self] in
            guard let self, self.isStarted, self.routingEnabled else { return }
            self.handle(self.router.setChopperMode(!self.router.chopperMode), origin: "native keyboard click")
        }
    }

    /// Koala restores this autosaved song on launch, including keyboard mode.
    /// Read it while Koala is closed so our first physical toggle stays in sync.
    func prepareForKoalaLaunch() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Koala Sampler/default/song.json")
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let keyboard = saved?["keyboardMode"] as? Bool ?? false
        let sampleBank = max(0, min(3, (saved?["selectedPad"] as? Int ?? 0) / 16))
        queue.sync {
            guard isStarted, !routingEnabled else { return }
            handle(router.restoreSongControls(sampleBank: sampleBank, keyboardMode: keyboard), origin: "restored song")
        }
    }

    func start(onReady: (() -> Void)? = nil) throws {
        guard KoalaPadMapper.offlineSelfCheck(), KoalaControlRouter.offlineSelfCheck() else {
            throw NSError(domain: "KoalaTouch.MIDI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "The offline MPC bank decoder check failed"])
        }
        try queue.sync {
            if let onReady {
                if controllerReady { DispatchQueue.main.async(execute: onReady) }
                else { readyHandlers.append(onReady) }
            }
            guard !isStarted else { return }
            let clientStatus = MIDIClientCreate("Koala Link" as CFString, nil, nil, &client)
            guard clientStatus == noErr else { throw Self.error("MIDIClientCreate", clientStatus) }
            let inputStatus = MIDIInputPortCreateWithBlock(client, "Koala Link Input" as CFString, &inputPort) { packetList, ref in
                guard let ref else { return }
                let connection = Unmanaged<Connection>.fromOpaque(ref).takeUnretainedValue()
                guard let owner = connection.owner else { return }
                // Copy the variable-sized payload while CoreMIDI owns it.
                let packets = Self.messages(in: packetList)
                owner.queue.async {
                    guard owner.isStarted, owner.connections.contains(where: { $0 === connection }) else { return }
                    for bytes in packets {
                        let events = owner.router.consume(bytes, source: connection.endpoint,
                                                          role: connection.role, routing: owner.routingEnabled)
                        owner.handle(events, origin: connection.role == .publicControl ? "Public MIDI" : "Private MIDI")
                        for number in owner.router.takeNewHolds() {
                            owner.queue.asyncAfter(deadline: .now() + KoalaControlRouter.holdToSolo) { [weak owner] in
                                guard let owner, owner.isStarted else { return }
                                owner.handle(owner.router.holdElapsed(number))
                            }
                        }
                    }
                }
            }
            guard inputStatus == noErr else { disposeMIDI(); throw Self.error("MIDIInputPortCreate", inputStatus) }
            let sourceStatus = MIDISourceCreate(client, "Koala Link" as CFString, &virtualSource)
            guard sourceStatus == noErr else { disposeMIDI(); throw Self.error("MIDISourceCreate", sourceStatus) }
            isStarted = true
            refreshConnections()
            reconnectTimer = DispatchSource.makeTimerSource(queue: queue)
            reconnectTimer?.schedule(deadline: .now() + 1, repeating: 1)
            reconnectTimer?.setEventHandler { [weak self] in self?.refreshConnections() }
            reconnectTimer?.resume()
        }
    }

    func stop() {
        let wasStarted = queue.sync { () -> Bool in
            guard isStarted else { return false }
            handle(router.resetConnections())
            reconnectTimer?.cancel(); reconnectTimer = nil
            for connection in connections {
                MIDIPortDisconnectSource(inputPort, connection.endpoint)
                connection.owner = nil
                retiredConnections.append(connection)
            }
            connections.removeAll()
            readyHandlers.removeAll()
            controllerReady = false; controllerSetupPending = false; ledRefreshPending = false
            setupGeneration += 1
            routingEnabled = false; isStarted = false
            if virtualSource != 0 { MIDIEndpointDispose(virtualSource) }
            virtualSource = 0
            disposeMIDI()
            // Port disposal ends callbacks before the refcon objects go away.
            retiredConnections.removeAll()
            return true
        }
        if wasStarted { controllerQueue.sync { controller_shutdown() } }
    }

    func setRoutingEnabled(_ enabled: Bool) {
        queue.sync {
            if !enabled { handle(router.releaseHeld()) }
            routingEnabled = enabled
        }
    }

    private func disposeMIDI() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0; client = 0
    }

    private func refreshConnections() {
        guard isStarted else { return }
        let sources = Self.touchSources()
        let found = Set(sources.map { $0.endpoint })
        if found != Set(connections.map { $0.endpoint }) {
            handle(router.resetConnections())
            for old in connections {
                MIDIPortDisconnectSource(inputPort, old.endpoint)
                old.owner = nil; retiredConnections.append(old)
            }
            connections.removeAll()
            for source in sources {
                let connection = Connection(owner: self, endpoint: source.endpoint, role: source.role)
                if MIDIPortConnectSource(inputPort, source.endpoint, Unmanaged.passUnretained(connection).toOpaque()) == noErr {
                    connections.append(connection)
                }
            }
            setupGeneration += 1
            controllerReady = false; controllerSetupPending = false; ledRefreshPending = false
            status(connections.isEmpty ? "MPC Touch disconnected; waiting to reconnect" : "MPC Touch connected (Public and Private)")
        }
        if !connections.isEmpty, !controllerReady, !controllerSetupPending {
            controllerSetupPending = true
            let generation = setupGeneration
            controllerQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                let banks: (Int, Int, Bool, Bool)? = self.queue.sync {
                    guard self.isStarted, self.setupGeneration == generation, !self.connections.isEmpty else { return nil }
                    return (self.router.padBank, self.router.qlinkBank, self.router.chopperMode, self.router.fullLevel)
                }
                guard let banks else { return }
                let sent = controller_initialize(Int32(banks.0), Int32(banks.1)) == 0
                if sent {
                    _ = controller_set_button_light(0x28, banks.2 ? 2 : 0)
                    _ = controller_set_button_light(0x27, banks.3 ? 2 : 0)
                }
                self.queue.async {
                    guard self.isStarted, self.setupGeneration == generation else { return }
                    self.controllerReady = sent; self.controllerSetupPending = false
                    self.status(sent ? "MPC controller setup sent" : "MPC MIDI setup failed; retrying")
                    if sent {
                        let callbacks = self.readyHandlers; self.readyHandlers.removeAll()
                        DispatchQueue.main.async { callbacks.forEach { $0() } }
                        // A selector can change while the paced initialization runs.
                        if banks.0 != self.router.padBank || banks.1 != self.router.qlinkBank || banks.2 != self.router.chopperMode || banks.3 != self.router.fullLevel { self.updateBankLEDs() }
                    }
                }
            }
        }
    }

    static func messages(in packetList: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
        var packets: [[UInt8]] = []
        let offset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        var packet = UnsafeMutablePointer(mutating: UnsafeRawPointer(packetList).advanced(by: offset).assumingMemoryBound(to: MIDIPacket.self))
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        for index in 0..<packetList.pointee.numPackets {
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)
            packets.append(Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.length))))
            if index + 1 < packetList.pointee.numPackets { packet = MIDIPacketNext(packet) }
        }
        return packets
    }

    static func packetSelfCheck() -> Bool {
        let capacity = 2048
        let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: MIDIPacketList.self)
        let first = MIDIPacketListInit(list)
        let long = [UInt8(0xF0)] + Array(repeating: UInt8(0x47), count: 600) + [0xF7]
        let next = long.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, first, 1, $0.count, $0.baseAddress!) }
        let following: [UInt8] = [0x99, 0x25, 100, 0x89, 0x25, 0]
        _ = following.withUnsafeBufferPointer { MIDIPacketListAdd(list, capacity, next, 2, $0.count, $0.baseAddress!) }
        return messages(in: UnsafePointer(list)) == [long, following]
    }

    private func handle(_ events: [KoalaControlRouter.Event], origin: String? = nil) {
        for event in events {
            switch event {
            case .midi(let bytes):
                publish(bytes)
                DispatchQueue.main.async { [weak self] in self?.onForward?(bytes) }
            case .padBank(let bank):
                updateBankLEDs()
                let first = (router.chopperMode ? KoalaPadMapper.chopperFirstNote : KoalaPadMapper.sampleFirstNote) + bank * 16
                PickerLog.write("MPC pad bank \(String(UnicodeScalar(65 + bank)!)) · \(router.chopperMode ? "Chopper" : "Samples"), Ch16 notes \(first)–\(first + 15)")
                if routingEnabled { DispatchQueue.main.async { [weak self] in self?.onPadBankChanged?(bank) } }
            case .chopperMode(let enabled):
                KoalaPerformanceFeed.shared.setChopperMode(enabled)
                if let origin { PickerLog.write("Keyboard mode \(enabled ? "on" : "off") · source: \(origin)") }
                updateBankLEDs()
                status(enabled ? "16 Levels · Chopper · banks A–D play chops 1–64, MIDI notes 60–123" : "16 Levels off · sample pads restored")
                if routingEnabled { DispatchQueue.main.async { [weak self] in self?.onChopperModeChanged?(enabled) } }
            case .fullLevel(let enabled):
                updateBankLEDs()
                status(enabled ? "FULL LEVEL on · pad velocity 127" : "FULL LEVEL off · natural pad velocity")
                PickerLog.write("FULL LEVEL \(enabled ? "on · velocity 127" : "off · natural velocity")")
            case .qlinkBank(let bank):
                updateBankLEDs()
                PickerLog.write("MPC Q-Link bank \(String(UnicodeScalar(65 + bank)!)) · Ch15 CC\(bank * 4 + 1)–\(bank * 4 + 4)")
            }
        }
    }

    private func updateBankLEDs() {
        guard controllerReady, !ledRefreshPending else { return }
        ledRefreshPending = true
        let generation = setupGeneration
        controllerQueue.async { [weak self] in
            guard let self else { return }
            let banks: (Int, Int, Bool, Bool)? = self.queue.sync {
                guard self.isStarted, self.setupGeneration == generation else { return nil }
                return (self.router.padBank, self.router.qlinkBank, self.router.chopperMode, self.router.fullLevel)
            }
            guard let banks else { return }
            _ = controller_refresh_banks(Int32(banks.0), Int32(banks.1))
            _ = controller_set_button_light(0x28, banks.2 ? 2 : 0)
            _ = controller_set_button_light(0x27, banks.3 ? 2 : 0)
            self.queue.async {
                guard self.isStarted, self.setupGeneration == generation else { return }
                self.ledRefreshPending = false
                if banks.0 != self.router.padBank || banks.1 != self.router.qlinkBank || banks.2 != self.router.chopperMode || banks.3 != self.router.fullLevel { self.updateBankLEDs() }
            }
        }
    }

    private func publish(_ bytes: [UInt8]) {
        guard virtualSource != 0, !bytes.isEmpty else { return }
        var storage = [UInt8](repeating: 0, count: 512)
        storage.withUnsafeMutableBytes { raw in
            guard let list = raw.baseAddress?.assumingMemoryBound(to: MIDIPacketList.self) else { return }
            let packet = MIDIPacketListInit(list)
            _ = bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list, raw.count, packet, 0, $0.count, $0.baseAddress!) }
            MIDIReceived(virtualSource, list)
        }
        KoalaPerformanceFeed.shared.observe(bytes)
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }

    private static func touchSources() -> [(endpoint: MIDIEndpointRef, role: KoalaControlRouter.Role)] {
        var result: [(MIDIEndpointRef, KoalaControlRouter.Role)] = []
        func add(_ endpoint: MIDIEndpointRef, _ entity: MIDIEntityRef) {
            let name = stringProperty(entity, kMIDIPropertyName)
            guard !name.localizedCaseInsensitiveContains("MIDI Port") else { return }
            let priv = integerProperty(entity, kMIDIPropertyPrivate) == 1 || integerProperty(endpoint, kMIDIPropertyPrivate) == 1 || name.localizedCaseInsensitiveContains("Private")
            let pub = name.localizedCaseInsensitiveContains("Public") || stringProperty(endpoint, kMIDIPropertyName).localizedCaseInsensitiveContains("Public")
            guard (priv || pub), !result.contains(where: { $0.0 == endpoint }) else { return }
            result.append((endpoint, priv ? .privateSelector : .publicControl))
        }
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            var entity = MIDIEntityRef(), device = MIDIDeviceRef()
            guard MIDIEndpointGetEntity(endpoint, &entity) == noErr, entity != 0,
                  MIDIEntityGetDevice(entity, &device) == noErr, isTouch(device) else { continue }
            add(endpoint, entity)
        }
        // The hidden Private endpoint may only be visible through its device.
        for index in 0..<MIDIGetNumberOfDevices() {
            let device = MIDIGetDevice(index)
            guard isTouch(device) else { continue }
            for entityIndex in 0..<MIDIDeviceGetNumberOfEntities(device) {
                let entity = MIDIDeviceGetEntity(device, entityIndex)
                for sourceIndex in 0..<MIDIEntityGetNumberOfSources(entity) { add(MIDIEntityGetSource(entity, sourceIndex), entity) }
            }
        }
        return result
    }

    private static func isTouch(_ device: MIDIDeviceRef) -> Bool {
        device != 0 && stringProperty(device, kMIDIPropertyName).localizedCaseInsensitiveContains("MPC Touch") && integerProperty(device, kMIDIPropertyOffline) == 0
    }
    private static func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    private static func integerProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0; MIDIObjectGetIntegerProperty(object, property, &value); return value
    }
    private static func error(_ operation: String, _ status: OSStatus) -> NSError {
        NSError(domain: "KoalaTouch.MIDI", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (\(status))"])
    }
}
