# MPC Touch MIDI mapping

## Physical pad order

Pads are numbered left to right, starting at the bottom row. The hardware pad
IDs stay the same when a bank changes; Koala Touch assigns the bank in software.
Pad strikes arrive on the Public endpoint, channel 10. Translated pad notes and
polyphonic pressure go to Koala on channel 16.

| Physical pad | Raw note (hex) | Raw note (decimal) | Sample bank A note | Chopper bank A note |
| --- | --- | --- | --- | --- |
| 1 | 25 | 37 | 36 | 60 |
| 2 | 24 | 36 | 37 | 61 |
| 3 | 2A | 42 | 38 | 62 |
| 4 | 52 | 82 | 39 | 63 |
| 5 | 28 | 40 | 40 | 64 |
| 6 | 26 | 38 | 41 | 65 |
| 7 | 2E | 46 | 42 | 66 |
| 8 | 2C | 44 | 43 | 67 |
| 9 | 30 | 48 | 44 | 68 |
| 10 | 2F | 47 | 45 | 69 |
| 11 | 2D | 45 | 46 | 70 |
| 12 | 2B | 43 | 47 | 71 |
| 13 | 31 | 49 | 48 | 72 |
| 14 | 37 | 55 | 49 | 73 |
| 15 | 33 | 51 | 50 | 74 |
| 16 | 35 | 53 | 51 | 75 |

Banks B, C and D add 16, 32 and 48 to the bank A translated note. Koala displays
MIDI 60 as C3. The displayed octave varies between applications; the MIDI
number is the unambiguous value. The user confirmed that MIDI 60 plays chop 1
with a 128-chop sample on 2026-10-11. Starting at C−1 (MIDI 12) can appear
correct with 16 chops because the lower notes wrap, but shifts the first pad
at other chop counts.

The pad ID table was inherited from the existing MPC integration. A physical
MPC Touch trace on 2026-10-11 independently confirmed pad 1 as raw 37 and pad 9
as raw 48, plus bank A and 16 LEVELS. That trace does not establish that every
pad or every control has been independently checked on the device.

## Banks, modes and releases

- Sample mode: banks A–D send notes 36–99.
- Chopper keyboard mode: banks A–D send notes 60–123, starting at bank A.
- Leaving Chopper keyboard mode restores the previous sample bank.
- A held pad captures its translated note at the strike. Bank or mode changes
  do not change the pressure or release note for that strike.
- The restored song's keyboard mode is read before Koala launches. Native
  Sequence keyboard-button taps update the bridge without sending a second
  toggle.
- The four banks play chops 1–64 when the sample has at least 64 slices.
  Increasing Koala's chop count to 128 does not add another four hardware
  banks to this profile.

Koala controls the chop count and the selected sample's Chopper behavior.
Use **CHOP: NOTE** for note selection. The bridge does not alter slice markers
or the number of chops. Koala wraps notes across the available slices when
the sample has fewer chops: with 17, bank B pad 1 is chop 17 and pad 2 returns
to chop 1; with 26, bank B pad 10 is chop 26 and pad 11 returns to chop 1.

## Other controls

| Control | Hardware input | Translated output / behavior |
| --- | --- | --- |
| Pad banks A–D | Ch1 notes 35–38 | Select software bank; no musical note |
| 16 LEVELS | Public Ch1 note 40 | Ch15 note 40; toggle keyboard and bridge mode once |
| Q-Link bank selector | Ch1 note 0 | Cycle four Q-Link banks; no musical note |
| Q-Link knobs 1–4 | Ch1 CC16–19 | Ch15 CC1–4, 5–8, 9–12 or 13–16 |
| Q-Link touch 1–4 | Ch1 notes 84–87 | Ch15 notes 84–99, captured until release |
| REC | Ch1 note 73 | Ch15 note 73; Koala record toggle |
| PLAY | Ch1 note 82 | Ch15 note 82; Koala play toggle |

Q-Link bank A has automatic start, length, volume and pitch assignments.
The other Q-Link banks are available for custom MIDI Learn. Other Public
controls are forwarded on channel 15; forwarding alone does not give a
control an automatic Koala assignment.

Public and Private endpoints have independent MIDI decoders and held state.
Mirrored selectors and known function buttons are combined so one physical
press has one action. 16 LEVELS uses Public only, including its release; delayed
Private copies cannot toggle the keyboard a second time. Native keyboard
clicks are tracked through release, with one update per completed click.
Private musical pad messages are ignored. A Private
pad release cannot end a Public pad strike.

## Saved mappings

Koala Touch maintains its canonical mappings while Koala is closed and saves
a backup before writing. Duplicate assignments to an owned address or MIDI
key are repaired. MIDI Learn can also receive the MPC's raw port; relearning
automatic controls can replace the translated assignments. Quit and reopen
Koala Touch to restore them. Song-specific MIDI maps can override the global
map and must be reviewed separately if a particular song behaves differently.

## Protocol reference

[MPC-LiveXplore](https://github.com/TheKikGen/MPC-LiveXplore) documents related
Akai controller protocols. Similar button and LED families are useful
references, but model IDs and commands must be checked for the MPC Touch.
Koala Touch uses its existing accepted Touch setup sequence; it does not send
experimental initialization or firmware commands.
