# Project Learnings

> Managed by `/learn`. Append-only — latest entry wins on conflicts.

## Patterns

## Pitfalls

### push-chop-pages-have-a-midi-note-limit
- **Insight:** A second 64-pad Chopper page cannot simply add 64 to the accepted notes 60–123 because MIDI notes stop at 127; reach the remaining chops only with a chop-count-aware assignment whose wrap behavior is confirmed in Koala.
- **Confidence:** 9/10
- **Source:** learn; current mapper and MIDI arithmetic, with additional-page behavior still unverified
- **Files:** Sources/KoalaTouch/KoalaMIDIBridge.swift, docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Performance

### live-pages-and-push-delete-build17-installed
- **Insight:** Installed local Koala Link 1.4.5 build 17 on October 12, 2026. Push tempo, tap-tempo estimate, bars, sequence double/clear, piano-roll layout, transport indicators and outgoing recorded-note previews now draw before autosave. MIDI clock is preferred; fallback playhead/note timing is explicitly LOCAL PREVIEW/LOCAL and waits for configured count-in. Notes keep original source/pitch/slice/sequence through releases; non-None queued sequence changes suppress speculative capture before saved selection agrees. Per-file save dates and command-read revisions retain newer local knob/flag/FX state against older reads. Normal sample selection uses the same guard. SHIFT+SESSION toggles FX HOLD.
- **Insight:** Delete requires keyboard/Chopper off and exactly one held loaded sample pad. The shipped no-link route verifies that pad is the selected MIDI sample before /currPad/delete. Empty-pad/wave/LED preview is immediate; Repeat is suspended for that held pad while its original note-off stays owned. Native delete-warning preferences remain unchanged. Pending previews reconcile with fresh saves or expire after 20 seconds. Known most-recent sample-delete/sequence Undo/Redo previews are invalidated by subsequent edits, independently changed saved targets, canceled/rejected snapshots or expiry; native undo commands are always sent. This does not mirror Koala's full undo history.
- **Confidence:** 9/10 for build/install/runtime; physical deletion and estimated-recording agreement pending user feedback
- **Source:** direct user requests; current code inspection; Luna read-only audits verified and expiry/history issue repaired; successful production compiler/package build and installer; installed/build hashes matched; runtime log and native CUA preview screenshot. No automated tests or user-sample deletion were performed.
- **Evidence:** Installed executable SHA256 84b23e4b06b599b83c8a3d8b819bc584b8417fed45309db7135d65be3ea49a8f; installer SHA256 762b4e8208a213b4cf836d3500b6043b145045ab29c8e0b1f99b593b6fa5bcbc. Runtime reported Push User mode, USB display on, 34 current saved samples cached. Accepted shared driver hash unchanged. Previous 1.4.4 build 16 retained as backup. Not published to GitHub in this request.
- **Files:** Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/KoalaSession.swift, Sources/KoalaTouch/PushKoalaBridge.swift, docs/PUSH2-CONTROLS.md
- **Date:** 2026-10-12
- **Next:** Await user feedback on immediate tempo/bar/recording display and whether held-pad DELETE removes the sample directly or opens a native confirmation. Native Mac-window edits and newly unsaved audio still depend on Koala autosaving.

### live-trim-build16-installed
- **Insight:** Installed 1.4.4 build 16 on October 12 and reopened Push mode. Installed/built executable SHA256 matched 65123f137b8b4f28db1266d96ec5d99342b6dd1ee99b6f7fdeb55902665d009e; installer SHA256 is 32f2e6155048945b1df22f2c974dc45cd93d8f51a083ee27509f7cbf5cf335c8. Runtime logged Push User mode, USB display on, initial cache of 59 samples, and the preview visibly showed the highlighted trim region. The user subsequently changed pad/sample contents, so that initial count is not a claim about the current song. Shared driver hash remained accepted. Physical marker latency/agreement and conclusive START learning are pending user feedback. No automated tests ran; no new public release was uploaded.
- **Confidence:** 9/10 for installed/runtime facts; physical trim agreement pending
- **Source:** package installer success, plist/hash checks, runtime log and native CUA screenshot
- **Files:** build-app.sh, Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/PushKoalaBridge.swift
- **Date:** 2026-10-12

### live-push-trim-displays-commands-before-autosave
- **Insight:** User explicitly asked to proceed with freely moving Push trim markers in sync with encoder commands. Version 1.4.4 build 16 implements pending trim ranges on cached waveform data for actual sent encoder/strip/macro CCs and draws a pink range highlight. Snapshot revision, changed/newer sampler save date and exact audio identity prevent older reads and replaced samples from applying stale ranges. Fractional CC accumulation is preserved; cached audio lengths restore initial trim positions. Fresh saved state reconciles later. START initially keeps the end fixed, then conclusively observed START-only gestures learn end-fixed versus length-fixed semantics keyed by Koala version/build; ambiguous/clipped gestures and LENGTH changes cannot teach it. This supersedes the previous manual-observation hold; physical agreement still needs feedback.
- **Confidence:** 8/10
- **Source:** direct user instruction October 12, 2026; inspected implementation, successful production app and installer build; Luna deploy review reported no concrete blocking bug and was checked against source
- **Files:** Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/PushKoalaBridge.swift, Sources/KoalaTouch/KoalaWaveformReader.swift
- **Date:** 2026-10-12

### live-push-trim-update-awaits-start-boundary-observation
- **Insight:** On October 12 the user reported START/LENGTH encoder trims did not update Push like Koala's native editor and confirmed they use the Push encoders. The installed 1.4.3 build 15 sends trim CCs immediately but draws waveform boundaries from saved pad metadata. The uninstalled source now records pending trim ranges for actual sent CC values (encoder/strip/macro), renders them on the cached waveform with a highlighted region, and reconciles only with a newer sampler save/read revision. Fractional encoder accumulation stays in positions; the paired LENGTH position updates after START. Audio identity/frame changes clear pending ranges, and initial trim values can use cached audio frames after launch preparation resets metadata frames. Production compilation succeeded and no automated tests ran.
- **Confidence:** 8/10
- **Source:** direct user request/reply, inspected controller/reader/render code, Luna audit claims checked against code, compiler builds; native START's end-versus-length behavior is not verified by the archive or manual
- **Files:** Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/PushKoalaBridge.swift, Sources/KoalaTouch/KoalaWaveformReader.swift
- **Date:** 2026-10-12
- **Next:** The user was asked to turn START a little and report whether only the left marker moves or both markers move. The source's trimStartKeepsEnd=true is provisional. Resolve that behavior before packaging/installing the live-trim update, set a new app build/version, and retain the installed 1.4.3 build 15 as backup. Read-only observation work/push-trim-observation.log captured no trim commands during its bounded window. The installed app remains unchanged in this turn.

### push-waveform-selection-must-not-wait-for-autosave
- **Insight:** A native Koala pad click at Unix time 1791775134.178 visibly selected A1 immediately, but song.json reported selectedPad 0 only at 1791775140.014 (about 5.8 seconds). Paper Cut prepares wave summaries on project loading and reads its local selected pad directly. Koala Link build 12 preloads saved WAV summaries, updates the audition waveform directly from Push input, and keeps selected-pad controls plus keyboard/Chopper source independent. Mouse selection and unsaved new audio still wait for Koala saving. Installed 1.4.2 build 12 logged all 59 saved samples warmed in its startup second and the preview displayed A1's waveform; physical pad-hit latency remains pending user feedback.
- **Confidence:** 9/10
- **Source:** primary agent inspected current Paper Cut and Koala Link code; native CUA click/screenshot and read-only file observation, 2026-10-11
- **Files:** Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/PushKoalaBridge.swift
- **Date:** 2026-10-11

### push-frame-replacements-need-immediate-draining
- **Insight:** The Push transfer callback cleared its sending flag without sending a newer pending frame. A replacement arriving during a transfer could wait for the 500 ms keepalive. Frame revisions now trigger the newest replacement immediately after a successful transfer; failures retain the existing retry path.
- **Confidence:** 9/10
- **Source:** Luna audit claim verified against current Push2.swift, then primary agent implementation; physical post-update latency pending
- **Files:** Sources/KoalaTouch/Push2.swift
- **Date:** 2026-10-11

### historical-koala-link-needs-revalidation
- **Insight:** Archived Paper Picker notes report limited SP-404MKII controller feedback with built-in mappings enabled, while the accepted Koala Link configuration disables those mappings, so the old link is a research lead and cannot be assumed compatible with the working MPC route.
- **Confidence:** 8/10
- **Source:** learn; inspected current KoalaMap.swift and dated Paper Picker research claims
- **Files:** Sources/KoalaTouch/KoalaMap.swift, docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Preferences

### push-pad-hits-should-select-the-editing-pad
- **Insight:** The user wants pressing a Push pad to select it for editing instead of leaving Koala's editing target on one pad. The former shared profile disabled MIDI pad selection to protect Chopper keys on the same channel. Installed local 1.4.3 build 15 introduces a Push-only profile with selection enabled, mapped sample notes on channel 16, and unmapped keyboard/Chopper notes on channel 13. Normal hits update the local editing target immediately. Canonical mappings and conflicting raw-channel-1/keyboard-channel-13 mappings are checked before input; stale snapshot reads cannot replace a newer pad choice. Repeat puts the held editing pad last and skips held notes belonging to the other mode without altering release assignments. MPC retains its accepted false/channel-16 profile. Controller profile changes close/save and reopen Koala normally. The startup log and defaults.json confirmed true/13, 59 saved samples warmed, and the installed executable matched the build; physical source-pinning feedback remains pending.
- **Confidence:** 8/10
- **Source:** user request October 11, 2026; current local mapping files had no channel 1 or 13 entries; Luna audit claims verified against code; production compiler build, physical channel-split behavior pending
- **Files:** Sources/KoalaTouch/KoalaMap.swift, Sources/KoalaTouch/KoalaController.swift, Sources/KoalaTouch/KoalaIntegration.swift, Sources/KoalaTouch/PushKoalaBridge.swift, Sources/KoalaTouch/App.swift
- **Date:** 2026-10-11

### preserve-confirmed-koala-behavior-on-push
- **Insight:** The user explicitly wants Koala's verified quirks carried into Push 2 support, especially Chopper behavior, using the confirmed Koala Link build as the reference for adaptation.
- **Confidence:** 10/10
- **Source:** learn; direct user statement, 2026-10-11
- **Files:** docs/MIDI-MAPPING.md, docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Architecture

### push-display-values-need-provenance
- **Insight:** A custom Push screen must distinguish live Koala feedback, locally commanded state and saved-song snapshots, because autosaved files can lag edits made in Koala and do not establish a live waveform or playhead.
- **Confidence:** 9/10
- **Source:** learn; inspected archived KoalaSession.swift and KoalaController.swift
- **Files:** docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Tools

## Architecture

### push-preview-keeps-the-accepted-mpc-route
- **Insight:** Version 1.4.0 build 8 introduces a startup MPC Touch / Push 2 choice. It reuses the accepted shared Koala MIDI profile; the MPC bridge, overlay and signed touch driver remain unchanged. Push owns only its User MIDI port and documented display interface. All physical Push buttons have roles, with companion macros and repeat where Koala lacks native equivalents.
- **Confidence:** 9/10
- **Source:** inspected current implementation and successful release compiler build; physical Push hardware absent
- **Files:** Sources/KoalaTouch/App.swift, Sources/KoalaTouch/PushKoalaBridge.swift, Sources/KoalaTouch/KoalaController.swift, docs/PUSH2-CONTROLS.md
- **Date:** 2026-10-11

### push-preview-provenance-and-next-hardware-check
- **Insight:** The Push view uses saved song JSON/audio snapshots and locally commanded state, with live timing only if Koala sends MIDI clock. The observed native palette is approximated by pink FF2863, cyan 00CBEA, charcoal 2D2727; an exact active-theme palette was not established. RGB565 screen encoding and separate RGB LED palette entries use those accents, with original LED/configuration values captured for restoration. Next: verify physical display orientation/colors, all control events, clock/repeat timing and count-aware page-two chop mapping. Stable v1.3.0 remains the verified MPC release.
- **Confidence:** 9/10
- **Source:** rendered artwork and inspected Push transport/renderer; hardware and exact color validation pending
- **Files:** Sources/KoalaTouch/Push2.swift, Sources/Push2Display/Push2Display.c, Sources/KoalaTouch/KoalaLook.swift, docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Preferences

### push-controls-and-installable-preview
- **Insight:** User wants every Push button to have a creative useful role, correct Koala colors, and an installable build ready while away from their Push. Easy tasks should be delegated to Luna efficiently.
- **Confidence:** 10/10
- **Source:** direct user statements, 2026-10-11
- **Files:** docs/PUSH2-CONTROLS.md
- **Date:** 2026-10-11

## Performance

### push-waveforms-need-cached-audio-and-independent-snapshots
- **Insight:** The first physical Push session reported slow waveform updates. The old path waited for a one-second JSON poll, reopened each pad's WAV for its frame count, then sought/read 960 times for the selected waveform. The replacement polls saved metadata at 150 ms, caches frame counts and decoded peaks by path/inode/size/modification date, and decodes sequential PCM chunks on a separate cancellable queue. Only a result for the current displayed pad and unchanged audio signature is applied. Koala's own autosave timing remains a limit.
- **Confidence:** 9/10
- **Source:** direct user report; inspected old/new code; successful production compiler build; live build 9 logged first waveform decode/cache readiness at 138 ms, which is not an end-to-end physical latency measurement
- **Files:** Sources/KoalaTouch/PushKoalaBridge.swift, Sources/KoalaTouch/KoalaWaveformReader.swift, Sources/KoalaTouch/KoalaController.swift
- **Date:** 2026-10-11

### quiet-audio-needs-waveform-display-scaling
- **Insight:** A real selected saved WAV peaked near 0.00055 full scale. Rendering raw amplitudes made its Push waveform nearly invisible. Scale the cached display peaks by their maximum; leave PCM files, gain controls and audio output untouched. A truly silent clip remains flat.
- **Confidence:** 9/10
- **Source:** inspected current saved audio and Push preview; display-only scaling added in 1.4.1 build 10
- **Files:** Sources/KoalaTouch/KoalaWaveformReader.swift
- **Date:** 2026-10-11
