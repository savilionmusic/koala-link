# Push 2 implementation and validation

Status for **Koala Link 1.4.0-preview.1** (app version 1.4.0, build 8), updated
2026-10-11. The stable release line remains **1.3.0** for MPC Touch. The Push
build succeeds; its screen artwork has been rendered and visually reviewed offline. The user is away from the
hardware, so no physical Push validation has occurred.

## Implemented

- The startup controller picker offers MPC Touch and Push 2. The menu can
  reopen the picker; each selection starts only that controller session.
- Push 2 uses its User MIDI port and documented USB display path, with a
  960×160 custom Koala screen. Koala Link reads/restores Push palette entries
  when available and restores Push mode/display resources on stop.
- The 64 pads map to Koala's four 4×4 bank quadrants. The screen includes PAD,
  EQ, FX/Perform, MIXER and SEQ pages; eight parameter encoders; button labels
  and state lights; the touch strip; and an offline preview window.
- Physical buttons have assigned actions, including Push-specific controls
  documented in [PUSH2-CONTROLS.md](PUSH2-CONTROLS.md). Automate is a local
  captured-CC macro. New chooses a saved empty sequence; Duplicate doubles
  sequence length. Neither is claimed to match Ableton Live's corresponding
  operation.
- Koala files supply saved pad names, sample audio/waveforms, chop markers and
  counts, sequence notes, mixer/FX values, keyboard mode and selected pad.
  MIDI clock supplies transport/timing when Koala sends it. Autosaved files
  are snapshots and can lag Koala.
- The Chopper page keeps Koala's established behavior: chop 1 is MIDI 60;
  notes 60–123 address the first 64 chops for 16/64/128 counts; smaller and odd
  counts wrap; C−1 is not chop 1. For 128 chops, an upper page is wired with
  count-aware notes intended to stay below 128. Its overflow mapping is pending
  hardware verification; full 128-chop access is not confirmed.
- The observed native screen colors are approximate matches: pink #FF2863, cyan
  #00CBEA, charcoal #2D2727. They are not taken from website CSS and are not
  proven to be the active skin values. Display pixels use RGBA8-to-RGB565;
  Push LEDs use separate palette slots. Physical color appearance is pending.

## Feedback and limits

The shipped Push bridge does **not** activate the archived SP-404-style Koala
feedback link. There is no live audio waveform/playhead feed. The Push view
combines locally commanded state, saved snapshots and MIDI clock. It must keep
those sources legible rather than present a saved value as live Koala state.

The bridge watches Koala's `default` song folder for changes to
`sampler/sampler.json`, `sequence.json`, `mixer.json`, `fx.json` and `song.json`.
Sampler pad entries provide labels/sample IDs, chopper slice starts, and saved
parameter values; `sampler/<id>.wav` provides audio samples for a waveform
snapshot. Sequence entries provide saved notes and bar lengths. `mixer.json`
and `fx.json` provide saved mixer and Perform values. `song.json` provides the
saved keyboard mode and selected pad. These files are periodically re-read;
they are not a subscription to current UI state.

Archived Paper Picker notes report a limited SP-404MKII-style handshake and
pad/page feedback on Koala 2.0.12 under a different settings configuration.
That evidence did not prove complete live state, loaded-sample feedback,
parameter feedback or waveform data. The current Koala Link map disables
Koala's built-in device mappings. Treat the archive as an unverified research
lead, not as an active feature or a complete public API.

Koala's MIDI documentation describes note input, MIDI mapping, parameters and
clock, but does not establish a complete public live-state API:
[Koala MIDI settings](https://manual.koalasampler.com/mobile/8-settings/).
The hardware implementation follows Ableton's published
[Push 2 MIDI and Display Interface Manual](https://github.com/Ableton/push-interface)
and the official archived [Push 2 display example](https://github.com/Ableton/push2-display-with-juce).
These sources document Push transport, not Koala feedback.

## Physical validation still needed

With a Push 2 connected and Ableton Live/Paper Cut closed, verify USB display
ownership, frame orientation and color, all pad/button/encoder/strip events,
LED palette restore, and return to Live mode on disconnect/quit. Then verify
Koala receives each action once, held notes release through mode/page changes,
the second 64-chop page against real 128-chop audio, clock/repeat timing, and
controller switching. Compare the approximate colors against the active Koala
skin; they are visual matches to the observed screen, not exact samples.
Artwork has been rendered and visually reviewed offline; this does not establish
final rendering or physical behavior.
