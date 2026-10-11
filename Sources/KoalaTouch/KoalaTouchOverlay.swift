import AppKit
import ApplicationServices

/// Large touch targets for Koala's fullscreen 1280×800 layout. The sampler
/// remains the active app; these panels never become key or steal pad focus.
final class KoalaTouchOverlay: NSObject {
    private static let proxyEventTag: Int64 = 0x505049434B4552
    enum Page { case sample, sequence, perform }
    var onBankSelected: ((Int) -> Void)?
    var onStatus: ((String) -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var application: NSRunningApplication?
    private var displayFrame = NSRect.zero
    private var bankPanel: NSPanel?
    private var mixerPanel: NSPanel?
    private var togglePanel: NSPanel?
    private var toggleButton: NSButton?
    private var overlayHidden = false
    private var bankButtons: [NSButton] = []
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var page: Page = .sample
    private var selectedBank = 0
    private var active = false
    private var closed = false
    private var controlsSuspended = false
    private enum Press { case bank(Int), mixer }
    private var pendingPresses: [Press] = []
    private var forwarding = false
    private var session = UUID()

    func start(application: NSRunningApplication, screen: NSScreen, bank: Int) {
        stop()
        closed = false
        session = UUID()
        self.application = application
        displayFrame = screen.frame
        selectedBank = bank
        // A fresh Koala launch opens on Sample. Header taps update the mode
        // without screen capture or extra Screen Recording permissions.
        page = .sample
        controlsSuspended = false
        overlayHidden = false
        bankButtons = []
        let bankRoot = Self.bankContent(target: self)
        bankButtons = bankRoot.subviews.compactMap { $0 as? NSButton }
        bankPanel = panel(content: bankRoot)
        let mixerRoot = Self.mixerContent(target: self)
        mixerPanel = panel(content: mixerRoot)
        let toggleRoot = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 92, height: 52))
        let toggle = NSButton(title: "HIDE", target: self, action: #selector(toggleOverlay))
        toggle.frame = NSRect(x: 4, y: 4, width: 84, height: 44)
        toggle.bezelStyle = .regularSquare
        toggle.font = PickerPaper.font(size: 16, weight: .medium)
        toggle.contentTintColor = PickerPaper.ink
        toggle.setAccessibilityLabel("Hide Koala overlay")
        toggleRoot.addSubview(toggle)
        toggleButton = toggle
        togglePanel = panel(content: toggleRoot)
        updateBankHighlight()
        movePanels()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            // Our forwarded press must never be mistaken for a new header
            // touch and schedule another forwarded press.
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.proxyEventTag else { return }
            guard let self else { return }
            let top = NSScreen.screens.first?.frame.maxY ?? self.displayFrame.maxY
            let point = event.cgEvent.map { NSPoint(x: $0.location.x, y: top - $0.location.y) } ?? NSEvent.mouseLocation
            self.observeKoalaTouch(at: point)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateVisibility() }
        updateVisibility()
    }

    func stop() {
        closed = true
        session = UUID()
        pendingPresses.removeAll()
        forwarding = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        bankPanel?.close(); mixerPanel?.close(); togglePanel?.close()
        bankPanel = nil; mixerPanel = nil; togglePanel = nil
        toggleButton = nil
        bankButtons.removeAll()
        application = nil
    }

    func screenChanged(_ screen: NSScreen?) {
        guard let screen else { bankPanel?.orderOut(nil); mixerPanel?.orderOut(nil); togglePanel?.orderOut(nil); return }
        displayFrame = screen.frame
        movePanels(); updateVisibility()
    }

    func selectBank(_ bank: Int) {
        guard (0..<4).contains(bank) else { return }
        selectedBank = bank
        updateBankHighlight()
        if page == .sample && !controlsSuspended { enqueue(.bank(bank)) }
    }

    private func panel(content: NSView) -> NSPanel {
        let panel = Panel(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = PickerPaper.paper
        panel.appearance = NSAppearance(named: .aqua)
        panel.contentView = content
        return panel
    }

    private func movePanels() {
        // The top-left corner is clear of Koala's page tabs and transport.
        bankPanel?.setFrameOrigin(NSPoint(x: displayFrame.minX + 8, y: displayFrame.maxY - 64))
        mixerPanel?.setFrameOrigin(NSPoint(x: displayFrame.minX + 8, y: displayFrame.maxY - 136))
        // Keep the toggle beside MIXER, below the bank row and clear of
        // Koala's native Sample tab. It stays available to show hidden controls.
        togglePanel?.setFrameOrigin(NSPoint(x: displayFrame.minX + 176, y: displayFrame.maxY - 134))
    }

    private func updateVisibility() {
        guard !closed, let application else { return }
        active = NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
        let ready = active && !controlsSuspended && !forwarding && koalaFrame() != nil
        movePanels()
        if ready && page != .sequence && !overlayHidden { bankPanel?.orderFrontRegardless() }
        else { bankPanel?.orderOut(nil) }
        if ready && page == .perform && !overlayHidden { mixerPanel?.orderFrontRegardless() }
        else { mixerPanel?.orderOut(nil) }
        if ready && page != .sequence { togglePanel?.orderFrontRegardless() }
        else { togglePanel?.orderOut(nil) }
    }

    @objc private func toggleOverlay() {
        overlayHidden.toggle()
        toggleButton?.title = overlayHidden ? "SHOW" : "HIDE"
        toggleButton?.setAccessibilityLabel(overlayHidden ? "Show Koala overlay" : "Hide Koala overlay")
        updateVisibility()
    }

    private func updateBankHighlight() {
        for button in bankButtons {
            button.state = button.tag == selectedBank ? .on : .off
            button.contentTintColor = button.tag == selectedBank ? PickerPaper.accent : PickerPaper.ink
        }
    }

    @objc private func bankPressed(_ sender: NSButton) {
        PickerLog.write("Koala overlay tap · bank \(sender.title)")
        onBankSelected?(sender.tag)
    }
    @objc private func mixerPressed() {
        guard page == .perform else { return }
        PickerLog.write("Koala overlay tap · MIXER")
        enqueue(.mixer)
    }

    // Use actual fullscreen coordinates, not the scaled screenshot preview.
    // Aim six pixels left of each original bank center, as requested, while
    // retaining one target per native bank. 1.2's preview-based positions were
    // a whole bank too far left (B hit A, C hit B, D hit C).
    private static func target(_ press: Press, frame: CGRect) -> CGPoint {
        let x: CGFloat
        switch press {
        case .bank(let bank): x = [CGFloat(579), 616, 653, 690][bank] / 1280
        case .mixer: x = 1036 / 1280
        }
        return CGPoint(x: frame.minX + frame.width * x, y: frame.minY + frame.height * (769 / 800))
    }

    private func observeKoalaTouch(at point: NSPoint) {
        guard active, let frame = koalaFrame(), displayFrame.contains(point) else { return }
        let x = (point.x - displayFrame.minX) / displayFrame.width
        let y = (displayFrame.maxY - point.y) / displayFrame.height
        guard frame.width > 0 else { return }
        if y < 0.13 {
            if (0.255..<0.383).contains(x) { page = .sample }
            else if (0.383..<0.533).contains(x) { page = .sequence }
            else if (0.533..<0.675).contains(x) { page = .perform }
            else {
                if (0.675..<0.76).contains(x) {
                    controlsSuspended = true
                    updateVisibility()
                }
                return
            }
            PickerLog.write("Koala page touch · \(page)")
            controlsSuspended = false
            // Koala handles the original header press first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, !self.closed else { return }
                self.updateVisibility()
                if self.page == .sample && !self.controlsSuspended { self.enqueue(.bank(self.selectedBank)) }
            }
        }
    }

    private func enqueue(_ press: Press) {
        guard !closed, !controlsSuspended else { return }
        // Keep a quick bank sweep's last pending selection, without replaying
        // stale banks after the user's hand has already moved on.
        if case .bank = press, let last = pendingPresses.last, case .bank = last {
            pendingPresses[pendingPresses.count - 1] = press
        } else { pendingPresses.append(press) }
        forwardNext()
    }

    /// Forward a user-requested press through the normal WindowServer route.
    /// PID-only events did not reliably activate Koala's custom drawn controls.
    /// Uncover the target before posting so the overlay cannot catch itself.
    private func forwardNext(waited: Int = 0) {
        guard !closed, !forwarding, !pendingPresses.isEmpty else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application?.processIdentifier,
              !controlsSuspended, AXIsProcessTrusted(), let window = koalaWindow() else {
            pendingPresses.removeAll()
            PickerLog.write("Koala overlay press skipped · sampler inactive, no fullscreen target, or no Accessibility")
            return
        }
        // Hardware bank presses can arrive while the finger is still down.
        // Never inject a second down/up into that physical gesture.
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            guard waited < 30 else { pendingPresses.removeAll(); return }
            let token = session
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self, self.session == token else { return }
                self.forwardNext(waited: waited + 1)
            }
            return
        }
        let press = pendingPresses.removeFirst()
        if case .bank = press, page != .sample { forwardNext(); return }
        if case .mixer = press, page != .perform { forwardNext(); return }
        let point = Self.target(press, frame: window.frame)
        guard let events = Self.clickEvents(at: point) else { return }
        let token = session
        let previousCursor = CGEvent(source: nil)?.location
        forwarding = true
        updateVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, !self.closed, self.session == token,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == self.application?.processIdentifier,
                  self.koalaWindow()?.id == window.id,
                  !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
                self?.finishForwarding(session: token)
                return
            }
            // The user may change pages during the uncover delay. A queued
            // Sample bank press must never land on Sequence's controls.
            if case .bank = press, self.page != .sample {
                self.finishForwarding(session: token)
                return
            }
            if case .mixer = press, self.page != .perform {
                self.finishForwarding(session: token)
                return
            }
            events[0].post(tap: .cghidEventTap) // move into Koala's uncovered view
            events[1].post(tap: .cghidEventTap)
            // A real down/up interval lets the sampler observe both transitions.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
                events[2].post(tap: .cghidEventTap) // always release a posted down
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    guard let self, !self.closed, self.session == token else { return }
                    // Restore only if no physical mouse/touch has moved since.
                    if let previousCursor, let current = CGEvent(source: nil)?.location,
                       abs(current.x - point.x) < 2, abs(current.y - point.y) < 2,
                       !CGEventSource.buttonState(.combinedSessionState, button: .left),
                       let restore = Self.mouseEvent(.mouseMoved, at: previousCursor) {
                        restore.post(tap: .cghidEventTap)
                    }
                    PickerLog.write("Koala native press forwarded at \(Int(point.x)),\(Int(point.y))")
                    self.finishForwarding(session: token)
                }
            }
        }
    }

    private func finishForwarding(session token: UUID) {
        guard session == token else { return }
        forwarding = false
        updateVisibility()
        forwardNext()
    }

    private static func mouseEvent(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        guard let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: proxyEventTag)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        return event
    }

    private static func clickEvents(at point: CGPoint) -> [CGEvent]? {
        guard let move = mouseEvent(.mouseMoved, at: point),
              let down = mouseEvent(.leftMouseDown, at: point),
              let up = mouseEvent(.leftMouseUp, at: point) else { return nil }
        return [move, down, up]
    }

    static func offlineSelfCheck() -> Bool {
        let frame = CGRect(x: -1280, y: 0, width: 1280, height: 800)
        guard target(.bank(0), frame: frame) == CGPoint(x: -701, y: 769),
              target(.bank(1), frame: frame) == CGPoint(x: -664, y: 769),
              target(.bank(2), frame: frame) == CGPoint(x: -627, y: 769),
              target(.bank(3), frame: frame) == CGPoint(x: -590, y: 769),
              target(.mixer, frame: frame) == CGPoint(x: -244, y: 769),
              let events = clickEvents(at: CGPoint(x: -729, y: 769)) else { return false }
        // Construct only; never post events during an offline check.
        return events.count == 3 && events[0].type == .mouseMoved && events[1].type == .leftMouseDown && events[2].type == .leftMouseUp && events.allSatisfy {
            $0.getIntegerValueField(.eventSourceUserData) == proxyEventTag &&
            $0.location == CGPoint(x: -729, y: 769) && $0.flags.isEmpty
        }
    }

    private static func bankContent(target: AnyObject?) -> NSView {
        let root = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 292, height: 56))
        for index in 0..<4 {
            let button = NSButton(title: String(UnicodeScalar(65 + index)!), target: target, action: #selector(bankPressed(_:)))
            button.tag = index
            button.frame = NSRect(x: 4 + index * 72, y: 4, width: 68, height: 48)
            button.bezelStyle = .regularSquare
            button.font = PickerPaper.font(size: 25, weight: .bold)
            button.contentTintColor = PickerPaper.ink
            button.setAccessibilityLabel("Koala pad bank \(button.title)")
            root.addSubview(button)
        }
        return root
    }

    private static func mixerContent(target: AnyObject?) -> NSView {
        let root = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 156, height: 56))
        let button = NSButton(title: "MIXER", target: target, action: #selector(mixerPressed))
        button.frame = NSRect(x: 4, y: 4, width: 148, height: 48)
        button.bezelStyle = .regularSquare
        button.font = PickerPaper.font(size: 23, weight: .bold)
        button.contentTintColor = PickerPaper.ink
        button.setAccessibilityLabel("Open or close Koala mixer")
        root.addSubview(button)
        return root
    }

    static func writePreview(to url: URL) throws {
        let root = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 480, height: 80))
        root.appearance = NSAppearance(named: .aqua)
        let banks = bankContent(target: nil); banks.setFrameOrigin(NSPoint(x: 10, y: 12)); root.addSubview(banks)
        let mixer = mixerContent(target: nil); mixer.setFrameOrigin(NSPoint(x: 314, y: 12)); root.addSubview(mixer)
        let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.contentView = root
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { throw CocoaError(.fileWriteUnknown) }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url); window.close()
    }

    private func koalaFrame() -> CGRect? { koalaWindow()?.frame }

    private func koalaWindow() -> (frame: CGRect, id: CGWindowID)? {
        guard let pid = application?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? displayFrame.maxY
        let expected = CGRect(x: displayFrame.minX, y: primaryTop - displayFrame.maxY,
                              width: displayFrame.width, height: displayFrame.height)
        return windows.compactMap { info -> (frame: CGRect, id: CGWindowID)? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let id = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect),
                  abs(rect.minX - expected.minX) < 3, abs(rect.minY - expected.minY) < 3,
                  abs(rect.width - expected.width) < 3, abs(rect.height - expected.height) < 3 else { return nil }
            return (rect, id.uint32Value)
        }.first
    }
}
