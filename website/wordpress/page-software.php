<?php
if (!defined('ABSPATH')) { exit; }
$downloads = savi_software_downloads();
$software_assets = content_url('/uploads/software/koala-link/');
$sav_lab_assets = content_url('/uploads/software/sav-lab/');
$signup_complete = isset($_GET['signup']) && $_GET['signup'] === 'complete';
$signup_updates = isset($_GET['updates']) && is_string($_GET['updates']) ? sanitize_key(wp_unslash($_GET['updates'])) : '';
$signup_joined = $signup_complete && $signup_updates === 'joined';
$signup_pending = $signup_complete && $signup_updates === 'pending';
$signup_sync_error = $signup_complete && $signup_updates === 'sync-error';
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
                    <a class="savi-software-button is-primary" href="#software-updates">Get the free download <span aria-hidden="true">↓</span></a>
                    <a class="savi-software-text-link" href="<?php echo esc_url($software_assets . 'Koala-Link-1.4.7-Manual.pdf'); ?>" download>Download the manual (PDF) <span aria-hidden="true">↓</span></a>
                    <a class="savi-software-text-link" href="https://github.com/savilionmusic/koala-link">View source on GitHub <span aria-hidden="true">↗</span></a>
                    <a class="savi-software-text-link" href="#push-preview">Explore Push 2 preview →</a>
                </div>
                <p class="savi-software-release"><span>v1.4.7 · build 19 · MPC Touch supported</span> · Apple silicon · macOS 13+</p>
                <p class="savi-software-small">One installer includes the app, touchscreen driver and automatic MIDI mappings for MPC Touch and Push 2. Requires Koala Sampler (sold separately) and DisplayLink Manager. Enter an email to unlock the installer; software-update emails are optional.</p>
            </div>
            <figure class="savi-software-app-figure">
                <div class="savi-software-display-label"><span>KOALA LINK / CONTROLLER SELECT</span><span>VERSION 1.4.7</span></div>
                <img src="<?php echo esc_url($software_assets . 'Koala-Link-Controller-Choice.png'); ?>" alt="Koala Link's controller picker with MPC Touch and Push 2 options." width="1440" height="760" fetchpriority="high">
                <figcaption>Choose MPC Touch or Push 2 at launch. Push 2 support is a preview included in the same installer.</figcaption>
            </figure>
        </div>
        <div class="savi-software-features">
            <div><span>PLAY</span><h3>Four banks. All your pads.</h3><p>Play Koala’s <span class="savi-software-number">64</span> sample pads across banks A–D. Toggle FULL LEVEL for consistent pad hits.</p></div>
            <div><span>CHOP</span><h3>Chops stay in order.</h3><p>Use 16 LEVELS for Chopper keyboard mode, with mapping that follows Koala’s slice behavior and smaller or odd chop counts.</p></div>
            <div><span>TOUCH</span><h3>Koala on the MPC screen.</h3><p>Hold, drag pads to the trash, and pinch to zoom in the sample editor and piano roll. Q-Links and transport controls are mapped.</p></div>
        </div>
        <section class="savi-software-whats-new" aria-labelledby="savi-software-whats-new-title">
            <div class="savi-software-whats-new-heading"><div><p class="savi-software-eyebrow">KOALA LINK / RELEASE 1.4.7</p><h2 id="savi-software-whats-new-title">Film it. Shape it. Perform it.</h2></div></div>
            <div class="savi-software-whats-new-grid">
                <article><p class="savi-software-eyebrow">WEBCAM</p><h3>Film your beats.</h3><p>Record yourself playing with Koala’s sound, the pad you hit and its waveform on screen. Choose 16:9 or 9:16; MP4 videos export at 1080×1920 in H.264 and AAC, ready to upload.</p></article>
                <article><p class="savi-software-eyebrow">STUTTER / CUTTER</p><h3>Video effects follow the music.</h3><p>STUTTER repeats the picture in time with the beat, from quarter notes to 32nds, with a smooth fade on each repeat. CUTTER chops the picture to black in time.</p></article>
                <article><p class="savi-software-eyebrow">RECORDING TOOLS</p><h3>Keep the take in view.</h3><p>A floating preview stays on top while you make the beat. ARM records on your first pad hit. An OBS output window, dB meter, drive, MPC3000-style clipper, limiter and LISTEN monitoring round out the recording tools.</p></article>
                <article><p class="savi-software-eyebrow">MPC TOUCH / Q-LINKS</p><h3>Stay hands-on.</h3><p>Hold an MPC Touch bank button to solo mixer track 1–4; tap to change banks, or use SHIFT plus a bank button to latch the solo. Q-Link bank D controls STUTTER, TALKBOX, FILTER and CUTTER; a quarter turn covers the range, and all the way down switches the effect off.</p></article>
            </div>
            <p class="savi-software-small">Webcam recording needs a camera and Camera plus Screen &amp; System Audio Recording permission.</p>
        </section>
    </section>

    <section class="savi-software-updates" id="software-updates" aria-labelledby="updates-title">
        <div class="savi-software-updates-copy">
            <p class="savi-software-eyebrow">SOFTWARE / RELEASE LIST</p>
            <h2 id="updates-title">Get the free download.</h2>
            <p>Enter your email to reveal the Koala Link installer. The installer is free; joining the software updates list is a separate choice.</p>
            <p class="savi-software-small">Marketing emails are optional. Unchecked means your email is not added to the updates list.</p>
        </div>
        <div class="savi-software-form-wrap">
            <form id="savi-software-signup" action="<?php echo esc_url(home_url('/software/')); ?>" method="post" <?php echo $signup_complete && !$signup_sync_error ? 'hidden' : ''; ?>>
                <input type="hidden" name="action" value="savi_software_signup">
                <?php wp_nonce_field('savi_software_signup', '_wpnonce', false); ?>
                <input type="hidden" name="ticket" value="<?php echo esc_attr(savi_software_ticket()); ?>">
                <div class="savi-software-field"><label for="savi-software-email">Email address <span>(required)</span></label><input id="savi-software-email" type="email" name="email" maxlength="254" required autocomplete="email" spellcheck="false" placeholder="you@example.com" aria-describedby="savi-software-privacy savi-software-form-status"></div>
                <div class="savi-software-field"><label for="savi-software-interest">Your controller</label><select id="savi-software-interest" name="interest"><option value="both">MPC Touch + Push 2 / Exploring</option><option value="mpc-touch">MPC Touch</option><option value="push-2">Push 2</option></select></div>
                <div class="savi-software-trap" aria-hidden="true"><label for="savi-company-website">Leave this field empty</label><input id="savi-company-website" type="text" name="company_website" tabindex="-1" autocomplete="off"></div>
                <label class="savi-software-consent" for="savi-software-consent"><input id="savi-software-consent" type="checkbox" name="consent" value="yes"><span><?php echo esc_html(SAVI_SOFTWARE_CONSENT); ?> <span class="savi-software-optional">(optional)</span></span></label>
                <button class="savi-software-button is-primary" type="submit">Unlock Koala Link <span aria-hidden="true">→</span></button>
                <p class="savi-software-form-status" id="savi-software-form-status" role="status" tabindex="-1"></p>
                <p class="savi-software-small" id="savi-software-privacy">Your email unlocks the installer. If you check the optional box, we send it to MailerLite for software updates. You can unsubscribe from future emails at any time. <a href="<?php echo esc_url(home_url('/privacy-policy/')); ?>">Privacy policy</a>. Need help? <a href="<?php echo esc_url(home_url('/contact/')); ?>">Contact Savilion</a>.</p>
            </form>
            <div id="savi-software-success" class="savi-software-success" role="status" tabindex="-1" <?php echo $signup_complete ? '' : 'hidden'; ?>>
                <p class="savi-software-eyebrow"><?php echo $signup_pending ? 'SAV LAB / CONFIRM SOFTWARE UPDATES' : ($signup_joined ? 'SAV LAB / UPDATES JOINED' : 'SAV LAB / DOWNLOAD READY'); ?></p>
                <h3><?php echo $signup_pending ? 'Check your inbox.' : ($signup_joined ? 'You’re on the updates list.' : 'Koala Link is ready.'); ?></h3>
                <p><?php
                    if ($signup_pending) { echo 'Your download is ready now. Follow MailerLite’s confirmation email to receive software updates.'; }
                    elseif ($signup_joined) { echo 'Your download is ready, and your email is on the software updates list.'; }
                    elseif ($signup_sync_error) { echo 'Your download is ready, but we could not complete the software updates signup. You can try again using the form.'; }
                    else { echo 'Your download is ready. Your address has not been added to the updates list.'; }
                ?></p>
                <a class="savi-software-button is-primary" href="<?php echo esc_url($downloads['stable']); ?>" download>Download Koala Link 1.4.7 ↓</a>
                <a class="savi-software-text-link" href="#push-preview">Explore the included Push 2 preview →</a>
                <p class="savi-software-small">Push 2 support is a preview. The latest build adds faster display feedback and sample deletion; complete control validation is ongoing.</p>
            </div>
        </div>
    </section>

    <section class="savi-software-push" id="push-preview" aria-labelledby="push-title">
        <div class="savi-software-section-heading"><p class="savi-software-eyebrow">SAV LAB / KOALA LINK / NEW CONTROLLER</p><span class="savi-software-tag">PREVIEW</span></div>
        <div class="savi-software-push-copy"><h2 id="push-title">A Koala view on Push 2.</h2><p>Play and select samples from the pads, trim with the encoders, and perform with effects and the touch strip. Custom sample, piano-roll, sequence, EQ and mixer views bring Koala to the Push display.</p></div>
        <figure class="savi-software-push-screen"><img src="<?php echo esc_url($software_assets . 'Koala-Link-1.4.5-Push-Sample.png'); ?>" alt="Rendered Push 2 sample screen with a waveform, sample start and end, pitch and volume controls, and a bank indicator." width="960" height="160" loading="lazy"><figcaption>Sample screen artwork rendered from version 1.4.5. New gestures and full control coverage are still being validated on hardware.</figcaption></figure>
        <div class="savi-software-push-bottom"><p>The Push 2 preview is included in the same <span class="savi-software-number">1.4.7</span> installer. It adds cached waveforms, immediate trim and sequence feedback, and pad selection for editing. To delete a sample, leave NOTE mode, hold one pad and press DELETE; confirm in Koala if prompted. Recording notes use a local timing preview that settles to Koala’s saved data. Mac edits and new audio still depend on Koala saving; create and edit chops in Koala.</p><a class="savi-software-button" href="#software-updates">Get the free download ↑</a></div>
        <a class="savi-software-text-link" href="https://github.com/savilionmusic/koala-link/blob/main/docs/PUSH2-CONTROLS.md">Read the Push 2 controls →</a> · <a class="savi-software-text-link" href="https://github.com/savilionmusic/koala-link/releases/tag/v1.4.7">What’s new in 1.4.7 →</a>
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
            <details open><summary>What you need</summary><div><p>An Apple silicon Mac running macOS <span class="savi-software-number">13</span> or later, plus Koala Sampler for Mac (sold separately).</p><p><strong>MPC Touch:</strong> DisplayLink Manager (separate) and Accessibility approval for Koala Link and mpc_touchd.</p><p><strong>Webcam:</strong> A camera and Camera plus Screen &amp; System Audio Recording permission.</p><p><strong>Push 2:</strong> A USB connection. Push 2 remains a preview; close Ableton Live and Paper Cut while Koala Link uses the Push display.</p></div></details>
            <details><summary>Installation</summary><div><ol><li>Download the Koala Link installer and run the .pkg file.</li><li>Connect and power your controller, then open Koala Link in Applications.</li><li>Choose MPC Touch or the Push 2 preview. Koala Link automatically prepares the matching MIDI map; you don’t need to learn each control. For MPC Touch, allow Accessibility when prompted.</li><li>On a new Koala installation, Koala Link opens Koala once to create its settings, then reopens it with the mapping ready. If Koala shows a first-time setup or permission dialog, finish it, quit Koala and choose your controller again.</li></ol><p>The app and installer are not notarized. If macOS blocks the download, use Open Anyway in System Settings → Privacy &amp; Security.</p></div></details>
            <details><summary>Help, release notes and source</summary><div><p><a href="https://github.com/savilionmusic/koala-link">Project and setup guide</a> · <a href="https://github.com/savilionmusic/koala-link/releases">Release notes</a> · <a href="https://github.com/savilionmusic/koala-link/issues">Report an issue</a></p><p>Koala Link is an independent companion app by Savilion. Koala Sampler, Akai, Ableton and DisplayLink are products and marks of their respective owners; no endorsement is implied.</p><p class="savi-software-small">Alicja Hand font credit: copyright 2026 Alicja Gajewski, included with the publisher’s redistribution permission.</p></div></details>
        </div>
    </section>

    <section class="savi-software-next" aria-labelledby="paper-cut-title"><div><p class="savi-software-eyebrow">02 / BY SAV LAB / IN DEVELOPMENT</p><h2 id="paper-cut-title">Paper Cut</h2><p>Hands-on music software by SAV LAB. Join the software list for Paper Cut release news and future product launches.</p></div><a class="savi-software-button" href="#software-updates">Get Paper Cut updates ↑</a></section>
</main>
<?php get_footer(); ?>
