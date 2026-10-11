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
