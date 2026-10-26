# Hand-off: update Savilion's websites for Koala Link 1.4.7

You are updating the Koala Link software page at https://savilionbeats.com/software/ (and any other page that mentions Koala Link) from version 1.4.6 to **1.4.7**. The facts in this file are checked and current as of 2026-10-22. Do not invent features, prices or support claims beyond them.

## Release facts

| | |
| --- | --- |
| Product | Koala Link (by Savilion, brand SAV LAB). Free. Email signup is optional. |
| Version | 1.4.7, build 19 (previous: 1.4.6, build 18) |
| Release page | https://github.com/savilionmusic/koala-link/releases/tag/v1.4.7 |
| Installer | `Koala-Link-1.4.7-Installer.pkg`, 1,464,534 bytes |
| Installer SHA-256 | `60ae880f2e3f18faac1652266b625f69ff254fca351dc79dda6d77aa4d10f428` |
| Manual | `Koala-Link-1.4.7-Manual.pdf` |
| Manual SHA-256 | `68270608f55424a4b45ba9a91664b1df04dc30ddf17f233df6c733a98a77ca65` |
| Direct downloads (after the release is published) | https://github.com/savilionmusic/koala-link/releases/download/v1.4.7/Koala-Link-1.4.7-Installer.pkg and https://github.com/savilionmusic/koala-link/releases/download/v1.4.7/Koala-Link-1.4.7-Manual.pdf |
| Requirements | Apple silicon Mac, macOS 13 or later, Koala Sampler for Mac (sold separately). MPC Touch also needs DisplayLink Manager (separate) and Accessibility approval. Webcam needs a camera and Camera plus Screen & System Audio Recording permission. |
| Status | MPC Touch: supported. Push 2: **preview only**; do not call it fully supported or validated. The app is not notarized, so macOS may ask for Open Anyway in Privacy & Security. |

## What's new in 1.4.7 (website copy, edit freely)

**Film your beats.** The new Webcam records you playing with Koala's own sound, the pad you hit and its waveform on screen. Record in 16:9 or 9:16 for Reels, TikTok and Shorts. The MP4 files (1080×1920, H.264 and AAC) are ready to upload as they are.

**Video effects that follow the music.** Koala's STUTTER repeats the picture in time with the beat. Turn further and it speeds up from quarter notes to 32nds, and each repeat fades in smoothly. CUTTER chops the picture to black in time.

**Studio tools for the recording.** A floating preview stays on top while you make the beat. ARM starts recording on your first pad hit. There's also an output window for OBS live streams, a dB meter, drive, an MPC3000-style clipper, a limiter, and LISTEN to hear it all live.

**Solo with one hand.** On the MPC Touch, hold a pad bank button (A–D) to solo Koala's mixer track 1–4, and let go to bring the mix back. A quick tap still changes the bank. SHIFT plus a bank button latches the solo on.

**Perform effects on the Q-Links.** Q-Link bank D now controls STUTTER, TALKBOX, FILTER and CUTTER. A quarter turn covers the full range, and turning all the way down switches the effect off.

## Changes to make

1. **WordPress page files.** These live in the Koala Link GitHub repo under `website/wordpress/`; that folder's README lists where each file goes.
   - `savilion-software.php`: in `savi_software_downloads()`, change `Koala-Link-1.4.6-Installer.pkg` to `Koala-Link-1.4.7-Installer.pkg`.
   - `page-software.php`: replace every visible `1.4.6` with `1.4.7`. That covers the release line, the display label, the download button text and the Push 2 preview note. Add a short "New in 1.4.7" section using the copy above (Webcam, video effects, hold-to-solo, Q-Link effects). Add a "Download the manual (PDF)" link next to the installer button.
   - `website/wordpress/README.md`: update the release, size and SHA-256 to the values above.
2. **Uploads.** Upload `Koala-Link-1.4.7-Installer.pkg`, `Koala-Link-1.4.7-Manual.pdf` and an updated `SHA256SUMS.txt` to `wp-content/uploads/software/koala-link/`. Do this before changing the page links. Keep the 1.4.6 files there too, so old links keep working.
3. **GitHub README.** In the repo's `README.md`, point the download link and "current release" text at v1.4.7 (app 1.4.7, build 19). Add a short Webcam section linking the manual.
4. **Social.** Optional: an Instagram post for `@savlabaudio` announcing the Webcam, filmed with Koala Link itself.

## Rules

- Keep the existing SAV LAB branding: the Alicja Hand font, terracotta `#A94F39`, cream `#F5EBDD`, charcoal. Keep the signup form, consent wording, privacy and unsubscribe text exactly as they are.
- Keep the Alicja Hand font credit: copyright 2026 Alicja Gajewski, included with the publisher's redistribution permission.
- Koala Sampler, Akai MPC Touch, Ableton Push 2 and DisplayLink belong to their owners. Do not imply endorsement.
- Back up the current page and plugin files before deploying. Never commit hosting credentials or subscriber exports.
