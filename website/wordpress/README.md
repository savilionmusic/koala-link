# Savilion Beats software page

Source for [savilionbeats.com/software](https://savilionbeats.com/software/).
The current release is **v1.4.7** (app 1.4.7, build 19; previous: 1.4.6,
build 18). MPC Touch is supported; Push 2 remains preview-only. The user confirmed on
2026-10-20 that version 1.4.5 works fine on MPC Touch. Push hardware
validation remains pending, so do not describe Push support as fully validated.
Koala Link is free. An email is required to reveal the installer; permission to
send software updates is a separate, optional choice. Standard controls are
mapped automatically after choosing the controller; first-time Koala settings
initialization is handled by the app, with guidance for any native setup dialogs.

The page presents **SAV LAB** as Savilion's software brand, using the supplied
Alicja Hand Bold horizontal wordmark and fonts with terracotta `#A94F39`, cream `#F5EBDD`, and
charcoal. Its brand styling is scoped to `.savi-software-page`. The follow
section links the verified Instagram `@savlabaudio`; Facebook and YouTube are
shown as coming soon while those profiles are being built.
The original supplied square logo is retained for the social sharing preview.
Keep the Alicja Hand font credit: copyright 2026 Alicja Gajewski, included with
the publisher's redistribution permission.

## Files

| File | WordPress location |
| --- | --- |
| `savilion-software.php` | `wp-content/mu-plugins/` |
| `page-software.php`, `software.css`, `software.js` | `wp-content/themes/savilion-dark/` |
| `assets/sav-lab/*` | `wp-content/uploads/software/sav-lab/` |

The theme's existing header/footer provide the site's navigation and skins.
Page-specific title, description, and social preview metadata are handled by the
software MU plugin. These files preserve the signup workflow, data controller,
consent language, privacy details, and unsubscribe process.
Both forms submit to `/software/` and reuse the same signup handler. The
Savilion page includes its WordPress nonce and ticket; the Statis page uses a
strict origin check and source marker so it can share the flow without
publishing a secret in static HTML. The request is handled on the page route,
avoiding the hosting browser-check interstitial on background admin-post
requests. Both pages use the same WordPress subscriber table. The email is
required to unlock the free installer, but only people who select the optional
software-updates consent checkbox are stored as subscribers and sent to the
MailerLite group **SAV LAB Software** (ID `202034791356302567`). Account-level
double opt-in for API/integration signups is enabled. New contacts can download
immediately; if MailerLite reports an unconfirmed contact, the page asks them
to confirm by email. If MailerLite is unavailable or its server key is missing,
the download still works and the page explains that the updates signup needs a
retry. Existing MailerLite subscribers keep their current provider status.

On the live Savilion Beats WordPress server, store the API token outside the
repository in `wp-config.php` as `SAVI_MAILERLITE_API_KEY`. Never put it in a
page, theme file, static HTML, or source control. This endpoint syncs only new
or returning opt-ins from either website. It does not migrate historical
WordPress records; any backfill needs separate review and authorization. Use
MailerLite to send campaigns and manage current delivery/unsubscribe status;
the local WordPress table is a consent record, not a campaign list. Do not
send the WordPress CSV export directly. The Software signups admin page checks
the server's MailerLite connection. Legacy WordPress unsubscribe links also
suppress the contact in MailerLite, with a queued retry if the service is
temporarily unavailable.

## Release updates

Upload installers and artwork under
`wp-content/uploads/software/koala-link/` before changing the page or download
URLs. Both MPC Touch and Push 2 preview download keys point to the exact same
audited installer bytes, named `Koala-Link-1.4.7-Installer.pkg`. The package is
identical to the installer attached to the current main release:
[v1.4.7](https://github.com/savilionmusic/koala-link/releases/tag/v1.4.7).
Its audited size is 1,464,534 bytes and SHA-256 is
`60ae880f2e3f18faac1652266b625f69ff254fca351dc79dda6d77aa4d10f428`.
The manual is `Koala-Link-1.4.7-Manual.pdf`, 159,810 bytes, SHA-256
`68270608f55424a4b45ba9a91664b1df04dc30ddf17f233df6c733a98a77ca65`.
Koala Sampler is sold separately. MPC Touch also needs DisplayLink Manager
(separate) and Accessibility approval. Webcam recording needs a camera and
Camera plus Screen & System Audio Recording permission. Keep the older 1.4.6
files in place, keep `SHA256SUMS.txt` alongside the downloads, and save current
page/plugin copies before deployment.

## Software signups

Opted-in addresses are stored in WordPress, with consent information and
controller preference. Administrators can manage/export them under **Software
signups**. There is no automatic campaign sending. Updating a download URL
does not change subscriber records, consent wording or unsubscribe behavior.
Hosting credentials and subscriber exports are excluded from this repository.
