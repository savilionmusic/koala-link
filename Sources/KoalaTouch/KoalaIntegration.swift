import AppKit
import ApplicationServices

/// Launches Koala and attempts to place its main window on a selected display.
final class KoalaIntegration {
    var onStatus: ((String) -> Void)?

    private let bundleIdentifier = "com.elf-audio.koala-mac"
    private let positioningAttempts = 12
    private let retryDelay: TimeInterval = 0.35
    /// Whether Koala's window is moved and made fullscreen (needs Accessibility).
    private var placement = true

    /// `accessibilityOptional`: without Accessibility, Koala still opens (where macOS puts it, not
    /// fullscreen) instead of failing. For Koala on the Mac's display with the Push.
    func open(on screen: NSScreen, accessibilityOptional: Bool = false, placeWindow: Bool = true,
              profileMode: KoalaPushProfile.Mode = .mpcTouch, completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        let placement = placeWindow && AXIsProcessTrusted()
        guard placement || accessibilityOptional else {
            completion(.failure(KoalaIntegrationError.accessibilityRequired))
            return
        }
        self.placement = placement
        let installedURL = URL(fileURLWithPath: "/Applications/koala.app")
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                ?? (FileManager.default.fileExists(atPath: installedURL.path) ? installedURL : nil) else {
            let error = KoalaIntegrationError.applicationNotInstalled
            onStatus?(error.localizedDescription)
            completion(.failure(error))
            return
        }

        guard let display = currentScreen(matching: screen) else {
            completion(.failure(KoalaIntegrationError.displayDisconnected))
            return
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first(where: { !$0.isTerminated }) {
            if !KoalaPushProfile.settingsMatch(mode: profileMode) {
                onStatus?("Saving and reopening Koala for the selected controller's MIDI channels…")
                guard running.terminate() else {
                    completion(.failure(NSError(domain: "KoalaLink.Profile", code: 1, userInfo: [NSLocalizedDescriptionKey: "Koala could not close normally. Save and quit it, then choose the controller again."])))
                    return
                }
                reopen(after: running, on: screen, accessibilityOptional: accessibilityOptional, placeWindow: placeWindow,
                       profileMode: profileMode, attempt: 0, completion: completion)
                return
            }
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            guard placement else { completion(.success(running)); return }
            onStatus?("Koala is already running. Checking Accessibility access and moving its window…")
            positionWindow(of: running, on: display, attempt: 0) { result in
                completion(result.map { running })
            }
            return
        }

        do {
            try KoalaMIDIProfile.prepare()
        } catch {
            onStatus?(error.localizedDescription)
            completion(.failure(error))
            return
        }
        // Koala's MIDI settings and the MPC's keys in its map, every launch (Koala writes its settings back when it quits,
        // and MIDI Learn can grab other ports' notes). A problem here never stops Koala.
        do { try KoalaPushProfile.prepare(mode: profileMode) }
        catch {
            PickerLog.write("Koala's MIDI map/settings not set: \(error.localizedDescription)")
            if profileMode == .push2 || !KoalaPushProfile.settingsMatch(mode: profileMode) { completion(.failure(error)); return }
        }
        onStatus?("Launching Koala…")
        launch(applicationURL: applicationURL, targetScreen: display, completion: completion)
    }

    private func reopen(after application: NSRunningApplication, on screen: NSScreen, accessibilityOptional: Bool,
                        placeWindow: Bool, profileMode: KoalaPushProfile.Mode, attempt: Int,
                        completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        if application.isTerminated {
            open(on: screen, accessibilityOptional: accessibilityOptional, placeWindow: placeWindow, profileMode: profileMode, completion: completion)
            return
        }
        guard attempt < 50 else {
            completion(.failure(NSError(domain: "KoalaLink.Profile", code: 2, userInfo: [NSLocalizedDescriptionKey: "Koala is still closing. Finish its save/close dialog, then choose the controller again."])))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.reopen(after: application, on: screen, accessibilityOptional: accessibilityOptional, placeWindow: placeWindow,
                         profileMode: profileMode, attempt: attempt + 1, completion: completion)
        }
    }

    private func launch(applicationURL: URL, targetScreen: NSScreen, completion: @escaping (Result<NSRunningApplication, Error>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] application, error in
          DispatchQueue.main.async {
            guard let self else { return }
            if let application {
                guard self.placement else {
                    self.onStatus?("Koala is open on the Mac display.")
                    completion(.success(application))
                    return
                }
                self.onStatus?("Koala launched. Waiting for its main window…")
                self.positionWindow(of: application, on: targetScreen, attempt: 0) { result in
                    completion(result.map { application })
                }
            } else {
                let launchError = error ?? KoalaIntegrationError.launchFailed
                self.onStatus?("Couldn’t launch Koala: \(launchError.localizedDescription)")
                completion(.failure(launchError))
            }
          }
        }
    }

    private func currentScreen(matching requested: NSScreen) -> NSScreen? {
        guard let requestedNumber = requested.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == requestedNumber.uint32Value
        }
    }

    private func positionWindow(of application: NSRunningApplication, on screen: NSScreen, attempt: Int,
                                completion: @escaping (Result<Void, Error>) -> Void) {
        guard let display = currentScreen(matching: screen) else {
            completion(.failure(KoalaIntegrationError.displayDisconnected))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failure(KoalaIntegrationError.accessibilityRequired))
            return
        }
        let frame = display.frame
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let position = CGPoint(x: frame.minX, y: primaryTop - frame.maxY)
        let size = CGSize(width: frame.width, height: frame.height)
        let displayBounds = CGRect(origin: position, size: size)
        if nativeWindowMatches(pid: application.processIdentifier, position: position, size: size) {
            onStatus?("Koala fills the MPC display at \(Int(size.width)) × \(Int(size.height)).")
            completion(.success(()))
            return
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement],
              let window = windows.first(where: { elementTitle($0).hasPrefix("Koala") }) ?? windows.first else {
            if attempt + 1 < positioningAttempts {
                retry(application: application, screen: display, attempt: attempt + 1, completion: completion)
            } else { completion(.failure(KoalaIntegrationError.windowUnavailable)) }
            return
        }

        // Move a normal window first, then enter Koala's real macOS fullscreen
        // mode. Merely changing AXSize leaves Koala's renderer at phone size.
        if isFullScreen(window) {
            if attempt + 1 < positioningAttempts {
                _ = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
                retry(application: application, screen: display, attempt: attempt + 1, completion: completion)
            } else { completion(.failure(KoalaIntegrationError.windowPlacementFailed)) }
            return
        }
        let normalSize = windowSize(window) ?? CGSize(width: 320, height: 594)
        let centeredPosition = CGPoint(x: position.x + max(0, (size.width - normalSize.width) / 2),
                                       y: position.y + max(0, (size.height - normalSize.height) / 2))
        _ = set(point: centeredPosition, attribute: kAXPositionAttribute as CFString, of: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self else { return }
            guard self.nativeWindowIsOnDisplay(pid: application.processIdentifier, bounds: displayBounds),
                  self.enterFullScreen(window) else {
                if attempt + 1 < self.positioningAttempts {
                    self.retry(application: application, screen: display, attempt: attempt + 1, completion: completion)
                } else { completion(.failure(KoalaIntegrationError.windowPlacementFailed)) }
                return
            }
            self.onStatus?("Koala is on the MPC display; entering fullscreen…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                if self.nativeWindowMatches(pid: application.processIdentifier, position: position, size: size) {
                    self.onStatus?("Koala fills the MPC display at \(Int(size.width)) × \(Int(size.height)).")
                    completion(.success(()))
                } else if attempt + 1 < self.positioningAttempts {
                    self.retry(application: application, screen: display, attempt: attempt + 1, completion: completion)
                } else { completion(.failure(KoalaIntegrationError.windowPlacementFailed)) }
            }
        }
    }

    private func elementTitle(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private func windowSize(_ window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }

    private func isFullScreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func enterFullScreen(_ window: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success { return true }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreenButton" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(unsafeBitCast(value, to: AXUIElement.self), kAXPressAction as CFString) == .success
    }

    private func nativeWindowIsOnDisplay(pid: pid_t, bounds: CGRect) -> Bool {
        nativeWindowFrames(pid: pid).contains { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }

    private func retry(application: NSRunningApplication, screen: NSScreen, attempt: Int,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.positionWindow(of: application, on: screen, attempt: attempt, completion: completion)
        }
    }

    private func set(point: CGPoint, attribute: CFString, of element: AXUIElement) -> Bool {
        let value = AXValueCreate(.cgPoint, [point.x, point.y])!
        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func set(size: CGSize, attribute: CFString, of element: AXUIElement) -> Bool {
        let value = AXValueCreate(.cgSize, [size.width, size.height])!
        return AXUIElementSetAttributeValue(element, attribute, value) == .success
    }

    private func windowMatches(_ window: AXUIElement, position: CGPoint, size: CGSize) -> Bool {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return false }

        var actualPosition = CGPoint.zero
        var actualSize = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &actualPosition),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &actualSize) else { return false }
        let tolerance: CGFloat = 2
        return abs(actualPosition.x - position.x) <= tolerance
            && abs(actualPosition.y - position.y) <= tolerance
            && abs(actualSize.width - size.width) <= tolerance
            && abs(actualSize.height - size.height) <= tolerance
    }

    /// CoreGraphics reports the composited frame. It is the final authority
    /// when Koala's Accessibility frame is temporarily stale during a resize.
    private func nativeWindowMatches(pid: pid_t, position: CGPoint, size: CGSize) -> Bool {
        let tolerance: CGFloat = 2
        return nativeWindowFrames(pid: pid).contains { actual in
            abs(actual.minX - position.x) <= tolerance
                && abs(actual.minY - position.y) <= tolerance
                && abs(actual.width - size.width) <= tolerance
                && abs(actual.height - size.height) <= tolerance
        }
    }

    private func nativeWindowFrames(pid: pid_t) -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.width > 100, frame.height > 100 else { return nil }
            return frame
        }
    }

}

enum KoalaIntegrationError: LocalizedError {
    case applicationNotInstalled
    case launchFailed
    case displayDisconnected
    case accessibilityRequired
    case windowUnavailable
    case windowPlacementFailed

    var errorDescription: String? {
        switch self {
        case .applicationNotInstalled:
            return "Koala was not found. Install Koala 2.0.11 or later and try again."
        case .launchFailed:
            return "Koala could not be launched."
        case .displayDisconnected:
            return "MPC Touch display disconnected. Reconnect it, then choose Koala again."
        case .accessibilityRequired:
            return "Koala Link needs Accessibility access to move Koala. Enable this app in System Settings → Privacy & Security → Accessibility, then choose Koala again."
        case .windowUnavailable:
            return "Koala opened, but its window did not become available. Choose Koala again."
        case .windowPlacementFailed:
            return "Koala opened, but macOS could not place it on the MPC display. Choose Koala again."
        }
    }
}
