# Push 2 controls

Release **1.4.10, build 23** isolates Push's raw MIDI ports while Koala Link owns
Push. The first-use prompt explains that other apps cannot see those ports
until you quit or change controllers. Koala is reopened after isolation, and
the bridge keeps its existing input/output connections. Disconnect/reconnect
repeats this ordering; an on-disk receipt restores visibility on a later launch
after a crash. No Touch port, driver or MIDI profile is isolated.
The user confirmed the installed 1.4.10 chop-grid fix works on the physical
Push on 2026-10-26; newly opened clients see only its translated input.

After Keyboard → source-pad selection, **all 64 pads** stay on that source and
show the same cyan chop color (white while held), including wrapped chops when
the sample has fewer than 64 slices. Other saved editing-pad changes cannot
replace the source until Keyboard exits or a different song loads. Sample-pad
notes keep the original channel-16, 36–99 mapping; chops use channel 13.

Local **1.4.8, build 20** fixes source selection: press **NOTE** or the upper
**KEYBOARD** button, then hit the loaded source pad on Push. The grid blinks
while choosing. That hit selects the sample; subsequent hits play its chops
or keys on channel 13. Empty pads cannot start recording in this chooser.
Keyboard again cancels/exits; repeat never retriggers the source-selection hit.
Delayed saves must agree with the commanded keyboard state and selected pad
before replacing them. Offline MIDI regression checks cover this flow; the user confirmed the complete
chop-grid fix in 1.4.10 on Push. MPC routing, profile and driver are unchanged.

Earlier **v1.4.6** shipped app version 1.4.6, build 18. The same installer supports MPC Touch and optional Push 2 preview
use. The user confirmed version 1.4.5 works fine on MPC Touch on 2026-10-20;
this does not establish Push hardware validation. Push remains a preview, and
new gesture behavior still needs physical validation. The older
**v1.4.5-preview.1** tag is historical. The original **1.4.0-preview.1** (app
1.4.0, build 8) was the first Push preview.

Version **1.4.6, build 18** adds first-use Koala initialization and creates missing MIDI maps automatically. Choose Push 2 in Koala Link; no manual MIDI Learn is needed for its standard controls.

Local update **1.4.3, build 15** adds normal Push pad presses that select the
editing pad immediately. Sample notes remain mapped on channel 16; piano and
Chopper notes use channel 13 to avoid selecting another mapped sample. The
current song's saved waveforms are preloaded. Runtime Push connections and
cached waveform switching have been observed; complete physical validation of
the selection/channel split is pending.

Local **1.4.4, build 16** also redraws trim markers and the highlighted range
immediately when Push sends START/LENGTH from encoders 7/8, a trim target on
the strip, or a recorded CC macro. Koala's saved trim values reconcile later;
native mouse edits still depend on saved metadata. The initial START prediction
keeps the end fixed; conclusive fresh saves teach the installed Koala version's
boundary behavior. Physical trim agreement remains pending user feedback.

Build **17** includes cached fast waveform display and sample-pad
selection, local trim-marker feedback, and local tempo, sequence, piano-roll,
transport and playhead previews. The build is installed and running; new
gesture behavior still needs physical validation. Timing previews use Koala
clock when available; sequence edits reconcile against saved data, which can
lag because of native autosave.

At startup choose **Push 2** in the controller picker. Connect and power the
Push first. Close Ableton Live, and quit Paper Cut if it owns the Push display.
Koala Link uses Push's User MIDI port and USB display. The Push display is
960×160 pixels. The on-screen Koala colors are approximate matches to the
observed native screen—pink #FF2863, cyan #00CBEA and charcoal #2D2727—not
verified values from its active skin. Display pixels are rendered as RGBA8
then converted to RGB565. Push pad/button LEDs use separate Push palette slots;
their exact match to Koala's active skin is unverified.

## Pads, encoders and strip

| Control | Binding |
| --- | --- |
| 64 pads | The grid is four 4×4 Koala banks: A bottom-left, B bottom-right, C top-left, D top-right. Within each square, pad 1 is bottom-left. In sample mode pads play Koala's 64 pads. In keyboard mode they play 16 Levels or the selected Chopper's slices. Held notes keep their original note through page, bank and mode changes and release correctly. |
| Pad pressure and channel pressure | Forwarded as polyphonic/channel aftertouch while notes are held. Koala Link does not change Push aftertouch configuration. |
| Accent (CC 57) | Toggles FULL LEVEL. On sends pad velocity 127; off sends measured velocity. |
| Repeat (CC 56) | Toggles local 1/16 retriggering for held pads, based on Koala's MIDI clock when available. |
| Eight encoders (CC 71–78) | Control the eight displayed parameters. Touching an encoder highlights its target. Hold SHIFT for fine control; stepped and relative controls use their own increments. On the Chopper, SHIFT + encoder 7 changes the displayed chop-count override. |
| Tempo encoder (CC 14) | BPM up/down. |
| Swing encoder (CC 15) | Swing. |
| Master encoder (CC 79) | Main output level. |
| Encoder touch (notes 0–7) | Highlights the corresponding on-screen encoder target. |
| Touch strip | In FX/Perform, touch an effect button to select it, then slide the strip for absolute amount. On other pages it adjusts a focused continuous encoder target, relative to the strip's starting position to avoid a jump. Defaults: PAD volume (pitch in keyboard mode), EQ mid gain, Mixer master, SEQ swing. It does not send values unless touched. The strip uses documented pitch-bend mode with no autoreturn and returns to its original configuration when Push mode ends. |

### Encoder pages

| Page | Encoders 1–8, left to right |
| --- | --- |
| PAD | Volume, pan, pitch, tone, attack, release, start, length |
| EQ | Low frequency, low gain, mid frequency, mid gain, high frequency, high gain, choke group, bus |
| FX / Perform | Encoders 1–8 set effects 1–8; hold SHIFT to edit effects 9–16. The display buttons also select/toggle effects. |
| MIXER | Bus A, B, C, D, main output level |
| SEQ | Swing, bars, BPM, scale, beats per bar, snap |

Values read from Koala's files are saved snapshots and may lag Koala. Unknown
values are shown as unknown until a control is moved. SHIFT applies five-times
finer increments to continuous parameters outside FX. Encoder touch highlights
the target; touching tempo, swing or master announces its current value.

## Display rows

The upper row is CC 102–109, left to right: **PAD, EQ, FX, MIXER, SEQ,
KEYBOARD, LOAD, SETTINGS**. The first five select a screen. KEYBOARD enters source
selection: hit a loaded pad on Push, then play its chops/keys. Press KEYBOARD
again to cancel or exit. LOAD opens Koala's load view; SETTINGS opens settings.
Browse also opens Load, with SHIFT + Browse opening Export.

The lower row is CC 20–27, left to right, and changes with the page:

| Page | Lower row actions |
| --- | --- |
| PAD | One Shot, Loop, Reverse, Mute, Solo, Mic Input (SHIFT: Headphone Monitoring), Resample, File Input. One Shot is unavailable for Choppers because Koala exposes no MIDI/link command for it. |
| EQ | Low Flat, Mid Flat, High Flat, All Flat reset the corresponding gains to zero; One Shot, Loop, Reverse, Mute act on the selected pad |
| FX / Perform | Effects 1–8. Tap toggles an effect; hold an off effect for momentary use. Selecting an already-on effect makes the strip target it. |
| MIXER | Mute buses A–D and Main. Hold Solo to make the first four lower keys Solo A–D instead. Lower keys 6–8 switch to PAD, PERFORM and SEQUENCE. |
| SEQ | Play, Record, Quantize, Piano Roll, Bars −, Bars +, Tempo menu, Clear Sequence (hold SHIFT). |

Scene buttons CC 43–36, top to bottom, select the eight sequences in the
current sequence bank. Up/down changes among four banks (sequences 1–32).
On Perform, those same scene buttons control effects 9–16.

## Other Push buttons

| Button (CC) | Action |
| --- | --- |
| Tap Tempo (3) | Tap tempo; SHIFT opens the tempo menu. |
| Metronome (9) | Toggle metronome. |
| Master (28) | Open Mixer and highlight the master encoder. |
| Stop (29) | Stop playback, release held notes, and stop a CC macro loop. |
| Setup (30) | Open Koala settings. |
| Layout (31) | Toggle the detail view: saved waveform/pattern view versus encoder view. |
| Convert (35) | Open the Chopper detail view. Chop count and markers are edited in Koala itself; this control opens the saved waveform view; NOTE toggles keyboard mode for Koala’s selected pad. |
| Left / Right (44/45) | Cycle PAD, EQ, FX, MIXER and SEQ pages. |
| Up / Down (46/47) | Move sequence bank up/down; on FX, first switch to SEQ. |
| Select (48) | Open Koala Edit; SHIFT + Select goes Back. |
| Shift (49) | Modifier for the actions identified above. |
| Note (50) | Enter Keyboard source selection, then hit a loaded pad on Push. Press again to cancel or exit. |
| Session (51) | Open FX / Perform. |
| Add Device (52) | Open FX / Perform (16 effects). |
| Add Track (53) | Open Mixer. |
| Octave Down / Up (54/55) | Move 16 Levels by an octave; in Chopper keyboard mode these change the chop page instead. |
| Repeat (56) | Toggle held-pad 1/16 retriggering. |
| Accent (57) | Toggle FULL LEVEL. |
| Scale (58) | Open SEQ and highlight Scale encoder 4; turn encoder 4 to change the scale. |
| User (59) | Open the controller picker. SHIFT + User twice within three seconds quits Koala and Koala Link. |
| Mute (60) | Toggle mute for Koala's selected pad. |
| Solo (61) | Toggle Solo; while held on MIXER, lower-row keys solo buses A–D. |
| Page Left / Right (62/63) | Change the 64-chop page in Chopper keyboard mode; otherwise cycle PAD, EQ, FX, MIXER and SEQ pages. |
| Play (85) | Toggle sequence playback. |
| Record (86) | Toggle sequence recording. |
| New (87) | Select the first saved empty sequence. It does not create a new sequence. If none is saved empty, SHIFT + lower-row key 8 clears the current sequence. |
| Duplicate (88) | Double the current sequence's bar length. It does not make an arbitrary copy. |
| Automate (89) | Start CC-macro capture; press again to loop the captured movement, or again to stop. SHIFT + Automate clears it. |
| Fixed Length (90) | Open SEQ and highlight Bars encoder 2 for recording length. |
| Device (110) | Open PAD. |
| Browse (111) | Open Load; SHIFT opens Export. |
| Mix (112) | Open MIXER. |
| Clip (113) | Open SEQ. |
| Quantize (116) | Toggle record quantization. |
| Double Loop (117) | Double current sequence bars; SHIFT subtracts one bar. |
| Delete (118) | Turn NOTE/keyboard mode off. Hold exactly one loaded sample pad, then press Delete. The shipped no-link route requires that pad to be Koala's selected MIDI sample pad. Only that pad is targeted. Its waveform/LED preview clears immediately; repeat playback for it pauses, but its original note-off is retained. Koala's native delete warning setting is unchanged, so confirm in Koala if prompted. The preview rolls back on cancel, a fresh save, or after 20 seconds. |
| Undo (119) | Sends Koala Undo; SHIFT sends Redo. The display can restore only its most recent known sample deletion or sequence edit, and only until another knob or recording edit invalidates that preview. This is not a complete mirror of Koala's undo history. |

The Automate macro is local to Koala Link: it records outgoing CC movement from
encoders and the strip, not Koala's automation lane, buttons or pad notes. It
loops the captured movement while the selected pad stays the same; changing
the selected pad stops it. Capture is capped at 30 seconds and 4,000 CC events.

## Local sequence preview (build 17)

In SEQ, BPM changes by one per encoder step; Tap Tempo also estimates BPM.
Bars increase/decrease by one up to 64, and Duplicate previews a doubled
sequence including its notes. Clear Sequence preserves Koala's native
confirmation. Piano Roll toggles that view independently from keyboard mode
used to play pads. Local Record/Play indicators, provisional recorded notes
and a playhead are shown; Koala MIDI clock is preferred, with a local estimate
labeled **LOCAL PREVIEW** or **LOCAL** when needed. Count-in is respected.
The local estimate waits for the configured count-in before drawing recorded notes.
When sequence snap is enabled, queued sequence changes do not display guessed
notes before saved sequence data agrees. See Koala's [Sequence controls](https://manual.koalasampler.com/mobile/5-sequence/) and
[count-in setting](https://manual.koalasampler.com/mobile/8-settings/).

EQ, Mixer and FX continuous values already update locally. Build 17 protects
them with command-revision and file-save-age checks so an older snapshot cannot
overwrite a newer command. SHIFT + SESSION toggles FX HOLD.

Koala's [sample controls](https://manual.koalasampler.com/mobile/4-sample/)
describe deleting the selected pad and the hold-Delete-then-tap-pad workflow.
Koala Link's Push flow intentionally requires one loaded pad first, then
Delete, and uses the selected MIDI pad on the shipped no-link route. The
pending preview is provisional until Koala's confirmation/save resolves it.

Build 17 was installed locally on October 12, 2026. The installer succeeded,
the installed executable matched the production build, and the running app
reported Push User mode, USB display on and its saved waveforms cached. Physical
feedback for the new recording previews and deletion gesture is pending.

## Chopper behavior

Press NOTE or the upper KEYBOARD button, then hit the source pad on Push.
The blinking grid and “HIT THE PAD TO PLAY” prompt mean the next loaded-pad
hit selects the source; it is not a chop hit. Empty pads are ignored while
choosing. Subsequent hits play that source's chops/keys without selecting
other samples. Press Keyboard to exit, then Keyboard again to choose a different
source. No mouse selection or MIDI Learn is needed. A restored song already
in Keyboard mode starts on its saved source.

While this mode is active, the complete grid belongs to that source. The pad
lights do not show other loaded samples, empty sample slots or sample banks.

If that pad is a Chopper, Push pads play its saved chops. Chop 1 is note 60; notes 60–123 address
the first 64 chops regardless of whether the saved count is 16, 64 or 128.
Smaller and odd counts wrap in Koala. C−1 is not chop 1. For a 128-chop sample,
Page Left/Right or Octave Down/Up exposes page 1 or 2. The second page uses
count-aware MIDI note mapping intended to stay below note 128. The first page
retains the accepted notes 60–123. Upper-page overflow mapping is pending
hardware verification; do not claim access to all 128 chops as confirmed.

If the selected pad is not a Chopper, the same mode is 16 Levels. Octave
buttons shift its note range. Keyboard again exits the mode.

## State and validation

The Push display combines locally commanded state, Koala's MIDI clock, and
autosaved files under `~/Music/Koala Sampler/default`. Saved pad names,
sample audio, waveforms, slice markers/counts, sequence notes and mixer/FX
values are snapshots, not live feedback. The shipped Push bridge does not
activate the archived SP-404-style Koala feedback link. There is no live
waveform/playhead feed from Koala.

The displayed colors are approximate matches to the observed native Koala
screen; the active skin palette is not proven. On Push, RGB pads/buttons use
palette slots read and restored by Koala Link; display pixels use RGBA8
converted to the Push's RGB565 frame format. Physical color appearance remains
unverified.
