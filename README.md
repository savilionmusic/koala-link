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

Press **16 LEVELS** to enter Chopper keyboard mode. The physical pads send 64
chromatic notes starting at **C−1 (MIDI note 0)**, on channel 16:

| Pad bank | MIDI notes |
| --- | --- |
| A | 0–15 |
| B | 16–31 |
| C | 32–47 |
| D | 48–63 |

The first note is the bottom-left physical pad, with notes increasing across
each row from bottom to top. Bank changes address more chops in the selected
sample. Press **16 LEVELS** again to restore sample-pad notes 36–99. Use the
physical button to keep the pad mapping and Koala's keyboard toggle together.
Held notes keep their original assignment until release, even if the bank or
mode changes.

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
