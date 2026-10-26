<?php
/**
 * Plugin Name: Savilion Software
 * Description: Software page and consent-based software update signups.
 * Version: 1.0.5
 */
if (!defined('ABSPATH')) { exit; }

define('SAVI_SOFTWARE_CONSENT', 'Email me Koala Link updates and news about future Savilion software, including Paper Cut.');
define('SAVI_SOFTWARE_CONSENT_VERSION', '2026-10-11');

function savi_software_table() {
    global $wpdb;
    return $wpdb->prefix . 'savi_software_subscribers';
}

add_action('init', function () {
    if (get_option('savi_software_schema') === '1') { return; }
    global $wpdb;
    require_once ABSPATH . 'wp-admin/includes/upgrade.php';
    $table = savi_software_table();
    dbDelta("CREATE TABLE $table (
        id bigint(20) unsigned NOT NULL AUTO_INCREMENT,
        email varchar(254) NOT NULL,
        status varchar(20) NOT NULL DEFAULT 'subscribed',
        interest varchar(20) NOT NULL DEFAULT 'both',
        source varchar(100) NOT NULL DEFAULT 'software-page',
        consent_text text NOT NULL,
        consent_version varchar(20) NOT NULL,
        created_at datetime NOT NULL,
        consented_at datetime NOT NULL,
        unsubscribed_at datetime DEFAULT NULL,
        PRIMARY KEY  (id),
        UNIQUE KEY email (email),
        KEY status (status)
    ) " . $wpdb->get_charset_collate() . ';');
    if ($wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($table))) !== $table) { return; }
    $page = get_page_by_path('software');
    if (!$page) {
        $id = wp_insert_post(array(
            'post_title' => 'Software', 'post_name' => 'software',
            'post_type' => 'page', 'post_status' => 'publish',
            'post_content' => 'Free Koala Link downloads for MPC Touch and a Push 2 preview. Sign up for Savilion software updates, including Paper Cut.',
            'comment_status' => 'closed', 'ping_status' => 'closed',
        ), true);
        if (is_wp_error($id)) { return; }
        update_option('savi_software_page_id', $id, false);
    } else {
        update_option('savi_software_page_id', $page->ID, false);
    }
    update_option('savi_software_schema', '1', false);
}, 20);

add_filter('template_include', function ($template) {
    if (is_page('software')) {
        $path = get_template_directory() . '/page-software.php';
        if (file_exists($path)) { return $path; }
    }
    return $template;
});

add_filter('body_class', function ($classes) {
    if (is_page('software')) { $classes[] = 'savi-software-view'; }
    return $classes;
});

function savi_software_page_description() {
    return 'Hands-on tools for making music. Built in the studio by Savilion. Explore Koala Link, Paper Cut and more from SAV LAB.';
}

function savi_software_page_social_image() {
    return content_url('/uploads/software/sav-lab/SAV-LAB-Alicja-preview.png');
}

function savi_software_brand_head_markup($html) {
    if (!is_page('software')) { return $html; }
    $title = 'SAV LAB — Music software by Savilion';
    $description = savi_software_page_description();
    $image = savi_software_page_social_image();
    $tags = array(
        'description' => $description,
        'og:type' => 'website',
        'og:title' => $title,
        'og:description' => $description,
        'og:image' => $image,
        'og:url' => home_url('/software/'),
        'twitter:card' => 'summary_large_image',
        'twitter:title' => $title,
        'twitter:description' => $description,
        'twitter:image' => $image,
    );
    $html = preg_replace('/<title\\b[^>]*>.*?<\\/title>/is', '<title>' . esc_html($title) . '</title>', $html, 1);
    $seen = array();
    $html = preg_replace_callback('/<meta\\b[^>]*>/i', function ($match) use ($tags, &$seen) {
        $tag = $match[0];
        if (!preg_match("~\\b(?:name|property)\\s*=\\s*([\"'])(.*?)\\1~i", $tag, $key)) { return $tag; }
        $name = strtolower($key[2]);
        if (!array_key_exists($name, $tags)) { return $tag; }
        if (isset($seen[$name])) { return ''; }
        $seen[$name] = true;
        $value = esc_attr($tags[$name]);
        $replaced = preg_replace("~\\s+content\\s*=\\s*([\"']).*?\\1~i", ' content="' . $value . '"', $tag, 1, $count);
        return $count ? $replaced : substr($tag, 0, -1) . ' content="' . $value . '">';
    }, $html);
    $missing = '';
    foreach ($tags as $name => $value) {
        if (isset($seen[$name])) { continue; }
        $attribute = in_array($name, array('description', 'twitter:card', 'twitter:title', 'twitter:description', 'twitter:image'), true) ? 'name' : 'property';
        $missing .= '<meta ' . $attribute . '="' . esc_attr($name) . '" content="' . esc_attr($value) . '">' . "\n";
    }
    if ($missing !== '' && stripos($html, '</head>') !== false) {
        $html = preg_replace('/<\\/head>/i', $missing . '</head>', $html, 1);
    }
    return $html;
}

add_filter('the_content', function ($content) {
    if (!is_page('privacy-policy') || !is_main_query() || !in_the_loop()) { return $content; }
    return $content . '<section id="software-updates-privacy"><h2>Software download access and updates</h2><p>When you request Koala Link installer access, your email address is processed to provide that access. It is added to the SAV LAB Software updates list only if you select the separate, optional consent checkbox. For opted-in subscribers, we store the email address, controller preference, signup source, consent wording and consent date in our WordPress database. We also send the email address to MailerLite to manage this software updates subscription and deliver updates about Koala Link and future Savilion software, including Paper Cut and product launches. See <a href="https://www.mailerlite.com/legal/privacy-policy" target="_blank" rel="noopener noreferrer">MailerLite’s privacy policy</a>.</p><p>Update emails include an unsubscribe option. You can also <a href="' . esc_url(home_url('/contact/')) . '">contact Savilion</a>. MailerLite manages email delivery preferences; WordPress keeps the original consent record. Download access does not require marketing consent.</p></section>';
});

add_action('template_redirect', function () {
    if (!is_page('software')) { return; }
    if (!defined('DONOTCACHEPAGE')) { define('DONOTCACHEPAGE', true); }
    do_action('litespeed_control_set_nocache', 'Software signup tokens');
    nocache_headers();
    header('Referrer-Policy: strict-origin-when-cross-origin');
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action']) && is_string($_POST['action']) && $_POST['action'] === 'savi_software_signup') {
        savi_software_signup();
    }
});

add_action('wp_enqueue_scripts', function () {
    wp_add_inline_style('savilion-mpc-live', '.savi-function-nav{width:min(100%,530px);grid-template-columns:repeat(5,minmax(68px,1fr))}@media(max-width:640px){.savi-function-nav{grid-template-columns:repeat(2,minmax(0,1fr))}}');
    if (!is_page('software')) { return; }
    $dir = get_template_directory();
    $uri = get_template_directory_uri();
    wp_enqueue_style('savi-software', $uri . '/software.css', array('savilion-mpc-live'), filemtime($dir . '/software.css'));
    wp_enqueue_script('savi-software', $uri . '/software.js', array(), filemtime($dir . '/software.js'), true);
}, 30);

function savi_software_downloads() {
    $base = content_url('/uploads/software/koala-link/');
    $installer = $base . 'Koala-Link-1.4.7-Installer.pkg';
    return array('stable' => $installer, 'preview' => $installer);
}

if (!defined('SAVI_MAILERLITE_GROUP_ID')) {
    define('SAVI_MAILERLITE_GROUP_ID', '202034791356302567');
}

function savi_software_mailerlite_sync($email) {
    if (!defined('SAVI_MAILERLITE_API_KEY') || !is_string(SAVI_MAILERLITE_API_KEY) || trim(SAVI_MAILERLITE_API_KEY) === '') {
        return array('ok' => false, 'status' => 'sync-error');
    }

    $response = wp_remote_post('https://connect.mailerlite.com/api/subscribers', array(
        'headers' => array(
            'Authorization' => 'Bearer ' . trim(SAVI_MAILERLITE_API_KEY),
            'Accept' => 'application/json',
            'Content-Type' => 'application/json',
            'X-Version' => '2026-10-22',
        ),
        'body' => wp_json_encode(array(
            'email' => $email,
            'groups' => array(SAVI_MAILERLITE_GROUP_ID),
        )),
        'timeout' => 8,
        'redirection' => 0,
    ));

    if (is_wp_error($response)) {
        error_log('SAVI software MailerLite sync failed (network error).');
        return array('ok' => false, 'status' => 'sync-error');
    }

    $code = (int) wp_remote_retrieve_response_code($response);
    $payload = json_decode(wp_remote_retrieve_body($response), true);
    if (!in_array($code, array(200, 201, 202), true)) {
        error_log('SAVI software MailerLite sync failed (HTTP ' . $code . ').');
        return array('ok' => false, 'status' => 'sync-error');
    }

    $provider_status = isset($payload['data']['status']) && is_string($payload['data']['status'])
        ? sanitize_key($payload['data']['status'])
        : '';
    if (in_array($provider_status, array('unsubscribed', 'bounced', 'junk'), true)) {
        return array('ok' => true, 'status' => 'not-added');
    }
    if ($provider_status === 'unconfirmed' || ($provider_status === '' && $code === 202)) {
        return array('ok' => true, 'status' => 'pending');
    }
    if ($provider_status === 'active') {
        return array('ok' => true, 'status' => 'joined');
    }

    error_log('SAVI software MailerLite sync returned an unexpected subscriber status.');
    return array('ok' => false, 'status' => 'sync-error');
}

// Keep legacy WordPress unsubscribe links effective after moving delivery to MailerLite.
function savi_software_mailerlite_unsubscribe($id) {
    global $wpdb;
    $table = savi_software_table();
    $row = $wpdb->get_row($wpdb->prepare("SELECT email, status FROM $table WHERE id = %d", $id));
    if (!$row || $row->status !== 'unsubscribed') { return true; }
    $ok = false;
    if (defined('SAVI_MAILERLITE_API_KEY') && is_string(SAVI_MAILERLITE_API_KEY) && trim(SAVI_MAILERLITE_API_KEY) !== '') {
        $response = wp_remote_post('https://connect.mailerlite.com/api/subscribers', array(
            'headers' => array('Authorization' => 'Bearer ' . trim(SAVI_MAILERLITE_API_KEY), 'Accept' => 'application/json', 'Content-Type' => 'application/json'),
            'body' => wp_json_encode(array('email' => $row->email, 'status' => 'unsubscribed', 'resubscribe' => false)),
            'timeout' => 8, 'redirection' => 0,
        ));
        if (!is_wp_error($response) && in_array((int) wp_remote_retrieve_response_code($response), array(200, 201), true)) {
            $payload = json_decode(wp_remote_retrieve_body($response), true);
            $ok = isset($payload['data']['status']) && $payload['data']['status'] === 'unsubscribed';
        }
    }
    if (!$ok && !wp_next_scheduled('savi_software_mailerlite_unsubscribe_retry', array((int) $id))) {
        wp_schedule_single_event(time() + 5 * MINUTE_IN_SECONDS, 'savi_software_mailerlite_unsubscribe_retry', array((int) $id));
        error_log('SAVI software MailerLite unsubscribe queued for retry.');
    }
    return $ok;
}
add_action('savi_software_mailerlite_unsubscribe_retry', 'savi_software_mailerlite_unsubscribe');

function savi_software_ticket() {
    $time = (string) time();
    return $time . '.' . hash_hmac('sha256', $time . '|software-signup', wp_salt('nonce'));
}

function savi_software_ticket_valid($ticket) {
    $parts = explode('.', $ticket, 2);
    if (count($parts) !== 2 || !ctype_digit($parts[0])) { return false; }
    $age = time() - (int) $parts[0];
    return $age >= 0 && $age <= DAY_IN_SECONDS && hash_equals(hash_hmac('sha256', $parts[0] . '|software-signup', wp_salt('nonce')), $parts[1]);
}

function savi_software_response($ok, $message, $code = 200, $updates_status = null) {
    nocache_headers();
    if (!in_array($updates_status, array('joined', 'pending', 'not-added', 'sync-error'), true)) {
        $updates_status = !empty($_POST['consent']) && $_POST['consent'] === 'yes' ? 'pending' : 'not-added';
    }
    $subscribed = in_array($updates_status, array('joined', 'pending'), true);
    if (!empty($_POST['ajax'])) {
        if ($ok) { wp_send_json_success(array('message' => $message, 'downloads' => savi_software_downloads(), 'subscribed' => $subscribed, 'updates' => $updates_status), $code); }
        wp_send_json_error(array('message' => $message), $code);
    }
    if (savi_software_is_statis_request()) {
        if ($ok) {
            wp_redirect('https://statisxsavilion.com/software/?download=ready&updates=' . $updates_status . '#software-access', 303);
        } else {
            wp_redirect('https://statisxsavilion.com/software/?signup=error#software-access', 303);
        }
        exit;
    }
    if (!$ok) { wp_die(esc_html($message) . '<p><a href="' . esc_url(home_url('/software/#software-updates')) . '">Return to software downloads</a></p>', 'Software updates', array('response' => $code)); }
    wp_safe_redirect(home_url('/software/?signup=complete&updates=' . $updates_status . '#software-updates'), 303);
    exit;
}

function savi_software_is_statis_request() {
    $origin = isset($_SERVER['HTTP_ORIGIN']) && is_string($_SERVER['HTTP_ORIGIN']) ? strtolower(untrailingslashit($_SERVER['HTTP_ORIGIN'])) : '';
    $source = isset($_POST['source']) && is_string($_POST['source']) ? sanitize_key(wp_unslash($_POST['source'])) : '';
    return in_array($origin, array('https://statisxsavilion.com', 'https://www.statisxsavilion.com'), true)
        && $source === 'statisxsavilion-software';
}

add_action('admin_post_savi_software_signup', 'savi_software_signup');
add_action('admin_post_nopriv_savi_software_signup', 'savi_software_signup');
function savi_software_signup() {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') { savi_software_response(false, 'Please use the signup form.', 405); }
    $origin = isset($_SERVER['HTTP_ORIGIN']) && is_string($_SERVER['HTTP_ORIGIN']) ? strtolower(untrailingslashit($_SERVER['HTTP_ORIGIN'])) : '';
    $statis_request = savi_software_is_statis_request();
    $site_origin = strtolower(untrailingslashit(home_url()));
    if (($origin && $origin !== $site_origin && !$statis_request) || (isset($_SERVER['HTTP_SEC_FETCH_SITE']) && $_SERVER['HTTP_SEC_FETCH_SITE'] === 'cross-site' && !$statis_request)) {
        savi_software_response(false, 'Please sign up from the Software page.', 403);
    }
    if (!$statis_request) {
        $nonce = isset($_POST['_wpnonce']) && is_string($_POST['_wpnonce']) ? sanitize_text_field(wp_unslash($_POST['_wpnonce'])) : '';
        $ticket = isset($_POST['ticket']) && is_string($_POST['ticket']) ? sanitize_text_field(wp_unslash($_POST['ticket'])) : '';
        if (!wp_verify_nonce($nonce, 'savi_software_signup') || !savi_software_ticket_valid($ticket)) {
            savi_software_response(false, 'This form has expired. Refresh the page and try again.', 403);
        }
    }
    if (!empty($_POST['company_website'])) { savi_software_response(false, 'We could not process that request. Please use the form again.', 400); }
    $email = isset($_POST['email']) && is_string($_POST['email']) ? strtolower(trim(wp_unslash($_POST['email']))) : '';
    if (strlen($email) > 254 || !is_email($email)) { savi_software_response(false, 'Enter a valid email address, such as you@example.com.', 400); }
    // A salted, short-lived IP hash limits abuse without retaining visitors' IP addresses.
    $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    $rate_key = 'savi_software_rate_' . substr(hash_hmac('sha256', $ip, wp_salt('auth')), 0, 32);
    $rate = get_transient($rate_key);
    if (!is_array($rate) || $rate['until'] <= time()) { $rate = array('count' => 0, 'until' => time() + HOUR_IN_SECONDS); }
    if ($rate['count'] >= 10) { savi_software_response(false, 'Too many signup attempts. Please try again later. The free download is still available below.', 429); }
    $rate['count']++;
    set_transient($rate_key, $rate, max(1, $rate['until'] - time()));
    $consent = !empty($_POST['consent']) && $_POST['consent'] === 'yes';
    if (!$consent) {
        savi_software_response(true, 'Your Koala Link download is ready.', 200, 'not-added');
    }
    $interest = isset($_POST['interest']) && is_string($_POST['interest']) ? sanitize_key($_POST['interest']) : 'both';
    if (!in_array($interest, array('mpc-touch', 'push-2', 'both'), true)) { $interest = 'both'; }
    global $wpdb;
    $table = savi_software_table();
    $now = current_time('mysql', true);
    $previous = $wpdb->get_row($wpdb->prepare("SELECT id, status FROM $table WHERE email = %s", $email));
    if ($previous && $previous->status === 'unsubscribed') {
        // Re-subscription must come through email verification by the owner/provider.
        savi_software_response(true, 'Your download is ready. This address remains unsubscribed and was not re-added.', 200, 'not-added');
    }
    if ($previous) {
        if ($wpdb->update($table, array('interest' => $interest), array('id' => (int) $previous->id), array('%s'), array('%d')) === false) {
            savi_software_response(false, 'We could not save your controller preference. Please try again.', 503);
        }
    } else {
        $saved = $wpdb->insert($table, array(
            'email' => $email, 'status' => 'subscribed', 'interest' => $interest,
            'source' => $statis_request ? 'statisxsavilion-software' : 'savilion-software', 'consent_text' => SAVI_SOFTWARE_CONSENT,
            'consent_version' => SAVI_SOFTWARE_CONSENT_VERSION,
            'created_at' => $now, 'consented_at' => $now,
        ), array('%s','%s','%s','%s','%s','%s','%s','%s'));
        // A concurrent insert may already have saved the same address.
        if ($saved === false && !$wpdb->get_var($wpdb->prepare("SELECT id FROM $table WHERE email = %s AND status = 'subscribed'", $email))) {
            savi_software_response(false, 'We could not save your signup. Your email has not been added. Please try again.', 503);
        }
    }
    $mailerlite = savi_software_mailerlite_sync($email);
    if (!$mailerlite['ok']) {
        savi_software_response(true, 'Your Koala Link download is ready, but we could not complete the software updates signup. Please try again later.', 200, 'sync-error');
    }
    if ($mailerlite['status'] === 'pending') {
        savi_software_response(true, 'Your download is ready. Check your inbox to confirm software updates.', 200, 'pending');
    }
    if ($mailerlite['status'] === 'not-added') {
        savi_software_response(true, 'Your download is ready. Your address has not been added to the updates list.', 200, 'not-added');
    }
    savi_software_response(true, 'Your Koala Link download is ready. You’re on the software updates list.', 200, 'joined');
}

function savi_software_unsubscribe_url($id) {
    $token = hash_hmac('sha256', (string) $id . '|software-unsubscribe', wp_salt('auth'));
    return add_query_arg(array('action' => 'savi_software_unsubscribe', 'id' => (int) $id, 'token' => $token), admin_url('admin-post.php'));
}
add_action('admin_post_savi_software_unsubscribe', 'savi_software_unsubscribe');
add_action('admin_post_nopriv_savi_software_unsubscribe', 'savi_software_unsubscribe');
function savi_software_unsubscribe() {
    nocache_headers();
    header('Referrer-Policy: no-referrer');
    header('X-Robots-Tag: noindex, nofollow');
    $id = isset($_REQUEST['id']) ? absint($_REQUEST['id']) : 0;
    $token = isset($_REQUEST['token']) && is_string($_REQUEST['token']) ? sanitize_text_field(wp_unslash($_REQUEST['token'])) : '';
    if (!$id || !hash_equals(hash_hmac('sha256', (string) $id . '|software-unsubscribe', wp_salt('auth')), $token)) {
        wp_die('This unsubscribe link is invalid. Please contact Savilion.', 'Software updates', array('response' => 400));
    }
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
        $url = savi_software_unsubscribe_url($id);
        wp_die('<p>Stop receiving Savilion software updates?</p><form method="post" action="' . esc_url($url) . '"><button type="submit">Unsubscribe</button></form>', 'Software updates', array('response' => 200));
    }
    global $wpdb;
    $result = $wpdb->update(savi_software_table(), array('status' => 'unsubscribed', 'unsubscribed_at' => current_time('mysql', true)), array('id' => $id), array('%s','%s'), array('%d'));
    if ($result === false) { wp_die('We could not save this change. Please try again.', 'Software updates', array('response' => 503)); }
    $provider_saved = savi_software_mailerlite_unsubscribe($id);
    $message = $provider_saved ? 'You have been unsubscribed from Savilion software updates.' : 'Your unsubscribe request has been saved and is being processed. You can also use the unsubscribe link in any software update email.';
    wp_die('<p>' . esc_html($message) . '</p><p><a href="' . esc_url(home_url('/software/')) . '">Back to software</a></p>', 'Unsubscribed', array('response' => 200));
}

add_action('admin_menu', function () {
    add_menu_page('Software signups', 'Software signups', 'manage_options', 'savi-software-signups', 'savi_software_admin', 'dashicons-email-alt', 58);
});
function savi_software_mailerlite_connection() {
    if (!defined('SAVI_MAILERLITE_API_KEY') || !is_string(SAVI_MAILERLITE_API_KEY) || trim(SAVI_MAILERLITE_API_KEY) === '') { return false; }
    $cache_key = 'savi_ml_connection_' . substr(hash('sha256', SAVI_MAILERLITE_API_KEY), 0, 12);
    $cached = get_transient($cache_key);
    if ($cached !== false) { return $cached === 'connected'; }
    $response = wp_remote_get('https://connect.mailerlite.com/api/groups/' . rawurlencode(SAVI_MAILERLITE_GROUP_ID), array(
        'headers' => array('Authorization' => 'Bearer ' . trim(SAVI_MAILERLITE_API_KEY), 'Accept' => 'application/json'),
        'timeout' => 8, 'redirection' => 0,
    ));
    $payload = !is_wp_error($response) ? json_decode(wp_remote_retrieve_body($response), true) : array();
    $connected = !is_wp_error($response) && (int) wp_remote_retrieve_response_code($response) === 200
        && isset($payload['data']['id']) && (string) $payload['data']['id'] === SAVI_MAILERLITE_GROUP_ID;
    set_transient($cache_key, $connected ? 'connected' : 'unavailable', 5 * MINUTE_IN_SECONDS);
    return $connected;
}
function savi_software_admin() {
    if (!current_user_can('manage_options')) { return; }
    $connection = savi_software_mailerlite_connection() ? 'Connected to SAV LAB Software' : 'Connection unavailable — check the server key or retry shortly';
    echo '<div class="notice notice-info"><p><strong>MailerLite:</strong> ' . esc_html($connection) . '</p></div>';
    global $wpdb;
    $table = savi_software_table();
    $page = isset($_GET['paged']) ? max(1, absint($_GET['paged'])) : 1;
    $count = (int) $wpdb->get_var("SELECT COUNT(*) FROM $table WHERE status = 'subscribed'");
    $total = (int) $wpdb->get_var("SELECT COUNT(*) FROM $table");
    $rows = $wpdb->get_results($wpdb->prepare("SELECT id, email, status, interest, consented_at FROM $table ORDER BY id DESC LIMIT %d OFFSET %d", 50, ($page - 1) * 50));
    $export = wp_nonce_url(admin_url('admin-post.php?action=savi_software_export'), 'savi_software_export');
    echo '<div class="wrap"><h1>Software signups</h1><p><strong>' . esc_html(number_format_i18n($count)) . '</strong> consent records · Koala Link and future Savilion products, including Paper Cut.</p><p><a class="button button-primary" href="' . esc_url($export) . '">Export consent records (CSV)</a> <a class="button" href="' . esc_url(home_url('/software/')) . '">View software page</a></p><p>Only explicitly opted-in addresses are stored here and synced to the MailerLite SAV LAB Software group. MailerLite sends confirmation emails and manages campaign delivery and unsubscribe preferences. Use MailerLite—not this consent-record export—to send updates. The export is retained for consent record keeping.</p><table class="widefat striped"><thead><tr><th>Email</th><th>Interest</th><th>Status</th><th>Consent date (UTC)</th></tr></thead><tbody>';
    if (!$rows) { echo '<tr><td colspan="4">No signups yet. New software signups will appear here.</td></tr>'; }
    foreach ($rows as $row) {
        echo '<tr><td>' . esc_html($row->email) . '</td><td>' . esc_html($row->interest) . '</td><td>' . esc_html($row->status) . '</td><td style="font-family:monospace;font-variant-numeric:tabular-nums">' . esc_html($row->consented_at) . '</td></tr>';
    }
    echo '</tbody></table><p>';
    if ($page > 1) { echo '<a class="button" href="' . esc_url(add_query_arg('paged', $page - 1)) . '">Previous</a> '; }
    if ($page * 50 < $total) { echo '<a class="button" href="' . esc_url(add_query_arg('paged', $page + 1)) . '">Next</a>'; }
    echo '</p></div>';
}
add_action('admin_post_savi_software_export', function () {
    if (!current_user_can('manage_options')) { wp_die('Not permitted.', '', array('response' => 403)); }
    check_admin_referer('savi_software_export');
    global $wpdb;
    $table = savi_software_table();
    nocache_headers();
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="savilion-software-subscribers-' . gmdate('Y-m-d') . '.csv"');
    $out = fopen('php://output', 'w');
    fputcsv($out, array('email','interest','source','consented_at_utc','consent_version','consent_text','unsubscribe_url'));
    $after = 0;
    do {
        $rows = $wpdb->get_results($wpdb->prepare("SELECT * FROM $table WHERE status = 'subscribed' AND id > %d ORDER BY id LIMIT 500", $after));
        foreach ($rows as $row) {
            $cells = array($row->email,$row->interest,$row->source,$row->consented_at,$row->consent_version,$row->consent_text,savi_software_unsubscribe_url($row->id));
            // Neutralize spreadsheet formulas in exported user input.
            $cells = array_map(function ($value) { return preg_match('/^[=+@\-\t\r]/', $value) ? "'" . $value : $value; }, $cells);
            fputcsv($out, $cells);
            $after = (int) $row->id;
        }
    } while (count($rows) === 500);
    fclose($out);
    exit;
});
