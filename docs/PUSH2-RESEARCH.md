# Push 2 implementation and validation

Status updated **2026-10-20** for the current **v1.4.6** release (app version
1.4.6, build 18). One installer supports MPC Touch and optional Push 2 preview
use. The user confirmed today that version 1.4.5 works fine on MPC Touch.
Push hardware validation remains pending; this release does not claim Push is
stable or fully validated. The previous **v1.4.5-preview.1** tag is historical
and contains the same app version/build as v1.4.5. The first Push preview,
**1.4.0-preview.1** (app 1.4.0, build 8), had screen artwork rendered and
visually reviewed offline.
The first physical Push session occurred later on 2026-10-11: the user reported
that waveforms appeared slowly, and the runtime log showed the User MIDI and
USB display connections opening. Full physical validation remains pending.

Build **18** adds first-use initialization through Koala itself and missing-map creation for both controllers. It was compiled and packaged; a fresh-Mac and physical hardware run of build 18 has not been performed. The accepted pad/Chopper routing and signed touch driver are unchanged.

Build **17**, distributed on the historical **v1.4.5** release, is installed and
running. It adds
tempo and sequence previews, local transport/record indicators, a provisional
playhead, count-in handling, safer snapshot reconciliation, and a pending
single-pad delete preview. The running app reported User mode, USB display on
and saved waveforms cached. New sequence/recording and deletion gestures still
need physical validation; this release does not claim every control is
verified. No automated tests were run. The installed Touch app's operation was
confirmed by the user on 2026-10-20. Push physical validation remains pending.

Build 16 caches decoded
waveforms and frame lengths by audio file identity, checks saved metadata every
150 ms, decodes sequential PCM chunks on a separate cancellable worker, and
scales quiet waveform display peaks. These changes affect the display data
path; Koala's autosave timing still limits when new edits become available.
The first live build 9 waveform readiness log measured 138 ms for 7,679 frames;
that measures decode/cache completion, not total latency on the physical screen.

The second speed investigation compared Paper Cut's `WaveformCache` and
`pushWave()` with this bridge. A native mouse selection changed Koala's visible
pad immediately, but its `song.json` selection changed about 5.8 seconds later.
Build 12 therefore displays a Push pad audition immediately without changing
Koala's selected-pad controls or keyboard/Chopper source. It warms every saved
sample in the background, gives foreground reads priority, listens for folder
save events, and retains polling as a fallback. A pending replacement display
frame now sends on completion of the current USB transfer, removing the old
up-to-500-ms keepalive wait. Marked controls still act on Koala's selected pad;
the waveform and header identify the auditioned pad. These changes do not give
live unsaved sample or native mouse-selection feedback.

Build 15 adds true sample-pad selection for Push: `midiCanSelectNotes=true`,
mapped sample notes on channel 16, and keyboard/Chopper notes on channel 13.
Normal sample-pad presses update the local editing target immediately; keyboard
notes keep their source. The canonical mapping and both raw-channel-1 and
keyboard-channel-13 conflicts are checked before Push input is enabled. A
snapshot read begun before a newer pad choice cannot overwrite that choice.
Switching controller profiles saves/quits Koala normally, applies the selected
profile while it is closed, then reopens it. MPC uses the accepted channel-16
keyboard profile with MIDI pad selection off. This split compiled successfully;
physical selection and Chopper-source behavior need user confirmation.

Build 16 adds immediate local trim-marker and range updates from actual sent
START/LENGTH MIDI CCs, including the encoder, strip and captured-macro paths.
The cached full waveform is reused; trims do not require PCM decoding. Saved
metadata reconciles only after a newer command-compatible read and changed
sampler save stamp; sample/frame/audio-identity changes invalidate pending
ranges. Fractional encoder accumulation is preserved.

Koala's exact START boundary behavior was not established by the archive. The
renderer initially keeps the end fixed, then learns end-fixed versus
length-fixed behavior from a conclusive START-only gesture and a settled fresh
save. It checks the sample identity, commanded start and both predictions,
rejects clipping/ambiguous results and gestures that also changed LENGTH, and
stores the result by Koala version/build. This replaces the earlier pending
manual observation request. Native mouse edits remain saved-state feedback.
Physical marker agreement and latency are pending user feedback.

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
- Build 17 locally previews BPM changes by one and Tap Tempo estimates, bars
  changes by one up to 64, and Duplicate's doubled sequence including its
  notes. Clear Sequence keeps Koala's native confirmation. Piano Roll display
  toggling is separate from keyboard mode for playing pads. Local Record/Play
  indicators, provisional notes and a playhead use Koala clock when available;
  fallback estimates are labeled LOCAL PREVIEW/LOCAL. Count-in is respected.
  For non-None snap, queued sequence changes wait for saved sequence agreement
  before showing note guesses. See the official [Sequence](https://manual.koalasampler.com/mobile/5-sequence/)
  and [Settings](https://manual.koalasampler.com/mobile/8-settings/) manuals.
- EQ/Mixer/FX continuous values preview locally. Command revision and file-save
  age checks prevent older snapshots from overwriting newer commands. SHIFT +
  SESSION toggles FX HOLD.
- Delete requires NOTE/keyboard mode off and exactly one loaded sample pad held
  before DELETE; the shipped no-link path also requires it to be Koala's
  selected MIDI sample pad. Only that pad's local waveform/LED preview clears;
  repeat playback pauses while its original note-off is retained. Koala's
  native warn-before-delete preference is unchanged, and a confirmation may
  still appear. Pending deletion rolls back on cancel, a fresh save, or a
  20-second timeout. See Koala's official [sample controls](https://manual.koalasampler.com/mobile/4-sample/)
  for native delete behavior. Undo/Redo sends Koala's native command; local
  restoration covers only the latest known sample deletion or sequence edit,
  and is invalidated by further knob or recording edits—not a full undo mirror.
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
