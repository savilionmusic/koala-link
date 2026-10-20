<?php
if (!defined('ABSPATH')) { exit; }
$downloads = savi_software_downloads();
$software_assets = content_url('/uploads/software/koala-link/');
$sav_lab_assets = content_url('/uploads/software/sav-lab/');
$signup_complete = isset($_GET['signup']) && $_GET['signup'] === 'complete';
// Adapt this page's title and sharing tags while preserving the shared header.
ob_start();
get_header();
echo savi_software_brand_head_markup(ob_get_clean());
?>
<main id="main-content" class="savi-software-page">
    <div class="savi-software-topline"><span>SOFTWARE / SAVILION</span><a href="#software-updates">Release updates ↓</a></div>
    <section class="savi-software-intro" aria-labelledby="software-title">
        <div class="savi-software-brand-copy"><h1 id="software-title"><img class="savi-software-brand-logo" src="<?php echo esc_url($sav_lab_assets . 'SAV-LAB-horizontal.svg'); ?>" alt="SAV LAB" width="329" height="100" fetchpriority="high"></h1><p class="savi-software-brand-tagline">Music software by Savilion.</p></div>
        <p class="savi-software-brand-support">Hands-on tools for making music. Built in the studio by Savilion.</p>
    </section>

    <section class="savi-software-product" aria-labelledby="koala-link-title">
        <div class="savi-software-product-head"><span>01 / KOALA LINK</span><span>BY SAV LAB · FREE DOWNLOAD · macOS</span></div>
        <div class="savi-software-product-grid">
            <div class="savi-software-product-copy">
                <h2 id="koala-link-title">Koala Link</h2>
                <p class="savi-software-product-lede">Your controller.<br>Your Koala workflow.</p>
                <p>Connect Koala Sampler for Mac to MPC Touch or Ableton Push 2. Play samples, work with chops and shape your sound from the hardware. Choose your controller when Koala Link opens.</p>
                <div class="savi-software-actions">
                    <a class="savi-software-button is-primary" href="<?php echo esc_url($downloads['stable']); ?>" download>Download for MPC Touch <span aria-hidden="true">↓</span></a>
                    <a class="savi-software-text-link" href="#push-preview">Explore Push 2 preview →</a>
                </div>
                <p class="savi-software-release"><span>v1.4.5 · MPC Touch release</span> · Apple silicon · macOS 13+</p>
                <p class="savi-software-small">One installer includes the app and touchscreen driver. Requires Koala Sampler (sold separately) and DisplayLink Manager. Email signup is optional.</p>
            </div>
            <figure class="savi-software-app-figure">
                <div class="savi-software-display-label"><span>KOALA LINK / CONTROLLER SELECT</span><span>VERSION 1.4.5</span></div>
                <img src="<?php echo esc_url($software_assets . 'Koala-Link-Controller-Choice.png'); ?>" alt="Koala Link's controller picker with MPC Touch and Push 2 options." width="1440" height="760" fetchpriority="high">
                <figcaption>Choose MPC Touch or Push 2 at launch. Push 2 support is a preview included in the same installer.</figcaption>
            </figure>
        </div>
        <div class="savi-software-features">
            <div><span>PLAY</span><h3>Four banks. All your pads.</h3><p>Play Koala’s <span class="savi-software-number">64</span> sample pads across banks A–D. Toggle FULL LEVEL for consistent pad hits.</p></div>
            <div><span>CHOP</span><h3>Chops stay in order.</h3><p>Use 16 LEVELS for Chopper keyboard mode, with mapping that follows Koala’s slice behavior and smaller or odd chop counts.</p></div>
            <div><span>TOUCH</span><h3>Koala on the MPC screen.</h3><p>Hold, drag pads to the trash, and pinch to zoom in the sample editor and piano roll. Q-Links and transport controls are mapped.</p></div>
        </div>
    </section>

    <section class="savi-software-updates" id="software-updates" aria-labelledby="updates-title">
        <div class="savi-software-updates-copy">
            <p class="savi-software-eyebrow">SOFTWARE / RELEASE LIST</p>
            <h2 id="updates-title">Hear what’s next.</h2>
            <p>Get Koala Link updates and news about new SAV LAB software, including Paper Cut. Join the list for future releases and product launches.</p>
            <p class="savi-software-small">Joining is optional. Koala Link stays free.</p>
        </div>
        <div class="savi-software-form-wrap">
            <form id="savi-software-signup" action="<?php echo esc_url(home_url('/software/')); ?>" method="post" <?php echo $signup_complete ? 'hidden' : ''; ?>>
                <input type="hidden" name="action" value="savi_software_signup">
                <?php wp_nonce_field('savi_software_signup', '_wpnonce', false); ?>
                <input type="hidden" name="ticket" value="<?php echo esc_attr(savi_software_ticket()); ?>">
                <div class="savi-software-field"><label for="savi-software-email">Email address <span>(required)</span></label><input id="savi-software-email" type="email" name="email" maxlength="254" required autocomplete="email" spellcheck="false" placeholder="you@example.com" aria-describedby="savi-software-privacy savi-software-form-status"></div>
                <div class="savi-software-field"><label for="savi-software-interest">Your controller</label><select id="savi-software-interest" name="interest"><option value="both">MPC Touch + Push 2 / Exploring</option><option value="mpc-touch">MPC Touch</option><option value="push-2">Push 2</option></select></div>
                <div class="savi-software-trap" aria-hidden="true"><label for="savi-company-website">Leave this field empty</label><input id="savi-company-website" type="text" name="company_website" tabindex="-1" autocomplete="off"></div>
                <label class="savi-software-consent" for="savi-software-consent"><input id="savi-software-consent" type="checkbox" name="consent" value="yes" required><span><?php echo esc_html(SAVI_SOFTWARE_CONSENT); ?></span></label>
                <button class="savi-software-button is-primary" type="submit">Join software updates <span aria-hidden="true">→</span></button>
                <p class="savi-software-form-status" id="savi-software-form-status" role="status" tabindex="-1"></p>
                <p class="savi-software-small" id="savi-software-privacy">Your email and signup preference are stored by Savilion Beats for software updates and product announcements. Unsubscribe from future emails at any time. <a href="<?php echo esc_url(home_url('/privacy-policy/')); ?>">Privacy policy</a>. Need help? <a href="<?php echo esc_url(home_url('/contact/')); ?>">Contact Savilion</a>.</p>
            </form>
            <div id="savi-software-success" class="savi-software-success" role="status" tabindex="-1" <?php echo $signup_complete ? '' : 'hidden'; ?>>
                <p class="savi-software-eyebrow">SAV LAB / SIGNUP SAVED</p><h3>You’re on the list.</h3><p>Koala Link is ready to download. We’ll use your signup for SAV LAB software updates and future product news.</p>
                <a class="savi-software-button is-primary" href="<?php echo esc_url($downloads['stable']); ?>" download>Download Koala Link 1.4.5 ↓</a>
                <a class="savi-software-text-link" href="#push-preview">Explore the included Push 2 preview →</a>
                <p class="savi-software-small">Push 2 support is a preview. The latest build adds faster display feedback and sample deletion; complete control validation is ongoing.</p>
            </div>
        </div>
    </section>

    <section class="savi-software-push" id="push-preview" aria-labelledby="push-title">
        <div class="savi-software-section-heading"><p class="savi-software-eyebrow">SAV LAB / KOALA LINK / NEW CONTROLLER</p><span class="savi-software-tag">PREVIEW</span></div>
        <div class="savi-software-push-copy"><h2 id="push-title">A Koala view on Push 2.</h2><p>Play and select samples from the pads, trim with the encoders, and perform with effects and the touch strip. Custom sample, piano-roll, sequence, EQ and mixer views bring Koala to the Push display.</p></div>
        <figure class="savi-software-push-screen"><img src="<?php echo esc_url($software_assets . 'Koala-Link-1.4.5-Push-Sample.png'); ?>" alt="Rendered Push 2 sample screen with a waveform, sample start and end, pitch and volume controls, and a bank indicator." width="960" height="160" loading="lazy"><figcaption>Sample screen artwork rendered from version 1.4.5. New gestures and full control coverage are still being validated on hardware.</figcaption></figure>
        <div class="savi-software-push-bottom"><p>The Push 2 preview is included in the same <span class="savi-software-number">1.4.5</span> installer. It adds cached waveforms, immediate trim and sequence feedback, and pad selection for editing. To delete a sample, leave NOTE mode, hold one pad and press DELETE; confirm in Koala if prompted. Recording notes use a local timing preview that settles to Koala’s saved data. Mac edits and new audio still depend on Koala saving; create and edit chops in Koala.</p><a class="savi-software-button" href="<?php echo esc_url($downloads['preview']); ?>" download>Download Koala Link 1.4.5 ↓</a></div>
        <a class="savi-software-text-link" href="https://github.com/savilionmusic/koala-link/blob/main/docs/PUSH2-CONTROLS.md">Read the Push 2 controls →</a> · <a class="savi-software-text-link" href="https://github.com/savilionmusic/koala-link/releases/tag/v1.4.5">What’s new in 1.4.5 →</a>
    </section>

    <section class="savi-software-follow" aria-labelledby="follow-sav-lab-title">
        <div><p class="savi-software-eyebrow">STUDIO NOTES / DEMOS / RELEASES</p><h2 id="follow-sav-lab-title">Follow SAV LAB</h2></div>
        <nav aria-label="SAV LAB social profiles">
            <a class="savi-software-social-link" href="https://www.instagram.com/savlabaudio/" target="_blank" rel="noopener noreferrer">Instagram <span>@savlabaudio</span> <span aria-hidden="true">↗</span></a>
            <span class="savi-software-social-coming">Facebook <span>Coming soon</span></span>
            <span class="savi-software-social-coming">YouTube <span>Coming soon</span></span>
        </nav>
    </section>

    <section class="savi-software-details" aria-labelledby="setup-title">
        <div><p class="savi-software-eyebrow">BEFORE YOUR FIRST SESSION</p><h2 id="setup-title">Install. Connect. Play.</h2></div>
        <div class="savi-software-detail-list">
            <details open><summary>What you need</summary><div><p>An Apple silicon Mac running macOS <span class="savi-software-number">13</span> or later, plus Koala Sampler for Mac.</p><p><strong>MPC Touch:</strong> DisplayLink Manager and Accessibility permission for Koala Link and mpc_touchd.</p><p><strong>Push 2:</strong> A USB connection. Close Ableton Live and Paper Cut while Koala Link uses the Push display.</p></div></details>
            <details><summary>Installation</summary><div><ol><li>Download the Koala Link installer and run the .pkg file.</li><li>Connect and power your controller, then open Koala Link in Applications.</li><li>Choose MPC Touch or the Push 2 preview. For MPC Touch, allow Accessibility when prompted.</li></ol><p>The app and installer are not notarized. If macOS blocks the download, use Open Anyway in System Settings → Privacy &amp; Security.</p></div></details>
            <details><summary>Help, release notes and source</summary><div><p><a href="https://github.com/savilionmusic/koala-link">Project and setup guide</a> · <a href="https://github.com/savilionmusic/koala-link/releases">Release notes</a> · <a href="https://github.com/savilionmusic/koala-link/issues">Report an issue</a></p><p>Koala Link is an independent companion app created by Savilion. Koala Sampler, Akai and Ableton are separate products and brands.</p></div></details>
        </div>
    </section>

    <section class="savi-software-next" aria-labelledby="paper-cut-title"><div><p class="savi-software-eyebrow">02 / BY SAV LAB / IN DEVELOPMENT</p><h2 id="paper-cut-title">Paper Cut</h2><p>Hands-on music software by SAV LAB. Join the software list for Paper Cut release news and future product launches.</p></div><a class="savi-software-button" href="#software-updates">Get Paper Cut updates ↑</a></section>
</main>
<?php get_footer(); ?>
