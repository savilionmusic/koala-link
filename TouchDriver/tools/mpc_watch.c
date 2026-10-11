// ============================================================
// mpc_watch.c — read-only flight recorder for MPC Touch drop-outs (2026-09-28)
//
// Puts every suspect on one timeline in ~/Library/Logs/mpc_watch.log. It never
// sends anything to the MPC, never opens its devices, never injects input.
//
//  USB      add/remove of MPC devices and of anything on the MPC's USB bus
//           (the USB-C adapter hub + billboard in front of it), with registry IDs
//  clients  which processes hold USB user clients on the MPC's chips (dfu-util,
//           Stream Deck, browsers, UA Connect, DisplayLink, our own driver...)
//  MIDI     messages per second from the MPC's Public / Private / MIDI Port
//           sources (a silent controller shows up as zeros while you play)
//  screen   MPC display present/absent; DisplayLinkUserAgent CPU per second
//  CPU      the app (MPC Touch) and the touch driver (mpc_touchd) per second
//  audio    MPC Touch Audio device alive / running / sample rate changes
//  syslog   kernel lines about the MPC path, DisplayLink/usbaudiod/MIDIServer
//           errors, coreaudiod overloads, anything named dfu; RTAID counted
//  logs     the touch driver's and the app's own logs, merged in
//  power    Mac sleep / wake
//
// It keeps the last 3 minutes of per-second samples in memory. Whenever
// something happens it writes out the 60 s before it, and 20 s later the aftermath.
//
//   mpc_watch                 run (normally as LaunchAgent com.savilion.mpc-watch)
//   mpc_watch mark "text"     note a moment ("pads dead") and make the watcher dump
//
// Build: see build-watch.sh
// ============================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <CoreMIDI/CoreMIDI.h>
#include <CoreAudio/CoreAudio.h>

#define MPC_DISP_VENDOR 0x5109
#define MPC_DISP_MODEL  0x1211
#define RING 180

// ---------- logging ----------
static pthread_mutex_t logLock = PTHREAD_MUTEX_INITIALIZER;
static void logf_(const char *fmt, ...){
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
    char ts[32]; strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    pthread_mutex_lock(&logLock);
    printf("%s.%03d ", ts, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
    printf("\n"); fflush(stdout);
    pthread_mutex_unlock(&logLock);
}
static double now_s(void){ return CFAbsoluteTimeGetCurrent(); }

// ---------- triggers ----------
static atomic_bool gTrigger;
static char gTriggerWhy[200];
static void trigger(const char *why){
    pthread_mutex_lock(&logLock);
    if (!atomic_load(&gTrigger)) snprintf(gTriggerWhy, sizeof gTriggerWhy, "%s", why);
    pthread_mutex_unlock(&logLock);
    atomic_store(&gTrigger, true);
}

// ---------- per-second ring ----------
typedef struct { double t; int midi[3]; float dl, app, td; int usb; int disp; } Sample;
static Sample ring[RING]; static int ringCount = 0, ringNext = 0;
static atomic_int midiNow[3];

static void usbBits(int bits, char out[4]){
    out[0] = bits & 1 ? 'C' : '-'; out[1] = bits & 2 ? 'T' : '-'; out[2] = bits & 4 ? 'S' : '-'; out[3] = 0;
}
static void dump(const char *label, int seconds){
    int n = seconds < ringCount ? seconds : ringCount;
    logf_("---- %s: last %d s (midi Public/Private/Port per s · CPU %% · usb C=controller T=touch S=screen · disp) ----", label, n);
    double tEnd = ring[(ringNext - 1 + RING) % RING].t;
    for (int i = n; i >= 1; i--){
        const Sample *s = &ring[(ringNext - i + RING) % RING];
        char u[4]; usbBits(s->usb, u);
        logf_("   t%+4.0fs  midi %3d/%3d/%3d  DL %5.1f  app %5.1f  touchd %4.1f  usb %s  disp %d",
              s->t - tEnd, s->midi[0], s->midi[1], s->midi[2], s->dl, s->app, s->td, u, s->disp);
    }
    logf_("---- end ----");
}

// ---------- USB registry ----------
static long regNum(io_registry_entry_t e, CFStringRef key){
    long x = -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, NULL, 0);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &x);
    if (v) CFRelease(v);
    return x;
}
static bool usbPresent(int vid, int pid){
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR("idVendor"), vn); CFDictionarySetValue(m, CFSTR("idProduct"), pn);
    CFRelease(vn); CFRelease(pn);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s) IOObjectRelease(s);
    return s != 0;
}
static long gMpcBus = 0x01;   // top byte of the MPC's locationID; refreshed when the controller appears
static void refreshMpcBus(void){
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    int vid = 0x09E8, pid = 0x0037;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &vid), pn = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR("idVendor"), vn); CFDictionarySetValue(m, CFSTR("idProduct"), pn);
    CFRelease(vn); CFRelease(pn);
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (s){ long loc = regNum(s, CFSTR("locationID")); if (loc > 0) gMpcBus = (loc >> 24) & 0xff; IOObjectRelease(s); }
}
static IONotificationPortRef gNotify;
static io_iterator_t gAddIter, gRemIter;
static void usbEvent(io_iterator_t it, bool added, bool quiet){
    io_service_t d;
    while ((d = IOIteratorNext(it))){
        long vid = regNum(d, CFSTR("idVendor")), pid = regNum(d, CFSTR("idProduct")), loc = regNum(d, CFSTR("locationID"));
        bool mpc = vid == 0x09E8 || vid == 0x17E9;
        if (!quiet && (mpc || ((loc >> 24) & 0xff) == gMpcBus)){
            io_name_t name = ""; IORegistryEntryGetName(d, name);
            uint64_t rid = 0; IORegistryEntryGetRegistryEntryID(d, &rid);
            logf_("USB %s %s  %04lx:%04lx @0x%08lx  id 0x%llx", added ? "+ ARRIVED" : "- GONE   ", name, vid, pid, loc, rid);
            char why[160]; snprintf(why, sizeof why, "USB %s %s", added ? "arrived" : "gone", name);
            trigger(why);
            if (added && vid == 0x09E8 && pid == 0x0037) refreshMpcBus();
        }
        IOObjectRelease(d);
    }
}
static void onUsbAdd(void *r, io_iterator_t it){ (void)r; usbEvent(it, true, false); }
static void onUsbRemove(void *r, io_iterator_t it){ (void)r; usbEvent(it, false, false); }

// who holds user clients on the MPC's chips
static char gClients[4096] = "";
static void snapshotClients(bool first){
    char buf[4096] = ""; size_t off = 0;
    io_iterator_t it = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
    io_service_t d;
    char items[64][96]; int ni = 0;
    while ((d = IOIteratorNext(it))){
        long vid = regNum(d, CFSTR("idVendor")), pid = regNum(d, CFSTR("idProduct"));
        const char *tag = vid == 0x09E8 && pid == 0x0037 ? "controller" : vid == 0x09E8 && pid == 0x8001 ? "touch" : vid == 0x17E9 && pid == 0xFF00 ? "screen" : NULL;
        if (tag){
            io_iterator_t ci = 0;
            if (IORegistryEntryCreateIterator(d, kIOServicePlane, kIORegistryIterateRecursively, &ci) == KERN_SUCCESS){
                io_registry_entry_t c;
                while ((c = IOIteratorNext(ci))){
                    io_name_t cls; IOObjectGetClass(c, cls);
                    if (strstr(cls, "UserClient")){
                        CFTypeRef v = IORegistryEntryCreateCFProperty(c, CFSTR("IOUserClientCreator"), NULL, 0);
                        char who[64] = "?";
                        if (v && CFGetTypeID(v) == CFStringGetTypeID()){
                            char raw[96]; CFStringGetCString(v, raw, sizeof raw, kCFStringEncodingUTF8);
                            int p = 0; char nm[64] = "";
                            if (sscanf(raw, "pid %d, %63[^\n]", &p, nm) == 2) snprintf(who, sizeof who, "%s", nm);
                            else snprintf(who, sizeof who, "%s", raw);
                        }
                        if (v) CFRelease(v);
                        char item[96]; snprintf(item, sizeof item, "%s→%s", who, tag);
                        bool dup = false;
                        for (int k = 0; k < ni; k++) if (!strcmp(items[k], item)) dup = true;
                        if (!dup && ni < 64) snprintf(items[ni++], sizeof items[0], "%s", item);
                    }
                    IOObjectRelease(c);
                }
                IOObjectRelease(ci);
            }
        }
        IOObjectRelease(d);
    }
    IOObjectRelease(it);
    // sort for stable comparison
    for (int a = 0; a < ni; a++) for (int b = a + 1; b < ni; b++)
        if (strcmp(items[a], items[b]) > 0){ char t[96]; memcpy(t, items[a], 96); memcpy(items[a], items[b], 96); memcpy(items[b], t, 96); }
    for (int k = 0; k < ni; k++) off += snprintf(buf + off, sizeof buf - off, "%s%s", k ? ", " : "", items[k]);
    if (first){ logf_("USB clients on MPC chips: %s", ni ? buf : "(none)"); }
    else if (strcmp(buf, gClients)){
        // report what appeared / disappeared
        char added[1024] = "", removed[1024] = ""; size_t ao = 0, ro = 0;
        for (int k = 0; k < ni; k++) if (!strstr(gClients, items[k])) ao += snprintf(added + ao, sizeof added - ao, " +%s", items[k]);
        char prev[4096]; snprintf(prev, sizeof prev, "%s", gClients);
        for (char *tok = strtok(prev, ","); tok; tok = strtok(NULL, ",")){
            while (*tok == ' ') tok++;
            if (*tok && !strstr(buf, tok)) ro += snprintf(removed + ro, sizeof removed - ro, " -%s", tok);
        }
        logf_("USB clients changed:%s%s", added, removed);
    }
    snprintf(gClients, sizeof gClients, "%s", buf);
}

// ---------- process CPU ----------
typedef struct { const char *name; pid_t pid; uint64_t lastNs; double lastT; } Proc;
static Proc procs[3] = { {"DisplayLinkUserAgent", 0, 0, 0}, {"MPC Touch", 0, 0, 0}, {"mpc_touchd", 0, 0, 0} };
static mach_timebase_info_data_t gTb;
static pid_t findPid(const char *name){
    static pid_t pids[8192];
    int n = proc_listallpids(pids, sizeof pids);
    for (int i = 0; i < n; i++){
        char nm[64] = "";
        if (proc_name(pids[i], nm, sizeof nm) > 0 && !strcmp(nm, name)) return pids[i];
    }
    return 0;
}
static float cpuOf(Proc *p, double now){
    struct rusage_info_v2 ri;
    if (p->pid <= 0 || proc_pid_rusage(p->pid, RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0){
        p->pid = findPid(p->name); p->lastNs = 0;
        if (p->pid <= 0 || proc_pid_rusage(p->pid, RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0) return -1;
    }
    uint64_t ns = (ri.ri_user_time + ri.ri_system_time) * gTb.numer / gTb.denom;   // rusage is in mach ticks here
    float pct = 0;
    if (p->lastNs && now > p->lastT) pct = (float)((double)(ns - p->lastNs) / 1e9 / (now - p->lastT) * 100.0);
    p->lastNs = ns; p->lastT = now;
    return pct;
}

// ---------- display ----------
static int mpcDisplayPresent(void){
    CGDirectDisplayID ids[16]; uint32_t n = 0;
    CGGetOnlineDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayVendorNumber(ids[i]) == MPC_DISP_VENDOR && CGDisplayModelNumber(ids[i]) == MPC_DISP_MODEL) return 1;
    return 0;
}

// ---------- MIDI (listen only) ----------
static MIDIClientRef gMidi; static MIDIPortRef gMidiIn;
static CFStringRef midiKey(const CFStringRef *k){ return *(const CFStringRef volatile *)k; }
static void midiStr(MIDIObjectRef o, const CFStringRef *k, char *out, size_t n){
    CFStringRef s = NULL; out[0] = 0;
    if (MIDIObjectGetStringProperty(o, midiKey(k), &s) == noErr && s){ CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(s); }
}
static void midiRead(const MIDIPacketList *pl, void *refCon, void *src){
    (void)refCon;
    int k = (int)(intptr_t)src;
    if (k >= 0 && k < 3) atomic_fetch_add(&midiNow[k], (int)pl->numPackets);
}
static int gMidiOffline = -1;
static void connectMidi(void){
    if (gMidiIn){ MIDIPortDispose(gMidiIn); gMidiIn = 0; }
    MIDIInputPortCreate(gMidi, CFSTR("watch"), midiRead, NULL, &gMidiIn);
    char got[96] = ""; size_t off = 0; int offline = -1;
    for (ItemCount i = 0; i < MIDIGetNumberOfDevices(); i++){
        MIDIDeviceRef d = MIDIGetDevice(i);
        char model[64]; midiStr(d, &kMIDIPropertyModel, model, sizeof model);
        if (!strstr(model, "MPC Touch")) continue;
        SInt32 off0 = 0; MIDIObjectGetIntegerProperty(d, midiKey(&kMIDIPropertyOffline), &off0); offline = off0;
        for (ItemCount j = 0; j < MIDIDeviceGetNumberOfEntities(d); j++){
            MIDIEntityRef e = MIDIDeviceGetEntity(d, j);
            char en[64]; midiStr(e, &kMIDIPropertyName, en, sizeof en);
            intptr_t k = !strcmp(en, "Public") ? 0 : !strcmp(en, "Private") ? 1 : !strcmp(en, "MIDI Port") ? 2 : -1;
            if (k < 0 || !MIDIEntityGetNumberOfSources(e)) continue;
            if (MIDIPortConnectSource(gMidiIn, MIDIEntityGetSource(e, 0), (void *)k) == noErr)
                off += snprintf(got + off, sizeof got - off, "%s%s", off ? " " : "", en);
        }
    }
    if (offline != gMidiOffline){
        logf_("MIDI: MPC device %s; listening to [%s]", offline < 0 ? "ABSENT" : offline ? "OFFLINE" : "online", got);
        if (gMidiOffline != -2 && offline != 0) trigger("MIDI device offline/absent");
        gMidiOffline = offline;
    }
}
static void midiNotify(const MIDINotification *msg, void *info){
    (void)info;
    if (msg->messageID == kMIDIMsgSetupChanged) connectMidi();
}

// ---------- audio device ----------
static AudioObjectID gAudio = 0;
static void audioLog(const char *what){
    UInt32 alive = 0, running = 0, sz = sizeof(UInt32); Float64 sr = 0; UInt32 szr = sizeof sr;
    AudioObjectPropertyAddress a = { kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(gAudio, &a, 0, NULL, &sz, &alive);
    a.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere; sz = sizeof(UInt32);
    AudioObjectGetPropertyData(gAudio, &a, 0, NULL, &sz, &running);
    a.mSelector = kAudioDevicePropertyNominalSampleRate;
    AudioObjectGetPropertyData(gAudio, &a, 0, NULL, &szr, &sr);
    logf_("audio: MPC Touch Audio (%u) %s — alive %u, running %u, %.0f Hz", gAudio, what, alive, running, sr);
    if (!alive) trigger("audio device not alive");
}
static void findAudio(void){
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz) != noErr) return;
    AudioObjectID ids[128]; if (sz > sizeof ids) sz = sizeof ids;
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    AudioObjectID found = 0;
    for (UInt32 i = 0; i < sz / sizeof(AudioObjectID); i++){
        CFStringRef name = NULL; UInt32 ns = sizeof name;
        AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &ns, &name) == noErr && name){
            char buf[128]; CFStringGetCString(name, buf, sizeof buf, kCFStringEncodingUTF8); CFRelease(name);
            if (strstr(buf, "MPC Touch")){ found = ids[i]; break; }
        }
    }
    if (found == gAudio) return;
    if (!found){ logf_("audio: MPC Touch Audio device ABSENT"); gAudio = 0; trigger("audio device absent"); return; }
    gAudio = found;
    AudioObjectPropertySelector sels[] = { kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioDevicePropertyNominalSampleRate };
    for (int i = 0; i < 3; i++){
        AudioObjectPropertyAddress pa = { sels[i], kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectID dev = found;
        AudioObjectAddPropertyListenerBlock(dev, &pa, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *addrs){
            (void)n; (void)addrs;
            if (dev == gAudio) audioLog("changed");
        });
    }
    audioLog("found");
}

// ---------- system log stream (separate thread) ----------
static atomic_int gRtaid, gOverload;
static void *syslogThread(void *arg){
    (void)arg;
    const char *cmd =
        "/usr/bin/log stream --style compact --level info --predicate '"
        "(process == \"kernel\" AND (eventMessage CONTAINS[c] \"MPC\" OR eventMessage CONTAINS \"SiS HID\" OR eventMessage CONTAINS[c] \"DisplayLink\" "
        "OR eventMessage CONTAINS[c] \"Billboard\" OR eventMessage CONTAINS[c] \"USB2.0 HUB\" OR eventMessage CONTAINS[c] \"overcurrent\" "
        "OR eventMessage CONTAINS[c] \"over-current\" OR eventMessage CONTAINS[c] \"dfu-util\")) "
        "OR (process == \"DisplayLinkUserAgent\" AND (messageType == error OR messageType == fault)) "
        "OR (process == \"coreaudiod\" AND (eventMessage CONTAINS \"RTAID\" OR eventMessage CONTAINS[c] \"overload\")) "
        "OR (process == \"usbaudiod\" AND messageType == error) "
        "OR (process == \"MIDIServer\" AND messageType == error) "
        "OR (process CONTAINS[c] \"dfu-util\")' 2>&1";
    for (;;){
        FILE *f = popen(cmd, "r");
        if (!f){ sleep(5); continue; }
        char line[1024];
        while (fgets(line, sizeof line, f)){
            size_t L = strlen(line); if (L && line[L-1] == '\n') line[--L] = 0;
            if (!L || !strncmp(line, "Filtering", 9) || !strncmp(line, "Timestamp", 9)) continue;
            if (strstr(line, "RTAID")){ atomic_fetch_add(&gRtaid, 1); continue; }
            if (strstr(line, "coreaudiod") && strcasestr(line, "overload")){
                if (atomic_fetch_add(&gOverload, 1) < 5) logf_("[syslog] %.300s", line);
                continue;
            }
            logf_("[syslog] %.300s", line);
            if (strstr(line, " kernel[") || strcasestr(line, "dfu-util")) trigger("kernel/dfu-util log line");
        }
        pclose(f);
        logf_("syslog stream ended; restarting in 5 s");
        sleep(5);
    }
    return NULL;
}

// ---------- tail the driver's and the app's logs ----------
typedef struct { char path[512]; const char *tag; off_t off; } Tail;
static Tail tails[2];
static void tailInit(Tail *t, const char *path, const char *tag){
    snprintf(t->path, sizeof t->path, "%s", path); t->tag = tag;
    struct stat st; t->off = stat(path, &st) == 0 ? st.st_size : 0;
}
static void tailPoll(Tail *t){
    struct stat st; if (stat(t->path, &st) != 0) return;
    if (st.st_size < t->off) t->off = 0;
    if (st.st_size == t->off) return;
    FILE *f = fopen(t->path, "r"); if (!f) return;
    fseeko(f, t->off, SEEK_SET);
    char line[1024];
    while (fgets(line, sizeof line, f)){
        size_t L = strlen(line); if (L && line[L-1] == '\n') line[--L] = 0;
        if (!L) continue;
        logf_("[%s] %s", t->tag, line);
        if (strcasestr(line, "left USB") || strcasestr(line, "removed") || strcasestr(line, "gone") || strcasestr(line, "error")
            || strcasestr(line, "offline") || strcasestr(line, "missing") || strcasestr(line, "closed")){
            char why[160]; snprintf(why, sizeof why, "%s: %.100s", t->tag, line); trigger(why);
        }
    }
    t->off = ftello(f);
    fclose(f);
}

// ---------- marks from `mpc_watch mark "text"` ----------
static char gMarkPath[512];
static atomic_bool gMarkPending;
static void onMarkSignal(void){
    FILE *f = fopen(gMarkPath, "r"); char text[256] = "(no text)";
    if (f){ if (fgets(text, sizeof text, f)){ size_t L = strlen(text); if (L && text[L-1] == '\n') text[L-1] = 0; } fclose(f); }
    logf_("==== MARK: %s ====", text);
    char why[200]; snprintf(why, sizeof why, "mark: %.180s", text); trigger(why);
}

// ---------- sleep / wake ----------
static io_connect_t gPowerRoot;
static void onPower(void *ref, io_service_t s, natural_t type, void *arg){
    (void)ref; (void)s;
    switch (type){
        case kIOMessageCanSystemSleep: IOAllowPowerChange(gPowerRoot, (long)arg); break;
        case kIOMessageSystemWillSleep: logf_("Mac going to sleep"); IOAllowPowerChange(gPowerRoot, (long)arg); break;
        case kIOMessageSystemHasPoweredOn: logf_("Mac woke"); break;
        default: break;
    }
}

// ---------- the 1 s tick ----------
static void tick(CFRunLoopTimerRef t, void *info){
    (void)t; (void)info;
    static double lastSummary = 0, lastClients = 0, lastDump = -100, afterDumpAt = 0;
    static int prevDisp = -1, prevUsb = -1;
    static double sumDl = 0, maxDl = 0, sumApp = 0, maxApp = 0, sumTd = 0, maxTd = 0; static int nSum = 0; static long midiSum[3];
    double now = now_s();

    Sample s = { .t = now };
    for (int k = 0; k < 3; k++){ s.midi[k] = atomic_exchange(&midiNow[k], 0); midiSum[k] += s.midi[k]; }
    s.dl = cpuOf(&procs[0], now); s.app = cpuOf(&procs[1], now); s.td = cpuOf(&procs[2], now);
    s.usb = (usbPresent(0x09E8, 0x0037) ? 1 : 0) | (usbPresent(0x09E8, 0x8001) ? 2 : 0) | (usbPresent(0x17E9, 0xFF00) ? 4 : 0);
    s.disp = mpcDisplayPresent();
    ring[ringNext] = s; ringNext = (ringNext + 1) % RING; if (ringCount < RING) ringCount++;

    if (prevDisp >= 0 && s.disp != prevDisp){ logf_("MPC display %s", s.disp ? "BACK" : "GONE"); trigger(s.disp ? "MPC display back" : "MPC display gone"); }
    if (prevUsb >= 0 && s.usb != prevUsb){ char a[4], b[4]; usbBits(prevUsb, a); usbBits(s.usb, b); logf_("MPC USB presence %s → %s", a, b); }
    prevDisp = s.disp; prevUsb = s.usb;

    if (s.dl >= 0){ sumDl += s.dl; if (s.dl > maxDl) maxDl = s.dl; }
    if (s.app >= 0){ sumApp += s.app; if (s.app > maxApp) maxApp = s.app; }
    if (s.td >= 0){ sumTd += s.td; if (s.td > maxTd) maxTd = s.td; }
    nSum++;

    tailPoll(&tails[0]); tailPoll(&tails[1]);
    if (atomic_exchange(&gMarkPending, false)) onMarkSignal();
    if (now - lastClients >= 2){ lastClients = now; snapshotClients(false); }

    if (atomic_load(&gTrigger) && now - lastDump >= 10){
        char why[200];
        pthread_mutex_lock(&logLock); snprintf(why, sizeof why, "%s", gTriggerWhy); pthread_mutex_unlock(&logLock);
        atomic_store(&gTrigger, false);
        lastDump = now; afterDumpAt = now + 20;
        dump(why, 60);
    }
    if (afterDumpAt && now >= afterDumpAt){ afterDumpAt = 0; dump("aftermath", 20); }

    if (now - lastSummary >= 60){
        if (lastSummary){
            char u[4]; usbBits(s.usb, u);
            logf_("minute: midi %ld/%ld/%ld · DL avg %.1f max %.1f · app avg %.1f max %.1f · touchd avg %.1f max %.1f · RTAID %d · usb %s · disp %d",
                  midiSum[0], midiSum[1], midiSum[2], sumDl / nSum, maxDl, sumApp / nSum, maxApp, sumTd / nSum, maxTd,
                  atomic_exchange(&gRtaid, 0), u, s.disp);
        }
        lastSummary = now; sumDl = maxDl = sumApp = maxApp = sumTd = maxTd = 0; nSum = 0; memset(midiSum, 0, sizeof midiSum);
        atomic_store(&gOverload, 0);
    }
}

static int markCommand(const char *text){
    char path[512]; snprintf(path, sizeof path, "%s/Library/Logs/mpc_watch.mark", getenv("HOME"));
    FILE *f = fopen(path, "w"); if (!f){ perror(path); return 1; }
    fprintf(f, "%s\n", text); fclose(f);
    pid_t pids[8192]; int n = proc_listallpids(pids, sizeof pids), sent = 0;
    for (int i = 0; i < n; i++){
        char nm[64] = "";
        if (pids[i] != getpid() && proc_name(pids[i], nm, sizeof nm) > 0 && !strcmp(nm, "mpc_watch")){ kill(pids[i], SIGUSR1); sent++; }
    }
    printf(sent ? "marked: %s\n" : "no running mpc_watch found (mark saved: %s)\n", text);
    return sent ? 0 : 1;
}

int main(int argc, char **argv){
    if (argc >= 2 && !strcmp(argv[1], "mark")) return markCommand(argc >= 3 ? argv[2] : "(mark)");
    setvbuf(stdout, NULL, _IOLBF, 0);
    mach_timebase_info(&gTb);
    snprintf(gMarkPath, sizeof gMarkPath, "%s/Library/Logs/mpc_watch.mark", getenv("HOME"));
    logf_("==== mpc_watch started (read-only) ====");

    // CoreMIDI client first: its property constants don't exist before a client does.
    MIDIClientCreate(CFSTR("mpc_watch"), midiNotify, NULL, &gMidi);
    gMidiOffline = -2; connectMidi();

    refreshMpcBus();
    logf_("MPC is on USB bus 0x%02lx", gMpcBus);
    gNotify = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(gNotify), kCFRunLoopDefaultMode);
    IOServiceAddMatchingNotification(gNotify, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), onUsbAdd, NULL, &gAddIter);
    usbEvent(gAddIter, true, true);
    IOServiceAddMatchingNotification(gNotify, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), onUsbRemove, NULL, &gRemIter);
    usbEvent(gRemIter, false, true);
    snapshotClients(true);

    findAudio();
    AudioObjectPropertyAddress devs = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &devs, dispatch_get_main_queue(), ^(UInt32 n, const AudioObjectPropertyAddress *a){ (void)n; (void)a; findAudio(); });

    char p1[512], p2[512];
    snprintf(p1, sizeof p1, "%s/Library/Logs/mpc_touchd.log", getenv("HOME"));
    snprintf(p2, sizeof p2, "%s/Library/Logs/MPC Touch Instrument/controller.log", getenv("HOME"));
    tailInit(&tails[0], p1, "touchd"); tailInit(&tails[1], p2, "app");

    IONotificationPortRef pwrPort = NULL; io_object_t pwrNotifier = 0;
    gPowerRoot = IORegisterForSystemPower(NULL, &pwrPort, onPower, &pwrNotifier);
    if (gPowerRoot) CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(pwrPort), kCFRunLoopDefaultMode);

    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t ms = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(ms, ^{ atomic_store(&gMarkPending, true); });
    dispatch_resume(ms);

    pthread_t th; pthread_create(&th, NULL, syslogThread, NULL);

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, now_s() + 1, 1.0, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
    CFRunLoopRun();
    return 0;
}
