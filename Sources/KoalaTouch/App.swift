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

/// Koala Link: Koala Sampler on the Akai MPC Touch.
///
/// Koala Link:
/// - readies the touch driver and the MPC's controls;
/// - sets Koala's MIDI map and settings (Koala closed);
/// - opens Koala full screen on the MPC's display;
/// - while Koala runs, routes the MPC's pads (banks A–D = Koala's 64 pads), Q-Links and KEYS/REC/PLAY, and shows the bank
///   overlay.
///
/// When Koala quits, Koala Link lets the MPC go and quits too.
///
/// The launcher owns one selected hardware session: MPC Touch or Push 2.
/// Paper Cut uses the same devices, so the two never run at once.
final class KoalaTouchApp: NSObject, NSApplicationDelegate {
    private let koalaBundleID = "com.elf-audio.koala-mac"
    private let paperCutBundleID = "com.savilion.mpctouch.instrument"
    private var cards: [NSWindow] = []
    private var statusItem: NSStatusItem?
    private var bridge: KoalaMIDIBridge?
    private var pushBridge: PushKoalaBridge?
    private var choiceWindow: ControllerChoiceWindow?
    private var webcam: WebcamWindowController?
    private var controllerChoice: KoalaControllerChoice?
    private var sessionGeneration = 0
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
        // One Koala Link at a time: a second copy would be a second owner of the MPC.
        if let id = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        installMenu()
        PickerLog.write("Koala Link \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") started")
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.screensChanged() }
        chooseController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        retry?.invalidate(); watch?.invalidate()
        overlay?.stop()
        bridge?.setRoutingEnabled(false)
        bridge?.stop()
        pushBridge?.stop(); choiceWindow?.close()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        PickerLog.write("Koala Link quit")
    }

    // MARK: Menu
    private func installMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(item("Open Koala Again", #selector(openAgain), "o"))
        appMenu.addItem(item("Choose Controller…", #selector(chooseController), ""))
        appMenu.addItem(item("Webcam…", #selector(openWebcam), "w"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Koala Link", #selector(quit), "q"))
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "Koala Link"
        let menu = NSMenu()
        menu.addItem(item("Open Koala Again", #selector(openAgain), "o"))
        menu.addItem(item("Choose Controller…", #selector(chooseController), ""))
        menu.addItem(item("Webcam…", #selector(openWebcam), ""))
        menu.addItem(.separator())
        menu.addItem(item("Quit Koala Link", #selector(quit), "q"))
        status.menu = menu; statusItem = status
    }
    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key); i.target = self; return i
    }
    @objc private func openAgain() {
        guard koala == nil else { koala?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); return }
        start()
    }
    @objc private func chooseController() {
        if choiceWindow == nil {
            let choice = ControllerChoiceWindow()
            choice.onChoose = { [weak self] selected in self?.selectController(selected) }
            choice.onWebcam = { [weak self] in self?.openWebcam() }
            choiceWindow = choice
        }
        choiceWindow?.showWindow(nil); choiceWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// WEBCAM (WebcamWindow.swift): opens beside whichever controller is in use.
    @objc private func openWebcam() {
        if webcam == nil { webcam = WebcamWindowController() }
        webcam?.open()
    }
    private func selectController(_ selected: KoalaControllerChoice) {
        sessionGeneration += 1; retry?.invalidate(); retry = nil
        watch?.invalidate(); watch = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        overlay?.stop(); overlay = nil
        bridge?.setRoutingEnabled(false); bridge?.stop(); bridge = nil
        pushBridge?.stop(); pushBridge = nil
        integration = nil; koala = nil
        preparing = false; launching = false; recoveryTried = false
        closeCards(); controllerChoice = selected
        PickerLog.write("Selected controller: \(selected.rawValue)")
        start()
    }
    /// Quit: Koala first (it saves its song), then Koala Link.
    @objc private func quit() {
        quitting = true
        guard let koala, !koala.isTerminated else { NSApp.terminate(nil); return }
        say("Closing Koala…")
        if !koala.terminate() { NSApp.terminate(nil) }
    }

    // MARK: Start: the touch driver, the MPC's controls, then Koala
    private func start() {
        guard let controllerChoice else { chooseController(); return }
        guard koala == nil, !preparing, !launching else { return }
        retry?.invalidate(); retry = nil
        if NSRunningApplication.runningApplications(withBundleIdentifier: paperCutBundleID).contains(where: { !$0.isTerminated }) {
            showCards()
            say("Paper Cut is using the MPC Touch. Quit Paper Cut, and Koala Link carries on by itself.")
            later(3)
            return
        }
        if controllerChoice == .push2 { startPush(); return }
        let generation = sessionGeneration
        preparing = true
        showCards()
        say("Starting the MPC Touch…")
        TouchService.prepare(mpcDisplayID: mpcScreen().flatMap(displayNumber), allowRecovery: !recoveryTried) { [weak self] result in
            guard let self else { return }
            guard self.sessionGeneration == generation, self.controllerChoice == .mpcTouch else { return }
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
                    guard self.sessionGeneration == generation, self.controllerChoice == .mpcTouch else { return }
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
        let generation = sessionGeneration
        if !NSRunningApplication.runningApplications(withBundleIdentifier: koalaBundleID).contains(where: { !$0.isTerminated }) {
            bridge.prepareForKoalaLaunch()
        }
        bridge.setRoutingEnabled(false)
        let integration = KoalaIntegration()
        integration.onStatus = { [weak self] text in DispatchQueue.main.async { self?.say(text) } }
        self.integration = integration
        integration.open(on: screen) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.sessionGeneration == generation, self.controllerChoice == .mpcTouch else { return }
                self.launching = false
                switch result {
                case .success(let app):
                    bridge.prepareForKoalaLaunch(); bridge.setRoutingEnabled(true); self.started(app)
                case .failure(let error):
                    self.integration = nil
                    if KoalaPushProfile.settingsMatch(mode: .mpcTouch), let app = NSRunningApplication.runningApplications(withBundleIdentifier: self.koalaBundleID).first(where: { !$0.isTerminated }) {
                        // Koala opened, but its window couldn't be placed: it still runs with the MPC.
                        bridge.prepareForKoalaLaunch(); bridge.setRoutingEnabled(true); self.started(app)
                        self.say(error.localizedDescription)
                    } else {
                        bridge.setRoutingEnabled(false)
                        self.say(error.localizedDescription)
                        // Accessibility (to place Koala's window on the MPC's screen): macOS's own prompt, once a run; it also
                        // puts Koala Link in the Accessibility list. Koala Link keeps trying and carries on once allowed.
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

    private func startPush() {
        preparing = true; closeCards()
        let generation = sessionGeneration
        let push = pushBridge ?? PushKoalaBridge(); pushBridge = push
        push.onStatus = { [weak self] text in
            guard let self, self.sessionGeneration == generation else { return }
            self.say(text)
        }
        push.onChooseController = { [weak self] in self?.chooseController() }
        push.onQuit = { [weak self] in self?.quit() }
        push.onReady = { [weak self] in
            guard let self, self.sessionGeneration == generation, self.controllerChoice == .push2 else { return }
            self.preparing = false; self.launchPushKoala()
        }
        do { try push.start(); preparing = false }
        catch { preparing = false; push.stop(); pushBridge = nil; say(error.localizedDescription); later(3) }
    }
    private func launchPushKoala() {
        guard koala == nil, !launching, let screen = NSScreen.screens.first, let pushBridge else { return }
        launching = true; let generation = sessionGeneration
        let integration = KoalaIntegration(); self.integration = integration
        integration.onStatus = { [weak self] text in
            guard let self, self.sessionGeneration == generation else { return }; self.say(text)
        }
        integration.open(on: screen, accessibilityOptional: true, placeWindow: false, profileMode: .push2) { [weak self] result in
            guard let self, self.sessionGeneration == generation, self.controllerChoice == .push2 else { return }
            self.launching = false
            switch result {
            case .success(let app): pushBridge.prepareForKoalaLaunch(); self.started(app)
            case .failure(let error): self.say(error.localizedDescription)
            }
        }
    }

    // MARK: Koala running
    private func started(_ app: NSRunningApplication) {
        closeCards()
        koala = app
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        if controllerChoice == .mpcTouch, let screen = mpcScreen(), let bridge {
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
        say(controllerChoice == .push2 ? "Koala is running with Push 2" : "Koala is running on the MPC Touch")
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
    /// Koala quit: everything held is let go, the MPC is released, and Koala Link quits too.
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
        pushBridge?.stop(); pushBridge = nil
        integration = nil
        PickerLog.write("Koala has quit")
        NSApp.terminate(nil)
    }

    private func screensChanged() {
        guard controllerChoice == .mpcTouch else { return }
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
