# Savilion Beats software page

Source for [savilionbeats.com/software](https://savilionbeats.com/software/).
The Push download is **v1.4.5-preview.1** (app 1.4.5, build 17); MPC Touch
stable remains 1.3.0. Koala Link is free and email signup is optional.

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
URLs. The current preview installer is
`Koala-Link-1.4.5-Push-Preview-Installer.pkg` and the sample artwork is
`Koala-Link-1.4.5-Push-Sample.png`. The installer is identical to the package
attached to the matching GitHub release. Keep `SHA256SUMS.txt` alongside the
downloads and save current page/plugin copies before deployment.

## Software signups

Opted-in addresses are stored in WordPress, with consent information and
controller preference. Administrators can manage/export them under **Software
signups**. There is no automatic campaign sending. Updating a download URL
does not change subscriber records, consent wording or unsubscribe behavior.
Hosting credentials and subscriber exports are excluded from this repository.
