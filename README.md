# Koala Touch

Use Koala Sampler on an Akai MPC Touch, with its screen, pads, banks, Q-Links
and transport controls. Koala Touch is free to download and use.

**[Download the installer](https://github.com/savilionmusic/koala-touch/releases/latest)**

## Requirements

- An Apple silicon Mac running macOS 13 or later.
- An Akai MPC Touch.
- [Koala Sampler for Mac](https://www.koalasampler.com/download/).
- [DisplayLink Manager](https://www.synaptics.com/products/displaylink-graphics/downloads/macos) for the MPC screen.

## Install

1. Download **Koala-Touch-Installer.pkg** from Releases and run it.
2. Open Koala Touch from Applications with the MPC connected.
3. Allow **Koala Touch** and **mpc_touchd** in System Settings → Privacy & Security → Accessibility when prompted.

The app and installer use ad-hoc signing and are not notarized. If macOS blocks
the download, use the Open Anyway control in Privacy & Security.

## Controls

Koala fills the MPC screen. The four pad banks provide 64 sample pads;
Q-Links, 16 LEVELS, REC and PLAY control Koala. Quitting Koala also quits Koala Touch.

Press **16 LEVELS** to enter Chopper keyboard mode. Physical bank A pad 1
plays **chop 1**. The pads send 64 chromatic notes starting at **MIDI note 60
(Koala's C3)**, on channel 16:

| Pad bank | Chops with at least 64 slices | MIDI notes |
| --- | --- | --- |
| A | 1–16 | 60–75 |
| B | 17–32 | 76–91 |
| C | 33–48 | 92–107 |
| D | 49–64 | 108–123 |

The first note is the bottom-left physical pad, with notes increasing across
each row from bottom to top. Bank changes address more chops in the selected
sample. Entering Chopper mode starts at bank A; leaving restores the previous
sample bank and sample-pad notes 36–99. The Chopper's own chop count and
**CHOP: NOTE** setting control how it responds to the notes. With fewer chops,
Koala wraps notes across the available slices. With 128 chops, these four banks
play the first 64. C−1 is below Koala's Chopper root and can shift which chop a
pad plays when the chop count changes.
Koala Touch follows the keyboard state in Koala's restored song and native
Sequence keyboard-button taps, as well as the physical **16 LEVELS** button.
Held notes keep their original assignment until release, even if the bank or
mode changes.

The sample-pad map is maintained automatically at launch with backups. Koala's
MIDI Learn also hears the hardware's raw port, so learning these same controls
by hand can replace the translated mapping. Quit and reopen Koala Touch to
restore its assignments. Q-Link bank A is mapped to start, length, volume and
pitch. Banks B–D expose CC5–16 on channel 15 for custom MIDI Learn assignments.
See [MIDI mapping](docs/MIDI-MAPPING.md) for the physical pad table and routing details.

The touchscreen driver supports steady holds, drag-to-trash and two-finger
zoom in the sample editor and piano roll. The installer sets pinch gain to
500. A 1024×640 MPC display mode made small Koala controls easier to touch on
the development setup; the driver follows the screen's current resolution.

## Build

Install Xcode Command Line Tools, then run:

```sh
./build-app.sh
./installer/build-installer.sh
```

The app is written to `build/Koala Touch.app`; the installer is written to
`dist/Koala-Touch-Installer.pkg`. Building does not install either one.

`TouchDriver/` contains the driver source and the accepted signed binaries
used by the app. App builds copy those binaries without re-signing them.
Rebuilding the driver with `TouchDriver/build.sh` changes its ad-hoc signature
and requires another Accessibility approval after installation.

## Remove

Run `/Library/Application Support/Koala Touch/uninstall.sh`. The touchscreen
service is shared with Paper Cut, and is retained when Paper Cut is installed.

## Credits

Created by Savilion. Alicja Hand handwriting font by Alicja Gajewski, included
with redistribution permission confirmed by the publisher. See [NOTICE.md](NOTICE.md).

Koala Touch is an independent companion app for Koala Sampler and the MPC Touch.
