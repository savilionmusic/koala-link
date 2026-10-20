# Savilion Beats software page

Source for [savilionbeats.com/software](https://savilionbeats.com/software/).
The current release is **v1.4.5** (app 1.4.5, build 17). The same installer
supports MPC Touch and optional Push 2 preview use. The user confirmed on
2026-10-20 that the current app works fine on MPC Touch. Push hardware
validation remains pending, so do not describe Push support as fully validated.
Koala Link is free and email signup is optional.

The page presents **SAV LAB** as Savilion's software brand, using the supplied
Alicja Hand Bold horizontal wordmark and fonts with terracotta `#A94F39`, cream `#F5EBDD`, and
charcoal. Its brand styling is scoped to `.savi-software-page`. The follow
section links the verified Instagram `@savlabaudio`; Facebook and YouTube are
shown as coming soon while those profiles are being built.
The original supplied square logo is retained for the social sharing preview.

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
The form submits on `/software/` and reuses the existing signup handler and all
of its nonce, ticket, origin, consent, validation, and rate checks. This avoids
the hosting browser-check interstitial on background admin-post requests.

## Release updates

Upload installers and artwork under
`wp-content/uploads/software/koala-link/` before changing the page or download
URLs. Both MPC Touch and Push download keys point to the exact same audited
installer bytes, named `Koala-Link-1.4.5-Installer.pkg`. The package is
identical to the installer attached to the current main release:
[v1.4.5](https://github.com/savilionmusic/koala-link/releases/tag/v1.4.5).
Its audited size is 1,280,912 bytes and SHA-256 is
`762b4e8208a213b4cf836d3500b6043b145045ab29c8e0b1f99b593b6fa5bcbc`.
The older `v1.4.5-preview.1` release tag is historical. The Touch driver is
bundled; Koala Sampler and DisplayLink Manager are separate prerequisites for
MPC Touch. Push 2 remains preview-only pending physical validation. The sample
artwork is `Koala-Link-1.4.5-Push-Sample.png`. Keep `SHA256SUMS.txt` alongside
the downloads and save current page/plugin copies before deployment.

## Software signups

Opted-in addresses are stored in WordPress, with consent information and
controller preference. Administrators can manage/export them under **Software
signups**. There is no automatic campaign sending. Updating a download URL
does not change subscriber records, consent wording or unsubscribe behavior.
Hosting credentials and subscriber exports are excluded from this repository.
