import AppKit
import ApplicationServices

@main
private enum KoalaTouchMain {
    static func main() {
        let application = NSApplication.shared
        PickerPaper.registerFonts()
        if KoalaTouchArtwork.handleCommandLine() { return }
        let delegate = KoalaTouchApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

/// Koala Touch: Koala Sampler on the Akai MPC Touch.
///
/// Koala Touch:
/// - readies the touch driver and the MPC's controls;
/// - sets Koala's MIDI map and settings (Koala closed);
/// - opens Koala full screen on the MPC's display;
/// - while Koala runs, routes the MPC's pads (banks A–D = Koala's 64 pads), Q-Links and KEYS/REC/PLAY, and shows the bank
///   overlay.
///
/// When Koala quits, Koala Touch lets the MPC go and quits too.
///
/// It is the Koala + MPC Touch part of Paper Picker (2026-10), on its own: no Push, no picker. Paper Cut uses the same MPC,
/// so the two never run at once.
final class KoalaTouchApp: NSObject, NSApplicationDelegate {
    private let koalaBundleID = "com.elf-audio.koala-mac"
    private let paperCutBundleID = "com.savilion.mpctouch.instrument"
    private var cards: [NSWindow] = []
    private var statusItem: NSStatusItem?
    private var bridge: KoalaMIDIBridge?
    private var integration: KoalaIntegration?
    private var overlay: KoalaTouchOverlay?
    private var koala: NSRunningApplication?
    private var retry: Timer?
    private var watch: Timer?
    private var preparing = false, launching = false, recoveryTried = false, quitting = false
    private var terminationObserver: NSObjectProtocol?, screenObserver: NSObjectProtocol?
    private var status = "Starting…"
    private var askedForAccessibility = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One Koala Touch at a time: a second copy would be a second owner of the MPC.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        installMenu()
        PickerLog.write("Koala Touch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") started")
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        retry?.invalidate(); watch?.invalidate()
        overlay?.stop()
        bridge?.setRoutingEnabled(false)
        bridge?.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        PickerLog.write("Koala Touch quit")
    }

    // MARK: Menu
    private func installMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(item("Open Koala Again", #selector(openAgain), "o"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Koala Touch", #selector(quit), "q"))
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Koala Touch"
        let menu = NSMenu()
        menu.addItem(item("Open Koala Again", #selector(openAgain), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Quit Koala Touch", #selector(quit), "q"))
        status.menu = menu; statusItem = status
    }
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.target = self; return i
    }
    @objc private func openAgain() {
        guard koala == nil else { koala?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); return }
        start()
    }
    /// Quit: Koala first (it saves its song), then Koala Touch.
    @objc private func quit() {
        quitting = true
        guard let koala, !koala.isTerminated else { NSApp.terminate(nil); return }
        say("Closing Koala…")
        if !koala.terminate() { NSApp.terminate(nil) }
    }

    // MARK: Start: the touch driver, the MPC's controls, then Koala
    private func start() {
        guard koala == nil, !preparing, !launching else { return }
        retry?.invalidate(); retry = nil
        if NSRunningApplication.runningApplications(withBundleIdentifier: paperCutBundleID).contains(where: { !$0.isTerminated }) {
            showCards()
            say("Paper Cut is using the MPC Touch. Quit Paper Cut, and Koala Touch carries on by itself.")
            later(3)
            return
        }
        preparing = true
        showCards()
        say("Starting the MPC Touch…")
        TouchService.prepare(mpcDisplayID: mpcScreen().flatMap(displayNumber), allowRecovery: !recoveryTried) { [weak self] result in
            guard let self else { return }
            self.recoveryTried = self.recoveryTried || result.recoveryAttempted
            self.say(result.message)
            guard result.ready, self.mpcScreen() != nil else {
                self.preparing = false
                if self.mpcScreen() == nil { self.say("Waiting for the MPC Touch's screen (DisplayLink)… · \(result.message)") }
                self.later(2)
                return
            }
            self.say("MPC touch ready · starting its controls…")
            let bridge = self.bridge ?? KoalaMIDIBridge()
            bridge.onStatus = { [weak self] text in DispatchQueue.main.async { self?.say(text) } }
            self.bridge = bridge
            do {
                try bridge.start(onReady: { [weak self] in
                    guard let self else { return }
                    self.preparing = false
                    self.launchKoala()
                })
            } catch {
                self.preparing = false
                bridge.stop(); self.bridge = nil
                self.say("The MPC's controls didn't start: \(error.localizedDescription)")
                self.later(2)
            }
        }
    }
    private func later(_ seconds: TimeInterval) {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.start() }
    }

    private func launchKoala() {
        guard koala == nil, !launching else { return }
        guard let screen = mpcScreen(), let bridge else { later(2); return }
        launching = true
        if !NSRunningApplication.runningApplications(withBundleIdentifier: koalaBundleID).contains(where: { !$0.isTerminated }) {
            bridge.prepareForKoalaLaunch()
        }
        bridge.setRoutingEnabled(true)
        let integration = KoalaIntegration()
        integration.onStatus = { [weak self] text in DispatchQueue.main.async { self?.say(text) } }
        self.integration = integration
        integration.open(on: screen) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.launching = false
                switch result {
                case .success(let app): self.started(app)
                case .failure(let error):
                    self.integration = nil
                    if let app = NSRunningApplication.runningApplications(withBundleIdentifier: self.koalaBundleID).first(where: { !$0.isTerminated }) {
                        // Koala opened, but its window couldn't be placed: it still runs with the MPC.
                        self.started(app)
                        self.say(error.localizedDescription)
                    } else {
                        bridge.setRoutingEnabled(false)
                        self.say(error.localizedDescription)
                        // Accessibility (to place Koala's window on the MPC's screen): macOS's own prompt, once a run; it also
                        // puts Koala Touch in the Accessibility list. Koala Touch keeps trying and carries on once allowed.
                        if case KoalaIntegrationError.accessibilityRequired = error, !self.askedForAccessibility {
                            self.askedForAccessibility = true
                            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                        }
                        self.later(4)
                    }
                }
            }
        }
    }

    // MARK: Koala running
    private func started(_ app: NSRunningApplication) {
        closeCards()
        koala = app
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if let screen = mpcScreen(), let bridge {
            let overlay = KoalaTouchOverlay()
            overlay.onBankSelected = { [weak bridge] bank in bridge?.selectPadBank(bank) }
            overlay.onKeyboardToggled = { [weak bridge] in bridge?.keyboardToggledOnScreen() }
            overlay.onStatus = { [weak self] text in self?.say(text) }
            bridge.onPadBankChanged = { [weak overlay] bank in overlay?.selectBank(bank) }
            bridge.onChopperModeChanged = { [weak overlay] enabled in overlay?.setChopperMode(enabled) }
            self.overlay?.stop()
            self.overlay = overlay
            overlay.start(application: app, screen: screen, bank: bridge.currentPadBank, chopperMode: bridge.currentChopperMode)
        }
        say("Koala is running on the MPC Touch")
        let pid = app.processIdentifier
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                                object: nil, queue: .main) { [weak self] note in
            guard let ended = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, ended.processIdentifier == pid else { return }
            self?.koalaEnded()
        }
        // macOS's notice can be missed: the process itself is checked every 2 s too.
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if app.isTerminated || (kill(pid, 0) != 0 && errno == ESRCH) { self?.koalaEnded() }
        }
    }
    /// Koala quit: everything held is let go, the MPC is released, and Koala Touch quits too.
    private func koalaEnded() {
        guard koala != nil else { return }
        watch?.invalidate(); watch = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        koala = nil
        overlay?.stop(); overlay = nil
        bridge?.onPadBankChanged = nil
        bridge?.onChopperModeChanged = nil
        bridge?.setRoutingEnabled(false)
        integration = nil
        PickerLog.write("Koala has quit")
        NSApp.terminate(nil)
    }

    private func screensChanged() {
        if koala != nil { overlay?.screenChanged(mpcScreen()); return }
        if !preparing && !launching { start() }
    }

    // MARK: The MPC's screen
    private func mpcScreen() -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Paper Cut remembers the exact display its touch windows use (read only, never written here).
        if let saved = UserDefaults(suiteName: paperCutBundleID)?.string(forKey: "launchDisplayUUID"),
           let match = NSScreen.screens.first(where: { $0 !== primary && displayUUID($0) == saved }) {
            return match
        }
        return NSScreen.screens.first { $0 !== primary && isMPCScreen($0) }
    }
    private func isMPCScreen(_ screen: NSScreen) -> Bool {
        let size = screen.frame.size
        return screen.localizedName.lowercased().contains("mpc") || (Int(size.width) == 1280 && Int(size.height) == 800)
    }
    private func displayNumber(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
    private func displayUUID(_ screen: NSScreen) -> String? {
        guard let number = displayNumber(screen),
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    // MARK: The starting card (on the MPC's screen, and the Mac's)
    private func showCards() {
        guard cards.isEmpty else { return }
        var screens: [NSScreen] = []
        if let main = NSScreen.screens.first { screens.append(main) }
        if let mpc = mpcScreen(), !screens.contains(mpc) { screens.append(mpc) }
        for screen in screens {
            let isMain = screen == NSScreen.screens.first
            let frame = isMain ? NSRect(x: screen.visibleFrame.midX - 480, y: screen.visibleFrame.midY - 300, width: 960, height: 600) : screen.frame
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.hasShadow = isMain; window.level = .floating
            let card = KoalaTouchCard(frame: NSRect(origin: .zero, size: frame.size)); card.status = status
            window.contentView = card
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()
            cards.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    private func closeCards() { cards.forEach { $0.orderOut(nil); $0.close() }; cards.removeAll() }
    private func say(_ text: String) {
        if text != status { PickerLog.write(text) }
        status = text
        statusItem?.button?.toolTip = text
        for window in cards { (window.contentView as? KoalaTouchCard)?.status = text }
    }
}
