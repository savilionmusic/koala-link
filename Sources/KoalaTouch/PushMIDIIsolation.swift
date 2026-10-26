import AppKit
import CoreMIDI

/// Koala falls back to normal samples for unmapped raw notes (60 and up),
/// regardless of the translated keyboard channel. Keep the bridge's existing
/// Push connections, but hide that device from clients opened afterwards.
/// A receipt precedes the change, so a later launch can recover after a crash.
final class PushMIDIIsolation {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "IsolatePushRawMIDI") }
    struct Lease: Codable {
        var deviceID: Int32, original: Int32, pid: Int32
    }
    struct Backend {
        var find: (Int32) -> MIDIDeviceRef?
        var identifier: (MIDIDeviceRef) -> Int32?
        var privacy: (MIDIDeviceRef) -> Int32?
        var setPrivacy: (MIDIDeviceRef, Int32) -> OSStatus
        var ownerAlive: (Int32) -> Bool
    }
    private let receipt: URL
    private let backend: Backend
    private var device: MIDIDeviceRef?
    private var lease: Lease?
    var active: Bool { device.map { backend.privacy($0) == 1 } ?? false }

    init(receipt: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Koala Touch/push-midi-isolation.json"),
         backend: Backend = PushMIDIIsolation.liveBackend) {
        self.receipt = receipt; self.backend = backend
    }

    /// Only recover this app's own recorded change. Never unhide an unrelated
    /// private device or take a lease from another running copy of the app.
    func recover() throws {
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        let saved = try JSONDecoder().decode(Lease.self, from: Data(contentsOf: receipt))
        guard saved.original == 0, saved.pid > 0 else { throw failure("Push MIDI recovery receipt is invalid; no device changed.") }
        guard saved.pid == getpid() || !backend.ownerAlive(saved.pid) else {
            throw failure("Another Koala Link session owns Push MIDI.")
        }
        if let found = backend.find(saved.deviceID) {
            guard backend.setPrivacy(found, saved.original) == noErr, backend.privacy(found) == saved.original else {
                throw failure("Could not restore Push MIDI visibility. Reopen Koala Link to retry.")
            }
        }
        try FileManager.default.removeItem(at: receipt)
        PickerLog.write("push 2 · recovered original MIDI visibility")
    }

    func claim(_ found: MIDIDeviceRef) throws {
        guard lease == nil, let id = backend.identifier(found), let original = backend.privacy(found), original == 0 else {
            throw failure("Push MIDI is already private or unavailable; no visibility changed.")
        }
        let saved = Lease(deviceID: id, original: original, pid: getpid())
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: receipt, options: .atomic)
        device = found; lease = saved
        guard backend.setPrivacy(found, 1) == noErr, active else {
            try? restore()
            throw failure("Could not isolate Push's raw MIDI input; Koala was not started.")
        }
        PickerLog.write("push 2 · raw MIDI isolated; existing bridge connections retained")
    }

    func restore() throws {
        guard device != nil, let lease else { return }
        if let current = backend.find(lease.deviceID) {
            guard backend.setPrivacy(current, lease.original) == noErr, backend.privacy(current) == lease.original else {
                throw failure("Could not restore Push MIDI visibility. Reopen Koala Link to retry.")
            }
        }
        self.device = nil; self.lease = nil
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        PickerLog.write("push 2 · original MIDI visibility restored")
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "KoalaLink.PushIsolation", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    static let liveBackend = Backend(
        find: { id in
            // A private Push can disappear from MIDIGetDevice enumeration too.
            // Its recorded unique ID still resolves, including after a crash.
            var device = MIDIObjectRef(), type = MIDIObjectType.other
            var name: Unmanaged<CFString>?
            guard MIDIObjectFindByUniqueID(id, &device, &type) == noErr, type == .device,
                  MIDIObjectGetStringProperty(device, kMIDIPropertyName, &name) == noErr,
                  let text = name?.takeRetainedValue() as String?,
                  text.localizedCaseInsensitiveContains("Push 2") else { return nil }
            return device
        },
        identifier: { device in
            var id: Int32 = 0
            return MIDIObjectGetIntegerProperty(device, kMIDIPropertyUniqueID, &id) == noErr ? id : nil
        },
        privacy: { device in
            var value: Int32 = 0
            let status = MIDIObjectGetIntegerProperty(device, kMIDIPropertyPrivate, &value)
            return status == noErr || status == kMIDIUnknownProperty ? value : nil
        },
        setPrivacy: { MIDIObjectSetIntegerProperty($0, kMIDIPropertyPrivate, $1) },
        ownerAlive: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
            return app.bundleIdentifier == Bundle.main.bundleIdentifier
        })

    /// Runs entirely against a fake MIDI device and a temporary receipt.
    static func offlineSelfCheck() throws -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KoalaLink-Isolation-\(UUID().uuidString)")
        let receipt = folder.appendingPathComponent("lease.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        var privacy: Int32 = 0, fail = false, present = true, ignoreRestore = false
        let backend = Backend(find: { $0 == 42 && present ? 7 : nil }, identifier: { $0 == 7 ? 42 : nil },
                              privacy: { _ in privacy }, setPrivacy: { _, value in
                                  guard !fail else { return -1 }
                                  if !ignoreRestore || value != 0 { privacy = value }
                                  return noErr
                              }, ownerAlive: { _ in false })
        let isolation = PushMIDIIsolation(receipt: receipt, backend: backend)
        try isolation.claim(7)
        guard privacy == 1, isolation.active, FileManager.default.fileExists(atPath: receipt.path) else { return false }
        try isolation.restore()
        guard privacy == 0, !FileManager.default.fileExists(atPath: receipt.path) else { return false }
        try isolation.claim(7)
        ignoreRestore = true
        do { try isolation.restore(); return false } catch {}
        guard privacy == 1, FileManager.default.fileExists(atPath: receipt.path) else { return false }
        ignoreRestore = false
        try isolation.restore()
        guard privacy == 0, !FileManager.default.fileExists(atPath: receipt.path) else { return false }
        try isolation.claim(7)
        // Simulate a crash: a new owner must restore before finding endpoints.
        let recovery = PushMIDIIsolation(receipt: receipt, backend: backend)
        try recovery.recover()
        guard privacy == 0 else { return false }
        privacy = 1
        do { try recovery.claim(7); return false } catch {}
        guard privacy == 1, !FileManager.default.fileExists(atPath: receipt.path) else { return false }
        privacy = 0; fail = true
        do { try recovery.claim(7); return false } catch {}
        guard FileManager.default.fileExists(atPath: receipt.path) else { return false }
        fail = false
        try PushMIDIIsolation(receipt: receipt, backend: backend).recover()
        guard privacy == 0, !FileManager.default.fileExists(atPath: receipt.path) else { return false }
        let removed = PushMIDIIsolation(receipt: receipt, backend: backend)
        try removed.claim(7); present = false
        try removed.restore()
        return !FileManager.default.fileExists(atPath: receipt.path)
    }
}
