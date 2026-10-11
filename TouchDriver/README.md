# MPC Touch touchscreen driver

`mpc_touchd` reads the MPC Touch's SiS touchscreen and posts pointer events
onto the MPC display. Two contacts while Koala is the frontmost app become
Alt-scroll zoom events for its sample editor and piano roll.

The app ships the signed driver with SHA-256
`d5f4db8ca9df3b836743a68cd63b3201f60287e0639147437a5091cc4fb881e8`.
The installer sets `--pinch-gain 500`; the driver's command-line default is
560. The gain can be tuned through the LaunchAgent's arguments without
rebuilding or changing its Accessibility approval.

The accepted build includes a movement threshold for holds, adaptive drag
smoothing, immediate first movement, and the actual release coordinate for
drag-to-trash. Pinch mode clears when no active fingertip remains, including
the panel's final report that still counts a lifted contact.

```sh
./build.sh       # build and ad-hoc sign; does not install
./install.sh     # build, install and restart for the current user
```

Every ad-hoc driver rebuild needs Accessibility approved again. The app and
installer build scripts copy the accepted driver without rebuilding it.

The service lives at `~/Library/Application Support/MPC Touch Driver/`, with
LaunchAgent `com.savilion.mpc-touchd` and log `~/Library/Logs/mpc_touchd.log`.
Paper Cut uses the same service. Do not run another raw touchscreen reader
while this driver is active.

`tools/` contains the read-only device snapshot and flight recorder, plus
`mpc_replug`, which re-enumerates the MPC controller to recover a MIDI lock-up.
These tools do not replace DisplayLink or modify controller firmware.
