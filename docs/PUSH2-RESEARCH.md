# Koala Link on Ableton Push 2

Research and proposed next phase, 2026-10-11. Push 2 support is planned and not yet implemented.

## Goal and accepted reference

The user wants custom Koala screens arranged for the Push 2 display and its physical controls, following the approach used in Paper Cut. The 64 pads, buttons, encoder turns and touches, touch strip and lights should form a coherent Koala instrument.

The user confirmed that installed **Koala Touch 1.2.1, build 6** works as wanted on 2026-10-11. This product is now named **Koala Link**. Its MIDI mapping, Chopper behavior, FULL LEVEL control and accepted touch-driver binary are the reference for the Push adaptation. See [MIDI mapping](MIDI-MAPPING.md) for the existing routing rules. This phase concerns the standalone Koala Link repository.

## Primary GitHub references

- [Ableton/push-interface](https://github.com/Ableton/push-interface): Ableton's official MIDI and Display Interface Manual, including control messages, LEDs, palettes, encoder touch, pad velocity/pressure, touch-strip configuration and display transport.
- [Ableton/push2-display-with-juce](https://github.com/Ableton/push2-display-with-juce): official C++ display example; archived, useful as protocol reference. Its display transport can be used independently of JUCE.
- [ffont/push2-python](https://github.com/ffont/push2-python): the author's implementation and examples for the screen, pads, buttons, encoders, touch strip, lights and simulator. Useful for comparison with the native implementation.

Ableton documents a **960×160** display sent through USB, separately from the MIDI controls. Its manual includes a full hardware map. These documents establish control of Push hardware; they do not establish what Koala reports back.

## Existing local work to reuse after review

Read-only inspection found Paper Cut's native C USB display transport (`Push2Display.c`), Swift MIDI device/decoder (`Push2.swift`) and screen renderer (`PushSurface.swift`). They already describe the documented frame encoding, User-port controls, encoder touches and display ownership. Reuse should keep those responsibilities separate from Koala actions.

The archived Paper Picker source also contains `KoalaController.swift`, `KoalaMap.swift`, `KoalaSession.swift`, `KoalaLink.swift`, and dated Push handoff/research notes. Those are historical evidence. Their old defaults and claims must be checked against the accepted Koala Link build and current Koala before adoption.

## Koala rules the adaptation must preserve

| Area | Rule |
| --- | --- |
| Sample pads | Keep the existing 64 sample assignments, Ch16 notes 36–99. Convert Push grid position to the intended Koala bank and slot explicitly. |
| First chop | Chop 1 is MIDI **60**, followed by 61, 62, etc. MIDI 60 is the first chop at every chop count; C−1 is not the first chop. |
| Chop count | Equal-16 is insufficient evidence for a mapping. Keep the accepted ordinal mapping when markers are added or AUTO changes the count. |
| Smaller/odd counts | Koala wraps notes over the available slices for smaller and odd chop counts. For 17 chops, ordinal 17 is chop 17 and ordinal 18 returns to chop 1; for 26, ordinal 26 is chop 26 and ordinal 27 returns to chop 1. |
| 128 chops | Current MPC banks address the first 64. Push's 64 pads can initially do the same. Access to all 128 needs an explicit second page and additional validation. |
| MIDI ceiling | Notes must remain 0–127. A second page starting at 124 crosses that ceiling after four pads; simply adding 64 is invalid. Count-aware wrapping is a candidate, not yet a confirmed solution. |
| Chopper vs pitched sample | Keyboard mode on a Chopper selects slices; on an ordinary sample it plays pitched notes. Do not infer identical pad behavior from the keyboard toggle alone. |
| Keyboard selection | Account for Koala's keyboard selection/CHOOSE step and keep the chosen sample stable while playing. Do not let raw input or another pad hit silently replace it. |
| Bank meaning | Sample banks select other sample pads; Chopper banks select more notes of the chosen sample. Keep that distinction visible on Push. |
| Held notes | Capture note, mode and sample assignment at press and release that same note after any bank/page/mode change. A page change must not strand a held pad. |
| One action | Translate Push inputs once. Keep raw MIDI ports, the virtual translated source, and any optional feedback link separate. |
| Native keyboard toggle | A completed touchscreen keyboard press already changes Koala; update shared mode state once without sending another toggle back. |
| FULL LEVEL | Preserve maximum strike velocity 127 when enabled and measured strike velocity when disabled. Push Accent is a proposed control for this state; its light must follow the shared state. |
| Restored song | Initialize from the saved song while Koala is closed. Saved files are not proof of subsequent live state. |
| Mapping repair | Preserve canonical channels and backups. Koala MIDI Learn can also hear raw hardware, and song-specific mappings can override global assignments. |

These rules specify the planned adaptation; they do not claim Push support is implemented or that future controls have been validated.

## Proposed screens and controls

Each page should align eight parameter columns with the eight screen encoders, and label the upper and lower display buttons according to their current action.

| Screen | Display / controls |
| --- | --- |
| Sample | Selected pad and bank, sample name when known, level/pan/pitch/tone, envelope, start/length. Waveform and live playhead depend on a verified state source. |
| Chopper / Keyboard | Explicit sample vs chop mode, selected sample, first/last visible chop, pad ordinals, page/octave indication and keyboard state. |
| Sequence | Selected pattern, transport, tempo and bars when known; record/quantize/piano-roll actions where Koala accepts them. A live note grid depends on verified data. |
| Perform | Koala effect names and states; tap/hold effects; touch strip controls the selected effect amount, with correct touch/release behavior. |
| Mixer / EQ | Channel and master parameters plus mute/solo; EQ parameter pages. Show actual values only when their source is known. |

Proposed control coverage:

- **Pads:** four 4×4 sample-bank regions, following the earlier user layout; keyboard/Chopper layout must keep its logical order explicit.
- **Upper/lower screen rows:** page navigation and labeled actions for the selected page.
- **Eight screen encoders:** page parameters; touch reveals the target, SHIFT gives fine changes. Avoid parameter jumps from an unknown starting value.
- **Tempo/swing/master encoders:** corresponding Koala parameters where available.
- **Play, Record, Tap Tempo, Metronome:** transport and timing.
- **Note, Session, Device, Clip, Mix, Browse, Setup:** keyboard and screen modes, song loading and settings where supported.
- **Mute, Solo, Select, Delete, Undo, Quantize, Double Loop:** verified Koala actions with explicit modifier/release behavior.
- **Arrows, Page and Octave buttons, scene column:** sequence banks, navigation, pitch/chop pages as appropriate.
- **Accent:** FULL LEVEL.
- **Touch strip:** effect amount in Perform; other roles only with a matching Koala action and clear display label. Reset/latch behavior is part of the assignment.
- **New, Duplicate, Automate, Fixed Length, Repeat, Scale, Convert, Add Track, Add Device and User:** every physical input needs an explicit action or an unavailable indication after checking Koala's capabilities; the corresponding Live operation cannot be assumed to exist in Koala.

This is a proposed layout, not the implemented MIDI table.

## State feedback is the next technical milestone

[Koala's MIDI documentation](https://manual.koalasampler.com/mobile/8-settings/) describes note input, parameter CCs, MIDI mapping and clock. It does not establish a complete public live-state API for external displays.

The archived SP-404MKII experiment reports a limited two-way controller connection in Koala 2.0.12: greeting, bank, page/button state and pad lights. It required built-in device mappings, which the accepted Koala Link configuration currently disables. The recorded live probe used an empty session and did not establish every loaded/playing-pad state, parameter value or waveform. Treat this as a lead for a separate compatibility check.

A Push screen should distinguish:

1. **Live feedback:** values Koala actually reports.
2. **Commanded state:** what the companion sent, which can differ after a mouse or MPC edit.
3. **Saved snapshot:** names, audio and settings from a saved song. A snapshot can lag current edits and is not live feedback.
4. **Unknown:** show an honest placeholder until a reliable source exists.

The next implementation milestone is a small native Push display/control adapter with the Koala feedback path established. Once that path is understood, build the Sample and Chopper pages, then Sequence, Perform and Mixer. The known Chopper quirks above must guide each stage.
