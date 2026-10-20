<?php
/**
 * Plugin Name: Savilion Software
 * Description: Software page and consent-based software update signups.
 * Version: 1.0.4
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
    return $content . '<section id="software-updates-privacy"><h2>Software update signups</h2><p>Added October 11, 2026. If you choose to join the software updates list, Savilion Beats stores your email address, controller preference, signup source, consent wording and consent date in our WordPress database. We use this information for Koala Link updates and news about future Savilion software, including Paper Cut and product launches.</p><p>Signup is optional and is not required to download Koala Link. You can unsubscribe using the link included in future software emails, or <a href="' . esc_url(home_url('/contact/')) . '">contact Savilion</a>. We retain an unsubscribe status to respect your email preference.</p></section>';
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
    $installer = $base . 'Koala-Link-1.4.6-Installer.pkg';
    return array('stable' => $installer, 'preview' => $installer);
}

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

function savi_software_response($ok, $message, $code = 200) {
    nocache_headers();
    if (!empty($_POST['ajax'])) {
        if ($ok) { wp_send_json_success(array('message' => $message, 'downloads' => savi_software_downloads()), $code); }
        wp_send_json_error(array('message' => $message), $code);
    }
    if (!$ok) { wp_die(esc_html($message) . '<p><a href="' . esc_url(home_url('/software/#software-updates')) . '">Return to software downloads</a></p>', 'Software updates', array('response' => $code)); }
    wp_safe_redirect(home_url('/software/?signup=complete#software-updates'), 303);
    exit;
}

add_action('admin_post_savi_software_signup', 'savi_software_signup');
add_action('admin_post_nopriv_savi_software_signup', 'savi_software_signup');
function savi_software_signup() {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') { savi_software_response(false, 'Please use the signup form.', 405); }
    $origin = isset($_SERVER['HTTP_ORIGIN']) ? wp_parse_url($_SERVER['HTTP_ORIGIN'], PHP_URL_HOST) : '';
    if (($origin && $origin !== wp_parse_url(home_url(), PHP_URL_HOST)) || (isset($_SERVER['HTTP_SEC_FETCH_SITE']) && $_SERVER['HTTP_SEC_FETCH_SITE'] === 'cross-site')) {
        savi_software_response(false, 'Please sign up from the Software page.', 403);
    }
    $nonce = isset($_POST['_wpnonce']) && is_string($_POST['_wpnonce']) ? sanitize_text_field(wp_unslash($_POST['_wpnonce'])) : '';
    $ticket = isset($_POST['ticket']) && is_string($_POST['ticket']) ? sanitize_text_field(wp_unslash($_POST['ticket'])) : '';
    if (!wp_verify_nonce($nonce, 'savi_software_signup') || !savi_software_ticket_valid($ticket)) {
        savi_software_response(false, 'This form has expired. Refresh the page and try again.', 403);
    }
    if (!empty($_POST['company_website'])) { savi_software_response(false, 'We could not save that signup. Please use the form again.', 400); }
    if (empty($_POST['consent']) || $_POST['consent'] !== 'yes') { savi_software_response(false, 'Please check the email updates box to join. You can download Koala Link without signing up.', 400); }
    $email = isset($_POST['email']) && is_string($_POST['email']) ? strtolower(trim(wp_unslash($_POST['email']))) : '';
    if (strlen($email) > 254 || !is_email($email)) { savi_software_response(false, 'Enter a valid email address, such as you@example.com.', 400); }
    $interest = isset($_POST['interest']) && is_string($_POST['interest']) ? sanitize_key($_POST['interest']) : 'both';
    if (!in_array($interest, array('mpc-touch', 'push-2', 'both'), true)) { $interest = 'both'; }
    // A salted, short-lived IP hash limits abuse without retaining visitors' IP addresses.
    $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    $rate_key = 'savi_software_rate_' . substr(hash_hmac('sha256', $ip, wp_salt('auth')), 0, 32);
    $rate = get_transient($rate_key);
    if (!is_array($rate) || $rate['until'] <= time()) { $rate = array('count' => 0, 'until' => time() + HOUR_IN_SECONDS); }
    if ($rate['count'] >= 10) { savi_software_response(false, 'Too many signup attempts. Please try again later. The free download is still available below.', 429); }
    $rate['count']++;
    set_transient($rate_key, $rate, max(1, $rate['until'] - time()));
    global $wpdb;
    $table = savi_software_table();
    $now = current_time('mysql', true);
    $previous = $wpdb->get_row($wpdb->prepare("SELECT id, status FROM $table WHERE email = %s", $email));
    if ($previous && $previous->status === 'unsubscribed') {
        // Re-subscription must come through email verification by the owner/provider.
        savi_software_response(false, 'This address was previously unsubscribed. Contact Savilion to rejoin; the download is available without signing up.', 409);
    }
    if ($previous) {
        if ($wpdb->update($table, array('interest' => $interest), array('id' => (int) $previous->id), array('%s'), array('%d')) === false) {
            savi_software_response(false, 'We could not save your controller preference. Please try again.', 503);
        }
    } else {
        $saved = $wpdb->insert($table, array(
            'email' => $email, 'status' => 'subscribed', 'interest' => $interest,
            'source' => 'software-page', 'consent_text' => SAVI_SOFTWARE_CONSENT,
            'consent_version' => SAVI_SOFTWARE_CONSENT_VERSION,
            'created_at' => $now, 'consented_at' => $now,
        ), array('%s','%s','%s','%s','%s','%s','%s','%s'));
        // A concurrent insert may already have saved the same address.
        if ($saved === false && !$wpdb->get_var($wpdb->prepare("SELECT id FROM $table WHERE email = %s AND status = 'subscribed'", $email))) {
            savi_software_response(false, 'We could not save your signup. Your email has not been added. Please try again.', 503);
        }
    }
    savi_software_response(true, 'You’re on the software updates list. Koala Link is ready to download below.');
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
    wp_die('<p>You have been unsubscribed from Savilion software updates.</p><p><a href="' . esc_url(home_url('/software/')) . '">Back to software</a></p>', 'Unsubscribed', array('response' => 200));
}

add_action('admin_menu', function () {
    add_menu_page('Software signups', 'Software signups', 'manage_options', 'savi-software-signups', 'savi_software_admin', 'dashicons-email-alt', 58);
});
function savi_software_admin() {
    if (!current_user_can('manage_options')) { return; }
    global $wpdb;
    $table = savi_software_table();
    $page = isset($_GET['paged']) ? max(1, absint($_GET['paged'])) : 1;
    $count = (int) $wpdb->get_var("SELECT COUNT(*) FROM $table WHERE status = 'subscribed'");
    $total = (int) $wpdb->get_var("SELECT COUNT(*) FROM $table");
    $rows = $wpdb->get_results($wpdb->prepare("SELECT id, email, status, interest, consented_at FROM $table ORDER BY id DESC LIMIT %d OFFSET %d", 50, ($page - 1) * 50));
    $export = wp_nonce_url(admin_url('admin-post.php?action=savi_software_export'), 'savi_software_export');
    echo '<div class="wrap"><h1>Software signups</h1><p><strong>' . esc_html(number_format_i18n($count)) . '</strong> subscribed · Koala Link and future Savilion products, including Paper Cut.</p><p><a class="button button-primary" href="' . esc_url($export) . '">Export subscribed emails (CSV)</a> <a class="button" href="' . esc_url(home_url('/software/')) . '">View software page</a></p><p>Only explicitly opted-in addresses are stored here. No emails are sent automatically. The export includes the consent record and each subscriber’s unsubscribe URL. Include that link when sending future updates and exclude unsubscribed addresses.</p><table class="widefat striped"><thead><tr><th>Email</th><th>Interest</th><th>Status</th><th>Consent date (UTC)</th></tr></thead><tbody>';
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
