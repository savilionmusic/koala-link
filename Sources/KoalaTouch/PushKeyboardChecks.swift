import Foundation

/// Offline MIDI regression checks. No CoreMIDI ports, hardware, live settings,
/// or Koala songs are opened; profile checks use disposable temporary files.
final class PushKeyboardChecks {
    static func run() throws {
        let checks = PushKeyboardChecks()
        checks.testNoteThenSourceThenAllChopsStayOnTheSource()
        checks.testDelayedKeyboardSaveCannotSkipSourceChoiceOrUndoExit()
        checks.testStaleSelectionCannotMoveChopSourceBeforeKoalaAcknowledgesIt()
        checks.testEmptyPadDoesNotStartRecordingWhileChoosing()
        checks.testHeldSourceKeepsItsReleaseAndDoesNotRepeatAsASelection()
        checks.testAcknowledgedSourceStaysPinnedUntilKeyboardExits()
        checks.testAll64PadsAreChopsEvenOverOtherLoadedSounds()
        guard try PushMIDIIsolation.offlineSelfCheck() else { throw CocoaError(.validationMissingMandatoryProperty) }
        try checks.testMPCProfileAndRoutingChecksRemainAccepted()
        print("PASS: Push Keyboard waits for a source; all 64 chop pads stay on channel 13 without toggling Keyboard")
        print("PASS: delayed saves, empty source pads, repeat and held releases preserve the source selection")
        print("PASS: the chosen source stays pinned; all 64 pads show chops independently of loaded sample slots")
        print("PASS: isolation restores visibility, recovers crashes, refuses an existing private owner and retains recovery after failure")
        print("PASS: accepted MPC profile and routing checks pass")
    }

    private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
        precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
    }
    private func expect(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
        precondition(condition, "Regression check failed", file: file, line: line)
    }
    private var messages: [[UInt8]] = []
    private var time = 10.0

    private func controller(keyboard: Bool = false) -> KoalaController {
        let controller = KoalaController { [unowned self] in self.messages.append($0) }
        controller.now = { [unowned self] in self.time }
        controller.keyboardChannel = KoalaPushProfile.pushKeyboardChannel
        controller.padsSelectInKoala = true
        controller.setSession(song(keyboard: keyboard))
        return controller
    }

    private func song(keyboard: Bool = false, selected: Int = 0) -> KoalaSession {
        var song = KoalaSession()
        song.name = "Keyboard regression fixture"
        song.selectedPad = selected
        song.keyboard = keyboard
        for pad in [0, 17] {
            var info = KoalaSession.Pad()
            info.loaded = true
            info.chopper = true
            info.slices = (0..<128).map { Double($0) / 128 }
            song.pads[pad] = info
        }
        return song
    }

    private func button(_ cc: Int, _ controller: KoalaController) {
        controller.handle(.button(cc, down: true))
        controller.handle(.button(cc, down: false))
    }

    private func pad(_ pad: Int, _ controller: KoalaController, down: Bool = true) {
        controller.handle(.pad(Push2Protocol.pushIndex(forKoala: pad), velocity: 100, down: down))
    }

    func testNoteThenSourceThenAllChopsStayOnTheSource() {
        let controller = controller()
        button(Push2Button.note, controller)
        expectEqual(controller.keyboard, .choosing)
        expect(controller.view().big.contains("HIT THE PAD"))
        expectEqual(messages, [[0x9E, 40, 1], [0x8E, 40, 0]])

        messages = []
        pad(17, controller)
        expectEqual(controller.keyboard, .on(17))
        expectEqual(controller.selected, 17)
        expectEqual(messages, [[0x9F, 53, 100]])
        pad(17, controller, down: false)
        expectEqual(messages.last, [0x8F, 53, 0])

        messages = []
        for index in 0..<64 {
            controller.handle(.pad(index, velocity: 91, down: true))
            controller.handle(.pressure(index, value: 70))
            controller.handle(.pad(index, velocity: 0, down: false))
        }
        expectEqual(controller.keyboard, .on(17))
        expectEqual(controller.selected, 17)
        expectEqual(messages.count, 64 * 3)
        for index in 0..<64 {
            let note = UInt8(60 + Push2Protocol.koalaPad(forPush: index))
            expectEqual(Array(messages[(index * 3)..<(index * 3 + 3)]),
                           [[0x9C, note, 91], [0xAC, note, 70], [0x8C, note, 0]])
        }
    }

    func testDelayedKeyboardSaveCannotSkipSourceChoiceOrUndoExit() {
        let controller = controller()
        button(Push2Button.upperRow.lowerBound + 5, controller)
        time += 1
        let save = Date().addingTimeInterval(1)
        // Koala can save keyboardMode=true before a source is chosen.
        controller.setSession(song(keyboard: true), savedDates: ["song.json": save],
                              readCommandRevision: controller.commandRevision)
        expectEqual(controller.keyboard, .choosing)
        pad(17, controller)
        pad(17, controller, down: false)
        button(Push2Button.note, controller)
        expectEqual(controller.keyboard, .off)

        // A background read begun before the exit must not turn it back on.
        controller.setSession(song(), acceptSelection: false, readCommandRevision: 0)
        controller.setSession(song(keyboard: true), acceptSelection: false, readCommandRevision: 0)
        expectEqual(controller.keyboard, .off)
    }

    func testStaleSelectionCannotMoveChopSourceBeforeKoalaAcknowledgesIt() {
        let controller = controller()
        button(Push2Button.note, controller)
        pad(17, controller)
        pad(17, controller, down: false)
        time += 1
        let save = Date().addingTimeInterval(1)
        controller.setSession(song(keyboard: true, selected: 3), savedDates: ["song.json": save],
                              readCommandRevision: controller.commandRevision)
        expectEqual(controller.selected, 17)
        expectEqual(controller.keyboard, .on(17))
        controller.tick()
        controller.setSession(song(keyboard: true, selected: 4), savedDates: ["song.json": save],
                              readCommandRevision: controller.commandRevision)
        expectEqual(controller.selected, 17)
        expectEqual(controller.keyboard, .on(17))
    }

    func testEmptyPadDoesNotStartRecordingWhileChoosing() {
        let controller = controller()
        button(Push2Button.note, controller)
        messages = []
        pad(5, controller)
        expectEqual(controller.keyboard, .choosing)
        expect(messages.isEmpty)
        button(Push2Button.note, controller)
        expectEqual(controller.keyboard, .off)
    }

    func testHeldSourceKeepsItsReleaseAndDoesNotRepeatAsASelection() {
        let controller = controller()
        pad(0, controller)
        button(Push2Button.repeatButton, controller)
        button(Push2Button.note, controller)
        pad(17, controller)
        messages = []
        time += 1
        controller.tick()
        expect(messages.isEmpty)
        pad(0, controller, down: false)
        pad(17, controller, down: false)
        expectEqual(messages, [[0x8F, 36, 0], [0x8F, 53, 0]])
    }

    func testAcknowledgedSourceStaysPinnedUntilKeyboardExits() {
        let controller = controller()
        button(Push2Button.note, controller)
        pad(17, controller)
        pad(17, controller, down: false)
        time += 1
        controller.setSession(song(keyboard: true, selected: 17),
                              savedDates: ["song.json": Date().addingTimeInterval(1)],
                              readCommandRevision: controller.commandRevision)
        controller.setSession(song(keyboard: true, selected: 0))
        expectEqual(controller.keyboard, .on(17))
        expectEqual(controller.selected, 17)
        // Even after command-preview expiry, an unrelated saved selection
        // cannot change the instrument or the grid's mode.
        time += 30
        controller.tick()
        controller.setSession(song(keyboard: false, selected: 4))
        expectEqual(controller.keyboard, .on(17))
        expectEqual(controller.selected, 17)
        button(Push2Button.note, controller)
        expectEqual(controller.keyboard, .off)
    }

    func testAll64PadsAreChopsEvenOverOtherLoadedSounds() {
        let controller = controller()
        var snapshot = song()
        for index in 0..<64 {
            if snapshot.pads[index] == nil {
                var other = KoalaSession.Pad()
                other.loaded = true
                snapshot.pads[index] = other
            }
        }
        snapshot.pads[17]?.slices = (0..<49).map { Double($0) / 49 }
        controller.setSession(snapshot)
        button(Push2Button.note, controller)
        pad(17, controller)
        pad(17, controller, down: false)
        expectEqual(controller.padColors(), Array(repeating: Push2Color.chop.rawValue, count: 64))
        messages = []
        for index in 0..<64 {
            controller.handle(.pad(index, velocity: 90, down: true))
            expectEqual(controller.padColors()[index], Push2Color.hit.rawValue)
            controller.handle(.pad(index, velocity: 0, down: false))
        }
        expectEqual(messages.count, 128)
        expect(messages.allSatisfy { $0[0] & 0x0F == 12 })
        expectEqual(controller.keyboard, .on(17))
        expectEqual(controller.padColors(), Array(repeating: Push2Color.chop.rawValue, count: 64))
    }

    func testMPCProfileAndRoutingChecksRemainAccepted() throws {
        expectEqual(KoalaPushProfile.requiredSettings(for: .mpcTouch).first { $0.key == "keyboardMidiChannel" }?.value as? Int, 16)
        expectEqual(KoalaPushProfile.requiredSettings(for: .mpcTouch).first { $0.key == "midiCanSelectNotes" }?.value as? Bool, false)
        expect(KoalaPadMapper.offlineSelfCheck())
        expect(KoalaControlRouter.offlineSelfCheck())
        expect(try KoalaMIDIProfile.offlineSelfCheck())
        expect(try KoalaPushProfile.offlineSelfCheck())
    }

}
