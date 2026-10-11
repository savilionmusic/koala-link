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

### historical-koala-link-needs-revalidation
- **Insight:** Archived Paper Picker notes report limited SP-404MKII controller feedback with built-in mappings enabled, while the accepted Koala Link configuration disables those mappings, so the old link is a research lead and cannot be assumed compatible with the working MPC route.
- **Confidence:** 8/10
- **Source:** learn; inspected current KoalaMap.swift and dated Paper Picker research claims
- **Files:** Sources/KoalaTouch/KoalaMap.swift, docs/PUSH2-RESEARCH.md
- **Date:** 2026-10-11

## Preferences

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
