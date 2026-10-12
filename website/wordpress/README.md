# Savilion Beats software page

Source for [savilionbeats.com/software](https://savilionbeats.com/software/).
The Push download is **v1.4.5-preview.1** (app 1.4.5, build 17); MPC Touch
stable remains 1.3.0. Koala Link is free and email signup is optional.

## Files

| File | WordPress location |
| --- | --- |
| `savilion-software.php` | `wp-content/mu-plugins/` |
| `page-software.php`, `software.css`, `software.js` | `wp-content/themes/savilion-dark/` |

The theme's existing header/footer provide the site's navigation and skins.
These files preserve the existing signup workflow and 2000 skin contrast.

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
