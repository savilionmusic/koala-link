// ============================================================
// mpc_touchd v3 — MPC Touch touchscreen driver for macOS (2026-09-28)
//
// The MPC Touch screen is a SiS 10-finger HID digitizer (09e8:8001) that only
// appears on USB after a SysEx "wake" to the controller (09e8:0037). macOS has
// no touchscreen support, so this helper wakes the panel, reads its touch
// reports and turns the primary finger into mouse down / drag / up on the
// MPC's display. In Koala, two fingers produce scroll events for editor zoom.
//
// Two ways in, chosen per attach:
//  * HID path — if macOS's own HID driver owns the panel, read it through
//    IOHIDManager (the kernel keeps the USB side healthy).
//  * Raw-USB path — Akai's AkaiTouchPanel.kext (a codeless "blocker" in
//    /Library/Extensions) claims the panel with a placeholder so no HID driver
//    binds and the device stays unconfigured. Then this helper sets the
//    configuration once if needed, opens interface 0 without seizing, and keeps
//    four asynchronous interrupt reads queued so the panel is always drained.
//
// Differences from v1 (baseline) and v2:
//  * One CFRunLoop drives everything: reads, CoreMIDI, display changes, timers.
//    No blocking reads; v1 posted events between single blocking reads.
//  * On read errors the reader closes and retries 2 s later; no CLEAR_HALT
//    storms (v1: every 20 ms for 12 s) and no configuration reset per session.
//  * Fixes v2's wake bug: CoreMIDI's property-name constants are NULL until the
//    first MIDI client exists, and v2's -O2 build loaded them before that, so it
//    never found the Public port. The client is created first, and keys are read
//    through midiKey() so the compiler can't hoist the load.
//  * Wake uses v1's proven bytes (7F address) on the MPC's Public port only,
//    widening to the MIDI Port only if Public alone doesn't wake the panel,
//    and backs off instead of repeating forever.
//  * Drags are coalesced to --rate per second (default 60, the screen's refresh).
//    A small movement threshold protects holds from sensor jitter; the first
//    intentional move and the final drop position are posted immediately.
//    Press and release are never delayed. Double taps carry click count 2.
//  * Follows the finger by contact ID and tip-switch bit, not "flags == 03".
//  * Maps only onto the MPC's own display; touches are dropped (never sent to
//    another screen) while it's missing. Remaps on display changes.
//  * --no-post reads and logs touches without moving the pointer, to test
//    whether drop-outs come from reading the panel or from pointer/screen traffic.
//
// Build: ./build.sh     Install: ./install.sh     (see README.md)
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <math.h>
#include <signal.h>
#include <sys/time.h>
#include <pthread.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <CoreMIDI/CoreMIDI.h>
#import <AppKit/AppKit.h>

#define AKAI_VID        0x09E8
#define CONTROLLER_PID  0x0037
#define SIS_PID         0x8001
#define MPC_DISP_VENDOR 0x5109      // EDID of the MPC Touch Screen (DisplayLink 17e9:ff00)
#define MPC_DISP_MODEL  0x1211
#define RAW_READS       4           // interrupt reads kept queued on the raw path

// ---------- options ----------
static struct { bool noPost, verbose, seize; double rate, pinchGain; } opt = { false, false, false, 60.0, 560.0 };

// ---------- logging ----------
static void logf_(const char *fmt, ...){
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
    char ts[32]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    printf("%s.%03d ", ts, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n");
}
static double now_s(void){ return CFAbsoluteTimeGetCurrent(); }

// ---------- USB registry lookups (read-only) ----------
static CFMutableDictionaryRef akaiMatch(const char *cls, int pid){
    CFMutableDictionaryRef m = IOServiceMatching(cls);
    int v = AKAI_VID, p = pid;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFNumberRef pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), vn);
    CFDictionarySetValue(m, CFSTR("idProduct"), pn);
    CFRelease(vn); CFRelease(pn);
    return m;
}
static bool usbPresent(int pid){
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, akaiMatch("IOUSBHostDevice", pid));
    if (s) IOObjectRelease(s);
    return s != 0;
}
static io_service_t sisInterface0(void){   // caller releases
    // USB interface matching needs vendor + product + configuration + interface together.
    CFMutableDictionaryRef m = akaiMatch("IOUSBHostInterface", SIS_PID);
    int cfg = 1, n = 0;
    CFNumberRef cn = CFNumberCreate(NULL, kCFNumberIntType, &cfg), nn = CFNumberCreate(NULL, kCFNumberIntType, &n);
    CFDictionarySetValue(m, CFSTR("bConfigurationValue"), cn);
    CFDictionarySetValue(m, CFSTR("bInterfaceNumber"), nn);
    CFRelease(cn); CFRelease(nn);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

// ---------- the MPC's display ----------
static CGDirectDisplayID gDisp = 0;
static CGRect gBounds;
static bool gHaveDisp = false;

static void refreshDisplay(const char *why){
    CGDirectDisplayID ids[16]; uint32_t n = 0, i;
    CGGetActiveDisplayList(16, ids, &n);
    CGDirectDisplayID pick = 0;
    for (i = 0; i < n && !pick; i++)
        if (CGDisplayVendorNumber(ids[i]) == MPC_DISP_VENDOR && CGDisplayModelNumber(ids[i]) == MPC_DISP_MODEL) pick = ids[i];
    for (i = 0; i < n && !pick; i++){
        CGRect b = CGDisplayBounds(ids[i]);
        if ((int)b.size.width == 1280 && (int)b.size.height == 800 && !CGDisplayIsBuiltin(ids[i])) pick = ids[i];
    }
    CGRect b = pick ? CGDisplayBounds(pick) : CGRectZero;
    bool changed = (pick != 0) != gHaveDisp || pick != gDisp || !CGRectEqualToRect(b, gBounds);
    gDisp = pick; gBounds = b; gHaveDisp = pick != 0;
    if (!changed) return;
    if (gHaveDisp) logf_("screen (%s): display %u, %.0fx%.0f @ %.0f,%.0f", why, pick, b.size.width, b.size.height, b.origin.x, b.origin.y);
    else logf_("screen (%s): MPC display not present; touches are ignored until it returns", why);
}
static void displayReconfigured(CGDirectDisplayID d, CGDisplayChangeSummaryFlags flags, void *info){
    (void)d; (void)info;
    if (!(flags & kCGDisplayBeginConfigurationFlag)) refreshDisplay("display change");
}

// ---------- pointer output ----------
static CGEventSourceRef gSrc = NULL;
static CFRunLoopTimerRef gFlushTimer = NULL;
static struct {
    bool down; int id;
    CGPoint last, pending; bool havePending;
    CGPoint filtered, rawLast; double lastInput; bool dragStarted;
    double lastPost, lastUp, lastDownT; CGPoint lastDownP; int clicks;
} T = { .id = -1 };
static struct { long reports, touches, drags; } stats;
static struct {
    bool blocked, tracking, scrollPosted;
    int idA, idB;
    double distance;
} pinch;

static bool koalaIsFocused(void){
    // The system-wide AX focused-app lookup can fail even when this helper is
    // permitted to post pointer events. NSWorkspace tracks the app that owns
    // the keyboard focus without another Accessibility query.
    @autoreleasepool {
        NSString *bundleID = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
        return [bundleID isEqualToString:@"com.elf-audio.koala-mac"];
    }
}

static void postPinchScroll(int delta, CGPoint center){
    if (opt.noPost || delta == 0) return;
    CGEventRef e = CGEventCreateScrollWheelEvent(gSrc, kCGScrollEventUnitPixel, 1, delta);
    if (!e) return;
    CGEventSetLocation(e, center);
    // Koala's Mac piano roll zooms with Alt + scroll. Check that the
    // sample editor still accepts this modified scroll in the live app.
    CGEventSetFlags(e, kCGEventFlagMaskAlternate);
    CGEventSetIntegerValueField(e, kCGScrollWheelEventIsContinuous, 1);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
    if (!pinch.scrollPosted){
        logf_("pinch: two contacts recognized; posting scroll deltas in Koala");
        pinch.scrollPosted = true;
    }
}

static void post(CGEventType type, CGPoint p){
    if (opt.noPost) return;
    CGEventRef e = CGEventCreateMouseEvent(gSrc, type, p, kCGMouseButtonLeft);
    if (!e) return;
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, T.clicks);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}
static void flushPending(void){
    if (T.havePending && T.down){
        if (hypot(T.pending.x - T.last.x, T.pending.y - T.last.y) >= 0.5){
            post(kCGEventLeftMouseDragged, T.pending);
            T.last = T.pending; T.lastPost = now_s(); stats.drags++;
        }
    }
    T.havePending = false;
}
static void flushTimerFired(CFRunLoopTimerRef t, void *info){ (void)t; (void)info; flushPending(); }

static void touchDown(int id, CGPoint p){
    double t = now_s();
    bool again = t - T.lastUp < 0.4 && hypot(p.x - T.lastDownP.x, p.y - T.lastDownP.y) < 24;
    T.clicks = again ? T.clicks + 1 : 1;
    T.down = true; T.id = id; T.last = p; T.havePending = false;
    T.filtered = p; T.rawLast = p; T.lastInput = t; T.dragStarted = false;
    T.lastDownT = t; T.lastDownP = p; T.lastPost = t;
    stats.touches++;
    post(kCGEventLeftMouseDown, p);
    if (opt.verbose || opt.noPost) logf_("down  id=%d at %.0f,%.0f%s", id, p.x, p.y, T.clicks > 1 ? " (double tap)" : "");
}
static void touchMove(CGPoint p){
    if (!T.down) return;
    double t = now_s(), gap = 1.0 / opt.rate;
    double dt = fmax(t - T.lastInput, 0.001);
    double rawDistance = hypot(p.x - T.rawLast.x, p.y - T.rawLast.y);
    T.rawLast = p; T.lastInput = t;
    if (!T.dragStarted){
        // Do not turn a stationary hold into a drag because the panel jitters.
        // Once the finger moves deliberately, tell Koala at once so its pad
        // drag starts without waiting for the next 60 Hz slot.
        if (hypot(p.x - T.lastDownP.x, p.y - T.lastDownP.y) < 4.0) return;
        T.dragStarted = true; T.filtered = p;
        post(kCGEventLeftMouseDragged, p);
        T.last = p; T.lastPost = t; stats.drags++;
        return;
    }
    // Smooth slow sensor wobble but follow quick movements with almost no lag.
    double speed = rawDistance / dt;
    double motion = fmin(1.0, fmax(0.0, (speed - 80.0) / 420.0));
    double tau = 0.014 * (1.0 - motion);
    double alpha = dt / (dt + tau);
    T.filtered.x += alpha * (p.x - T.filtered.x);
    T.filtered.y += alpha * (p.y - T.filtered.y);
    p = T.filtered;
    if (hypot(p.x - T.last.x, p.y - T.last.y) < 1.0){
        T.pending = p; T.havePending = false;
        return;
    }
    if (t - T.lastPost >= gap){
        T.havePending = false;
        if (p.x == T.last.x && p.y == T.last.y) return;
        post(kCGEventLeftMouseDragged, p);
        T.last = p; T.lastPost = t; stats.drags++;
    } else {
        T.pending = p; T.havePending = true;
        CFRunLoopTimerSetNextFireDate(gFlushTimer, T.lastPost + gap);
    }
}
static void touchUp(const char *why){
    if (!T.down) return;
    // Koala decides whether a pad reached the trash from the release position.
    // Finish at the actual finger coordinate, even if a smoothed drag is pending.
    T.havePending = false;
    if (T.dragStarted && hypot(T.rawLast.x - T.last.x, T.rawLast.y - T.last.y) >= 0.5){
        post(kCGEventLeftMouseDragged, T.rawLast);
        T.last = T.rawLast; stats.drags++;
    }
    post(kCGEventLeftMouseUp, T.last);
    if (opt.verbose || opt.noPost || why) logf_("up    id=%d at %.0f,%.0f after %.2f s%s%s", T.id, T.last.x, T.last.y,
                                               now_s() - T.lastDownT, why ? " — " : "", why ? why : "");
    T.down = false; T.id = -1; T.lastUp = now_s();
}

// ---------- touch reports ----------
// Report 0x10 (64 bytes incl. ID): 10 slots × {flags, contact id, x lo, x hi, y lo, y hi},
// contact count at byte 61, scan time at 62–63. flags bit 0 = tip switch. X/Y 0–4095.
static bool mapPoint(int x, int y, CGPoint *out){
    if (!gHaveDisp || x > 4095 || y > 4095) return false;
    out->x = gBounds.origin.x + (double)x / 4095.0 * (gBounds.size.width - 1);
    out->y = gBounds.origin.y + (double)y / 4095.0 * (gBounds.size.height - 1);
    return true;
}
static void handlePinchPair(int idA, CGPoint a, int idB, CGPoint b){
    double distance = hypot(a.x - b.x, a.y - b.y);
    if (distance < 28.0) return; // close contacts are too noisy for a useful pinch
    if (!pinch.tracking || pinch.idA != idA || pinch.idB != idB){
        pinch.tracking = true;
        pinch.idA = idA; pinch.idB = idB; pinch.distance = distance;
        return;
    }
    if (fabs(distance - pinch.distance) < 3.0) return;
    int delta = (int)round(-opt.pinchGain * log(distance / pinch.distance));
    pinch.distance = distance;
    CGPoint center = { (a.x + b.x) / 2.0, (a.y + b.y) / 2.0 };
    postPinchScroll(delta, center);
}
/// `r` points at the first slot (just after the report ID).
static void handleTouchReport(const uint8_t *r){
    stats.reports++;
    int count = r[60];
    if (count > 10) return;  // malformed report; retain the current contact
    int n = count;           // zero contacts is a release, not a stale first slot
    if (opt.verbose){
        char line[256]; int off = snprintf(line, sizeof line, "report count=%d", count);
        for (int i = 0; i < n && off < (int)sizeof line - 32; i++){
            const uint8_t *s = r + 6*i;
            off += snprintf(line + off, sizeof line - off, "  [f=%02x id=%d %d,%d]", s[0], s[1], s[2] | s[3] << 8, s[4] | s[5] << 8);
        }
        logf_("%s", line);
    }
    if (!gHaveDisp){
        touchUp("MPC display missing");
        pinch.blocked = pinch.tracking = false;
        return;
    }
    // Koala's Mac view receives scroll events; the editor under the midpoint
    // decides how they affect its zoom.
    // Keep the primary mouse gesture intact until a second finger appears; then
    // release it and suppress new mouse downs until every finger has lifted.
    if (pinch.blocked || (n >= 2 && koalaIsFocused())){
        if (!pinch.blocked){
            touchUp("pinch began");
            pinch.blocked = true;
            pinch.tracking = false;
            pinch.scrollPosted = false;
            T.lastUp = 0; // the next single touch must not become a double tap
        }
        int ids[2], found = 0;
        CGPoint points[2];
        for (int i = 0; i < n; i++){
            const uint8_t *s = r + 6*i;
            CGPoint p;
            if ((s[0] & 1) && mapPoint(s[2] | s[3] << 8, s[4] | s[5] << 8, &p)){
                if (found < 2){ ids[found] = s[1]; points[found] = p; }
                found++;
            }
        }
        if (found == 2){
            if (ids[0] > ids[1]){
                int id = ids[0]; ids[0] = ids[1]; ids[1] = id;
                CGPoint p = points[0]; points[0] = points[1]; points[1] = p;
            }
            handlePinchPair(ids[0], points[0], ids[1], points[1]);
        }
        else pinch.tracking = false;
        // The SiS panel's last report keeps the lifted contact in the count
        // with tip-switch clear; it does not necessarily send count=0.
        if (found == 0){
            logf_("pinch ended; ordinary touch restored");
            pinch.blocked = false;
            pinch.tracking = false;
            pinch.scrollPosted = false;
            T.lastUp = 0;
        }
        return;
    }
    if (!T.down){
        for (int i = 0; i < n; i++){
            const uint8_t *s = r + 6*i; CGPoint p;
            if ((s[0] & 1) && mapPoint(s[2] | s[3] << 8, s[4] | s[5] << 8, &p)){ touchDown(s[1], p); break; }
        }
        return;
    }
    for (int i = 0; i < n; i++){
        const uint8_t *s = r + 6*i;
        if (s[1] != T.id) continue;
        CGPoint p;
        if ((s[0] & 1) && mapPoint(s[2] | s[3] << 8, s[4] | s[5] << 8, &p)) touchMove(p);
        else touchUp(NULL);
        return;
    }
    touchUp(NULL);   // the primary finger is no longer reported
}

// ---------- HID path (macOS HID driver owns the panel) ----------
static IOHIDManagerRef gHid = NULL;
static IOHIDDeviceRef gDev = NULL;
static bool gHidOpen = false;
static uint8_t gHidBuf[64];

static void onHidReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                        uint32_t reportID, uint8_t *r, CFIndex len){
    (void)ctx; (void)sender; (void)type;
    if (result != kIOReturnSuccess) return;
    if (len >= 62 && r[0] == 0x10) handleTouchReport(r + 1);            // buffer includes the report ID
    else if (reportID == 0x10 && len >= 61) handleTouchReport(r);       // ID stripped
}
static void stopRaw(const char *why);
static bool rawOpen(void);
static void onHidMatch(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev){
    (void)ctx; (void)result; (void)sender;
    if (gDev) return;
    if (rawOpen()) stopRaw("macOS HID driver took over");
    gDev = dev; CFRetain(dev);
    IOHIDDeviceRegisterInputReportCallback(dev, gHidBuf, sizeof gHidBuf, onHidReport, NULL);
    logf_("reading touches via macOS HID driver");
    refreshDisplay("panel attached");
}
static void onHidRemove(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev){
    (void)ctx; (void)result; (void)sender;
    if (dev != gDev) return;
    touchUp("panel removed");
    pinch.blocked = pinch.tracking = false;
    CFRelease(gDev); gDev = NULL;
    logf_("HID touch device removed");
}
static void openHid(void){
    IOReturn r = IOHIDManagerOpen(gHid, opt.seize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone);
    if (r == kIOReturnSuccess){ gHidOpen = true; return; }
    static double lastLog = 0;
    if (now_s() - lastLog > 60){
        lastLog = now_s();
        logf_("HID open failed 0x%x%s", r, r == kIOReturnNotPermitted ? " — allow mpc_touchd in Privacy & Security → Input Monitoring" : "");
        if (r == kIOReturnNotPermitted) IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    }
}

// ---------- raw-USB path (AkaiTouchPanel.kext blocks the HID driver) ----------
static IONotificationPortRef gNotify = NULL;
static struct {
    IOUSBInterfaceInterface300 **intf;
    CFRunLoopSourceRef src;
    io_object_t interest;
    UInt8 pipe;
    bool open;
    int errors;
    double stoppedAt, configuredAt;
    uint8_t buf[RAW_READS][64];
} R;

static bool rawOpen(void){ return R.open; }

static void stopRaw(const char *why){
    if (!R.intf) return;
    bool wasOpen = R.open;
    R.open = false;
    touchUp(why);
    pinch.blocked = pinch.tracking = false;
    if (wasOpen){ (*R.intf)->USBInterfaceClose(R.intf); }
    if (R.src){ CFRunLoopRemoveSource(CFRunLoopGetMain(), R.src, kCFRunLoopDefaultMode); R.src = NULL; }
    (*R.intf)->Release(R.intf); R.intf = NULL;
    if (R.interest){ IOObjectRelease(R.interest); R.interest = 0; }
    R.stoppedAt = now_s();
    logf_("raw USB reader closed (%s)", why);
}

static void onRawRead(void *refcon, IOReturn result, void *arg0);
static bool armRead(int k){
    IOReturn kr = (*R.intf)->ReadPipeAsync(R.intf, R.pipe, R.buf[k], sizeof R.buf[k], onRawRead, (void *)(intptr_t)k);
    if (kr != kIOReturnSuccess){ logf_("raw read queue failed 0x%x", kr); return false; }
    return true;
}
static void onRawRead(void *refcon, IOReturn result, void *arg0){
    if (!R.open) return;
    int k = (int)(intptr_t)refcon;
    UInt32 len = (UInt32)(uintptr_t)arg0;
    if (result == kIOReturnSuccess){
        R.errors = 0;
        // Copy the completed frame, then put the USB read back in flight before
        // creating mouse events. The HID path uses the same report decoder.
        uint8_t report[64];
        bool valid = len >= 62 && R.buf[k][0] == 0x10;
        if (valid) memcpy(report, R.buf[k], sizeof report);
        if (!armRead(k)){ stopRaw("could not re-queue a read"); return; }
        if (valid) handleTouchReport(report + 1);
        return;
    }
    if (result == kIOReturnAborted) return;                      // we closed it
    R.errors++;
    logf_("raw read error 0x%x (%d in a row)", result, R.errors);
    if (result == kIOUSBPipeStalled && R.errors == 1){           // one clear, then give up
        (*R.intf)->ClearPipeStallBothEnds(R.intf, R.pipe);
        if (armRead(k)) return;
    }
    stopRaw("read errors; retrying in 2 s if the panel is still there");
}
static void onInterfaceInterest(void *refcon, io_service_t service, natural_t type, void *arg){
    (void)refcon; (void)service; (void)arg;
    if (type == kIOMessageServiceIsTerminated) stopRaw("panel removed");
}

/// The blocker leaves the panel unconfigured; select configuration 1 once.
static void configureSis(void){
    io_service_t d = IOServiceGetMatchingService(kIOMainPortDefault, akaiMatch("IOUSBHostDevice", SIS_PID));
    if (!d) return;
    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    IOUSBDeviceInterface300 **dev = NULL;
    if (IOCreatePlugInInterfaceForService(d, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) == kIOReturnSuccess && plug){
        (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300), (LPVOID *)&dev);
        (*plug)->Release(plug);
    }
    IOObjectRelease(d);
    if (!dev) return;
    UInt8 cfg = 0;
    (*dev)->GetConfiguration(dev, &cfg);
    if (cfg == 0){
        IOReturn kr = (*dev)->USBDeviceOpen(dev);
        bool seized = false;
        if (kr == kIOReturnExclusiveAccess){ kr = (*dev)->USBDeviceOpenSeize(dev); seized = true; }
        if (kr == kIOReturnSuccess){
            kr = (*dev)->SetConfiguration(dev, 1);
            logf_("panel configuration set (0x%x)%s", kr, seized ? " [seized]" : "");
            (*dev)->USBDeviceClose(dev);
        } else logf_("panel open for configuration failed 0x%x", kr);
    }
    (*dev)->Release(dev);
}

static void startRaw(io_service_t ifSvc){
    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(ifSvc, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess || !plug){
        R.stoppedAt = now_s(); return;
    }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&R.intf);
    (*plug)->Release(plug);
    if (!R.intf){ R.stoppedAt = now_s(); return; }
    IOReturn kr = (*R.intf)->USBInterfaceOpen(R.intf);
    bool seized = false;
    if (kr == kIOReturnExclusiveAccess){ kr = (*R.intf)->USBInterfaceOpenSeize(R.intf); seized = true; }
    if (kr != kIOReturnSuccess){
        logf_("raw open failed 0x%x", kr);
        (*R.intf)->Release(R.intf); R.intf = NULL; R.stoppedAt = now_s(); return;
    }
    R.open = true; R.errors = 0;
    (*R.intf)->CreateInterfaceAsyncEventSource(R.intf, &R.src);
    CFRunLoopAddSource(CFRunLoopGetMain(), R.src, kCFRunLoopDefaultMode);
    UInt8 nPipes = 0; R.pipe = 0;
    (*R.intf)->GetNumEndpoints(R.intf, &nPipes);
    for (UInt8 p = 1; p <= nPipes && !R.pipe; p++){
        UInt8 dir, num, ttype, interval; UInt16 size;
        if ((*R.intf)->GetPipeProperties(R.intf, p, &dir, &num, &ttype, &size, &interval) == kIOReturnSuccess
            && dir == kUSBIn && ttype == kUSBInterrupt) R.pipe = p;
    }
    if (!R.pipe){ stopRaw("no interrupt IN pipe"); return; }
    IOServiceAddInterestNotification(gNotify, ifSvc, kIOGeneralInterest, onInterfaceInterest, NULL, &R.interest);
    int queued = 0;
    for (int k = 0; k < RAW_READS; k++) queued += armRead(k);
    if (!queued){ stopRaw("could not queue reads"); return; }
    logf_("reading touches via raw USB, %d reads queued%s (AkaiTouchPanel.kext keeps the HID driver off)",
          queued, seized ? " [seized]" : "");
    refreshDisplay("panel attached");
}

// ---------- wake over CoreMIDI ----------
static MIDIClientRef gMidi = 0;
static MIDIPortRef gMidiOut = 0;
static int gWakeRounds = 0;

// CoreMIDI's kMIDIProperty* constants are only filled in once a client exists.
// A volatile read stops the compiler from loading them early (v2's bug).
static CFStringRef midiKey(const CFStringRef *key){ return *(const CFStringRef volatile *)key; }
static void midiString(MIDIObjectRef o, const CFStringRef *key, char *out, size_t n){
    CFStringRef s = NULL; out[0] = 0;
    if (MIDIObjectGetStringProperty(o, midiKey(key), &s) == noErr && s){
        CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(s);
    }
}
static void midiNotify(const MIDINotification *msg, void *info){ (void)msg; (void)info; }

/// The MPC Touch's Public destination and its external MIDI Port; never Private.
static void findMpcPorts(MIDIEndpointRef *pub, MIDIEndpointRef *ext){
    *pub = *ext = 0;
    for (ItemCount i = 0; i < MIDIGetNumberOfDevices(); i++){
        MIDIDeviceRef dev = MIDIGetDevice(i);
        char manu[128], name[128], model[128]; SInt32 off = 0;
        midiString(dev, &kMIDIPropertyManufacturer, manu, sizeof manu);
        midiString(dev, &kMIDIPropertyName, name, sizeof name);
        midiString(dev, &kMIDIPropertyModel, model, sizeof model);
        MIDIObjectGetIntegerProperty(dev, midiKey(&kMIDIPropertyOffline), &off);
        if (off || !strcasestr(manu, "akai") || !(strcasestr(name, "MPC Touch") || strcasestr(model, "MPC Touch"))) continue;
        for (ItemCount j = 0; j < MIDIDeviceGetNumberOfEntities(dev); j++){
            MIDIEntityRef ent = MIDIDeviceGetEntity(dev, j);
            char en[64]; SInt32 priv = 0;
            midiString(ent, &kMIDIPropertyName, en, sizeof en);
            MIDIObjectGetIntegerProperty(ent, midiKey(&kMIDIPropertyPrivate), &priv);
            if (priv || MIDIEntityGetNumberOfDestinations(ent) == 0) continue;
            if (!strcmp(en, "Public")) *pub = MIDIEntityGetDestination(ent, 0);
            else if (!strcmp(en, "MIDI Port")) *ext = MIDIEntityGetDestination(ent, 0);
        }
    }
}
static void sendSysex(MIDIEndpointRef dest, const Byte *data, size_t len){
    Byte storage[256]; MIDIPacketList *pl = (MIDIPacketList *)storage;
    MIDIPacket *pk = MIDIPacketListInit(pl);
    pk = MIDIPacketListAdd(pl, sizeof storage, pk, 0, len, data);
    if (pk) MIDISend(gMidiOut, dest, pl);
}
static void wakeRound(void){
    MIDIEndpointRef pub, ext;
    findMpcPorts(&pub, &ext);
    if (!pub){
        static double lastLog = 0;
        if (now_s() - lastLog > 30){ lastLog = now_s(); logf_("wake: MPC Touch Public MIDI port not visible yet"); }
        return;
    }
    // v1's bytes, proven to wake the panel on this Mac.
    static const Byte gate[]    = {0xF0,0x47,0x7F,0x37,0x64,0x00,0x01,0x01,0xF7};
    static const Byte display[] = {0xF0,0x47,0x7F,0x37,0x64,0x00,0x03,0x00,0x01,0xF7};
    gWakeRounds++;
    bool widen = gWakeRounds >= 3 && ext;   // v1 also sent to the MIDI Port; only if Public alone fails
    sendSysex(pub, gate, sizeof gate); sendSysex(pub, display, sizeof display);
    if (widen){ sendSysex(ext, gate, sizeof gate); sendSysex(ext, display, sizeof display); }
    logf_("wake round %d → Public%s", gWakeRounds, widen ? " + MIDI Port" : "");
}

// ---------- housekeeping (every 0.5 s) ----------
static void tick(CFRunLoopTimerRef t, void *info){
    (void)t; (void)info;
    static double ctrlSince = 0, lastRound = 0, sisSince = 0, lastPerm = 0, lastStats = 0, lastConfig = 0;
    static bool axLogged = false, axState = true;
    double now = now_s();

    if (!gHidOpen) openHid();

    if (usbPresent(SIS_PID)){
        if (sisSince == 0){
            sisSince = now;
            if (gWakeRounds) logf_("touch panel on USB after %d wake round%s", gWakeRounds, gWakeRounds == 1 ? "" : "s");
            else logf_("touch panel on USB");
            gWakeRounds = 0;
        }
        // Prefer the HID driver; give it 0.7 s to claim the panel before reading raw.
        if (!gDev && !R.intf && now - sisSince >= 0.7 && now - R.stoppedAt >= 2.0){
            io_service_t ifc = sisInterface0();
            if (ifc){ startRaw(ifc); IOObjectRelease(ifc); }
            else if (now - lastConfig >= 3.0){ lastConfig = now; configureSis(); }
        }
    } else {
        if (sisSince){ sisSince = 0; logf_("touch panel left USB (controller %s)", usbPresent(CONTROLLER_PID) ? "still present" : "gone too"); }
        if (R.intf) stopRaw("panel left USB");
        if (!usbPresent(CONTROLLER_PID)){ ctrlSince = 0; gWakeRounds = 0; }
        else if (ctrlSince == 0) ctrlSince = now;                   // let a re-enumerating MPC settle
        else if (now - ctrlSince >= 2.0){
            double interval = gWakeRounds < 5 ? 2.0 : 15.0;            // back off after 5 tries
            if (now - lastRound >= interval){ lastRound = now; wakeRound(); }
        }
    }

    // The MPC's screen can come back after the panel (e.g. after a drop-out); keep looking.
    if (!gHaveDisp) refreshDisplay("waiting for MPC screen");

    // CGPreflightPostEventAccess() is cached for the life of the process, so a grant made
    // after launch never shows up there. AXIsProcessTrusted() is live: when it turns true,
    // exit and let launchd (KeepAlive) start a fresh process that can post events.
    if (!opt.noPost && now - lastPerm > (axState ? 30 : 3)){
        lastPerm = now;
        bool ax = CGPreflightPostEventAccess();
        if (!axLogged || ax != axState){
            axLogged = true; axState = ax;
            logf_(ax ? "Accessibility: allowed (touches move the pointer)"
                     : "Accessibility: NOT allowed — System Settings → Privacy & Security → Accessibility → enable mpc_touchd");
        }
        if (!ax && AXIsProcessTrusted()){
            logf_("Accessibility was just granted: restarting to apply it");
            touchUp("restart");
            exit(0);
        }
    }

    if (now - lastStats >= 60){
        if (stats.reports) logf_("last minute: %ld reports, %ld touches, %ld drags posted", stats.reports, stats.touches, stats.drags);
        memset(&stats, 0, sizeof stats); lastStats = now;
    }
}

static void onSignal(int sig){
    logf_("signal %d: releasing pointer and stopping", sig);
    touchUp("stopping");
    CFRunLoopStop(CFRunLoopGetMain());
}

static void usage(void){
    printf("mpc_touchd v3 — MPC Touch touchscreen driver\n"
           "  --no-post   read and log touches, never move the pointer (diagnostic)\n"
           "  --verbose   log every touch report\n"
           "  --seize     open the touch panel exclusively (HID path)\n"
           "  --rate N    max drag events per second (default 60)\n"
           "  --pinch-gain N  Koala zoom scroll gain (default 560)\n");
}

int main(int argc, char **argv){
    for (int i = 1; i < argc; i++){
        if (!strcmp(argv[i], "--no-post")) opt.noPost = true;
        else if (!strcmp(argv[i], "--verbose")) opt.verbose = true;
        else if (!strcmp(argv[i], "--seize")) opt.seize = true;
        else if (!strcmp(argv[i], "--rate") && i + 1 < argc){ opt.rate = atof(argv[++i]); if (opt.rate < 10) opt.rate = 10; if (opt.rate > 500) opt.rate = 500; }
        else if (!strcmp(argv[i], "--pinch-gain") && i + 1 < argc){
            char *end = NULL;
            double gain = strtod(argv[++i], &end);
            if (!end || *end || !isfinite(gain) || gain < 100 || gain > 1200){ usage(); return 2; }
            opt.pinchGain = gain;
        }
        else { usage(); return strcmp(argv[i], "--help") ? 2 : 0; }
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    logf_("mpc_touchd v3 started%s%s%s, drags ≤%.0f/s, pinch gain %.0f", opt.noPost ? " [no-post]" : "",
          opt.verbose ? " [verbose]" : "", opt.seize ? " [seize]" : "", opt.rate, opt.pinchGain);

    // CoreMIDI client first — its property constants don't exist before this.
    OSStatus st = MIDIClientCreate(CFSTR("mpc_touchd"), midiNotify, NULL, &gMidi);
    if (st == noErr) st = MIDIOutputPortCreate(gMidi, CFSTR("wake"), &gMidiOut);
    if (st != noErr) logf_("CoreMIDI unavailable (%d): the panel can't be woken, only used if already awake", (int)st);

    gSrc = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (gSrc) CGEventSourceSetLocalEventsSuppressionInterval(gSrc, 0);   // don't freeze the trackpad after a touch
    refreshDisplay("start");
    CGDisplayRegisterReconfigurationCallback(displayReconfigured, NULL);
    if (!opt.noPost && !CGPreflightPostEventAccess()) CGRequestPostEventAccess();

    gNotify = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(gNotify), kCFRunLoopDefaultMode);

    gHid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int vid = AKAI_VID, pid = SIS_PID;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vn);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), pn);
    CFRelease(vn); CFRelease(pn);
    IOHIDManagerSetDeviceMatching(gHid, match); CFRelease(match);
    IOHIDManagerRegisterDeviceMatchingCallback(gHid, onHidMatch, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHid, onHidRemove, NULL);
    IOHIDManagerScheduleWithRunLoop(gHid, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    openHid();

    gFlushTimer = CFRunLoopTimerCreate(NULL, now_s() + 1e9, 1e9, 0, 0, flushTimerFired, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), gFlushTimer, kCFRunLoopDefaultMode);
    CFRunLoopTimerRef tickTimer = CFRunLoopTimerCreate(NULL, now_s() + 0.2, 0.5, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), tickTimer, kCFRunLoopDefaultMode);

    int sigs[] = { SIGTERM, SIGINT, SIGHUP };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++){
        int s = sigs[i];
        signal(s, SIG_IGN);
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)s, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ onSignal(s); });
        dispatch_resume(src);
    }

    CFRunLoopRun();

    touchUp("exit");
    if (R.intf) stopRaw("exit");
    if (gHid){ IOHIDManagerClose(gHid, kIOHIDOptionsTypeNone); CFRelease(gHid); }
    if (gMidi) MIDIClientDispose(gMidi);
    logf_("mpc_touchd v3 stopped");
    return 0;
}
