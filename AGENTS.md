# Koala Touch working instructions

- Build the app with `build-app.sh` and the installer with `installer/build-installer.sh`.
- The touch driver is shared with Paper Cut. Never remove it while the other app is installed.
- Change, rebuild or re-sign `TouchDriver/mpc_touchd` only when the user asks. Ad-hoc rebuilds require Accessibility approval again.
- App and installer builds copy the accepted signed driver; do not rebuild it as part of those builds.
- Never run a second raw touchscreen reader while `com.savilion.mpc-touchd` is running.
- Ask before changing AkaiTouchPanel.kext, DisplayLink or firmware. Do not send undocumented startup commands or Akai 0x5A experiments.
- Preserve contact and MIDI note assignments until their releases, including across bank or mode changes.
- Public and Private MPC endpoints have separate decode and held state; Private selectors must never duplicate Public musical input.
- Preserve font attribution and the publisher's recorded redistribution permission.
- Installer packages are distributed as GitHub Release assets.
