# Koala Link

Use Koala Sampler with an Akai MPC Touch or Ableton Push 2. Koala Link is free
to download and use. Choose **MPC Touch** or **Push 2** in the startup window;
change controllers later from the Koala Link menu. Push 2 support is a preview:
the build succeeds and its screen artwork has been rendered and visually reviewed
offline. Physical Push hardware validation is still pending.

MPC Touch's stable release line is **1.3.0**. The Push 2 preview is
**1.4.0-preview.1** (app version **1.4.0**, build **8**).

**[Download the Push 2 preview installer](https://github.com/savilionmusic/koala-link/releases/tag/v1.4.0-preview.1)** · [MPC Touch stable installer](https://github.com/savilionmusic/koala-link/releases/tag/v1.3.0)

![Koala Link controller choice](docs/screens/Koala-Link-Controller-Choice.png)

[Push screen previews](docs/screens/Koala-Link-Push-Screens.png) · [Complete Push controls](docs/PUSH2-CONTROLS.md)

## Requirements

- An Apple silicon Mac running macOS 13 or later, and Koala Sampler for Mac.
- Either an Akai MPC Touch (with DisplayLink Manager), or an Ableton Push 2
  connected by USB. Close Ableton Live while Koala Link uses the Push display,
  and quit Paper Cut if it is using the Push.

## Install

1. Download **Koala-Link-Installer.pkg** from Releases and run it.
2. Open Koala Link from Applications and choose your controller. Connect and
   power the Push 2 before choosing it; connect the MPC Touch before choosing it.
3. For MPC Touch, allow **Koala Link** and **mpc_touchd** in System Settings
   → Privacy & Security → Accessibility when prompted.

Koala Link replaces Koala Touch and keeps your existing Koala MIDI settings.

The app and installer use ad-hoc signing and are not notarized. If macOS blocks
the download, use the Open Anyway control in Privacy & Security.

## MPC Touch controls

Koala fills the MPC screen. The four pad banks provide 64 sample pads;
Q-Links, FULL LEVEL, 16 LEVELS, REC and PLAY control Koala. Quitting Koala
also quits Koala Link.

Press **FULL LEVEL** to toggle maximum pad velocity. With its light on, every
physical pad strike sends velocity 127; with it off, strikes keep their measured
velocity. This works across banks A–D in sample and Chopper modes. Koala Link
enables Koala's MIDI and keyboard velocity settings for this control. FULL LEVEL
starts off when Koala Link opens, and retains its state through an MPC reconnect.

Press **16 LEVELS** to enter Chopper keyboard mode. Physical bank A pad 1
plays **chop 1**. Notes 60–123 address the first 64 chops in order, regardless
of the sample's chop count, on channel 16:

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
Koala wraps notes across the available slices, including smaller and odd chop
counts. C−1 is not the first chop. With 128 chops, these four banks still play
chops 1–64. Reaching chops 65–128 would require another page, with the MIDI
note ceiling handled and the behavior confirmed live in Koala; that is not
part of the MPC mapping described here.

Koala Link follows the keyboard state in Koala's restored song and native
Sequence keyboard-button taps, as well as the physical **16 LEVELS** button.
Held notes keep their original assignment until release, even if the bank or
mode changes.

The sample-pad map is maintained automatically at launch with backups. Koala's
MIDI Learn also hears the hardware's raw port, so learning these same controls
by hand can replace the translated mapping. Quit and reopen Koala Link to
restore its assignments. Q-Link bank A is mapped to start, length, volume and
pitch. Banks B–D expose CC5–16 on channel 15 for custom MIDI Learn assignments.
See [MIDI mapping](docs/MIDI-MAPPING.md) for the physical pad table and routing details.

The touchscreen driver supports steady holds, drag-to-trash and two-finger
zoom in the sample editor and piano roll. The installer sets pinch gain to
500. A 1024×640 MPC display mode made small Koala controls easier to touch on
the development setup; the driver follows the screen's current resolution.

Preview the Push screens offline (no controller or MIDI endpoints are opened):

```sh
"build/Koala Link.app/Contents/MacOS/KoalaTouch" --render-push /tmp/koala-link-screens
```

## Build

Install Xcode Command Line Tools, then run:

```sh
./build-app.sh
./installer/build-installer.sh
```

The app is written to `build/Koala Link.app`; the installer is written to
`dist/Koala-Link-Installer.pkg`. Building does not install either one.

Push controls and current validation limits are in the
[Push 2 controls](docs/PUSH2-CONTROLS.md) and
[Push 2 research](docs/PUSH2-RESEARCH.md) notes.

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

Koala Link is an independent companion app for Koala Sampler and supported controllers.

## More controllers

The controller picker keeps the MPC and Push sessions separate. See the
[Push 2 control reference](docs/PUSH2-CONTROLS.md) and
[implementation and validation status](docs/PUSH2-RESEARCH.md).
