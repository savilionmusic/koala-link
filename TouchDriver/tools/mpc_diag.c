// mpc_diag.c — read-only snapshot of everything the MPC Touch exposes to macOS.
// Sends nothing, claims nothing, injects nothing. Safe to run next to the daemon.
//
//   USB   : Akai (09e8) and DisplayLink (17e9) devices, their interfaces and the
//           driver objects attached below each one.
//   HID   : what IOHIDManager sees from Akai — whether macOS's own HID driver has
//           bound the SiS touch panel (it can't while a raw-USB reader seizes it).
//   MIDI  : every CoreMIDI device/entity/endpoint, including hidden (Private) ones,
//           so wake-port matching is based on facts.
//   Screen: active displays and their bounds.
//
// Build: clang -O2 -Wall -framework IOKit -framework CoreFoundation \
//        -framework CoreGraphics -framework CoreMIDI mpc_diag.c -o mpc_diag
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <CoreMIDI/CoreMIDI.h>

static void cfstr(CFTypeRef v, char *out, size_t n){
    out[0] = 0;
    if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString(v, out, (CFIndex)n, kCFStringEncodingUTF8);
}
static long cfnum(CFTypeRef v){
    long x = -1;
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &x);
    return x;
}
static long regNum(io_registry_entry_t e, const char *key){
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, NULL, 0);
    CFRelease(k);
    long x = cfnum(v); if (v) CFRelease(v); return x;
}
static void regStr(io_registry_entry_t e, const char *key, char *out, size_t n){
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, k, NULL, 0);
    CFRelease(k);
    cfstr(v, out, n); if (v) CFRelease(v);
}
static void midiStr(MIDIObjectRef o, CFStringRef prop, char *out, size_t n){
    CFStringRef s = NULL; out[0] = 0;
    if (MIDIObjectGetStringProperty(o, prop, &s) == noErr && s){ cfstr(s, out, n); CFRelease(s); }
}

static void dumpChildren(io_registry_entry_t e, int depth){
    io_iterator_t it = 0;
    if (IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) != KERN_SUCCESS) return;
    io_registry_entry_t c;
    while ((c = IOIteratorNext(it))){
        io_name_t cls; IOObjectGetClass(c, cls);
        char name[128] = ""; regStr(c, "USB Interface Name", name, sizeof name);
        long ifn = regNum(c, "bInterfaceNumber"), icls = regNum(c, "bInterfaceClass");
        printf("%*s- %s", depth*2, "", cls);
        if (ifn >= 0) printf("  if#%ld class=0x%02lx", ifn, icls);
        if (name[0]) printf("  \"%s\"", name);
        printf("\n");
        if (depth < 4) dumpChildren(c, depth + 1);
        IOObjectRelease(c);
    }
    IOObjectRelease(it);
}

static void usb(void){
    printf("== USB (Akai 09e8, DisplayLink 17e9) ==\n");
    io_iterator_t it = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
    io_service_t d; int found = 0;
    while ((d = IOIteratorNext(it))){
        long vid = regNum(d, "idVendor"), pid = regNum(d, "idProduct");
        if (vid == 0x09E8 || vid == 0x17E9){
            char prod[128] = "", ven[128] = "";
            regStr(d, "USB Product Name", prod, sizeof prod);
            regStr(d, "USB Vendor Name", ven, sizeof ven);
            printf("%04lx:%04lx  %s / %s  location=0x%08lx\n", vid, pid, ven, prod, regNum(d, "locationID"));
            dumpChildren(d, 1);
            found++;
        }
        IOObjectRelease(d);
    }
    IOObjectRelease(it);
    if (!found) printf("(none)\n");
}

static void hid(void){
    printf("\n== HID devices from Akai (IOHIDManager, not opened) ==\n");
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int v = 0x09E8; CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vn); CFRelease(vn);
    IOHIDManagerSetDeviceMatching(m, match); CFRelease(match);
    CFSetRef set = IOHIDManagerCopyDevices(m);
    if (!set || CFSetGetCount(set) == 0) printf("(none — SiS absent, asleep, or seized by a raw-USB reader)\n");
    else {
        CFIndex n = CFSetGetCount(set); const void *vals[64]; if (n > 64) n = 64;
        CFSetGetValues(set, vals);
        for (CFIndex i = 0; i < n; i++){
            IOHIDDeviceRef dev = (IOHIDDeviceRef)vals[i];
            char prod[128] = "", transport[32] = "";
            cfstr(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey)), prod, sizeof prod);
            cfstr(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey)), transport, sizeof transport);
            printf("%04lx:%04lx \"%s\" %s  primary %02lx:%02lx  in=%ld out=%ld feat=%ld\n",
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey))),
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey))), prod, transport,
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsagePageKey))),
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsageKey))),
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxInputReportSizeKey))),
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxOutputReportSizeKey))),
                   cfnum(IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey))));
            CFArrayRef pairs = IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
            if (pairs) for (CFIndex j = 0; j < CFArrayGetCount(pairs); j++){
                CFDictionaryRef p = CFArrayGetValueAtIndex(pairs, j);
                printf("    usage pair %02lx:%02lx\n",
                       cfnum(CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsagePageKey))),
                       cfnum(CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsageKey))));
            }
        }
    }
    if (set) CFRelease(set);
    CFRelease(m);
}

static void endpointLine(const char *kind, MIDIEndpointRef e){
    char name[128], disp[160], manu[128];
    midiStr(e, kMIDIPropertyName, name, sizeof name);
    midiStr(e, kMIDIPropertyDisplayName, disp, sizeof disp);
    midiStr(e, kMIDIPropertyManufacturer, manu, sizeof manu);
    SInt32 priv = 0, off = 0;
    MIDIObjectGetIntegerProperty(e, kMIDIPropertyPrivate, &priv);
    MIDIObjectGetIntegerProperty(e, kMIDIPropertyOffline, &off);
    printf("      %s name=\"%s\" display=\"%s\" manufacturer=\"%s\" private=%d offline=%d\n",
           kind, name, disp, manu, (int)priv, (int)off);
}

static void midi(void){
    printf("\n== CoreMIDI devices (incl. hidden endpoints) ==\n");
    MIDIClientRef c = 0;
    OSStatus st = MIDIClientCreate(CFSTR("mpc-diag"), NULL, NULL, &c);
    if (st){ printf("MIDIClientCreate failed: %d\n", (int)st); return; }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
    ItemCount nd = MIDIGetNumberOfDevices(); int shown = 0;
    for (ItemCount i = 0; i < nd; i++){
        MIDIDeviceRef dev = MIDIGetDevice(i);
        char name[128], manu[128], model[128], drv[128];
        midiStr(dev, kMIDIPropertyName, name, sizeof name);
        midiStr(dev, kMIDIPropertyManufacturer, manu, sizeof manu);
        midiStr(dev, kMIDIPropertyModel, model, sizeof model);
        midiStr(dev, kMIDIPropertyDriverOwner, drv, sizeof drv);
        SInt32 off = 0; MIDIObjectGetIntegerProperty(dev, kMIDIPropertyOffline, &off);
        if (!(strcasestr(manu, "akai") || strcasestr(name, "mpc") || strcasestr(model, "mpc"))) continue;
        shown++;
        printf("device \"%s\" manufacturer=\"%s\" model=\"%s\" driver=\"%s\" offline=%d\n", name, manu, model, drv, (int)off);
        for (ItemCount j = 0; j < MIDIDeviceGetNumberOfEntities(dev); j++){
            MIDIEntityRef ent = MIDIDeviceGetEntity(dev, j);
            char en[128]; SInt32 epriv = 0;
            midiStr(ent, kMIDIPropertyName, en, sizeof en);
            MIDIObjectGetIntegerProperty(ent, kMIDIPropertyPrivate, &epriv);
            printf("    entity \"%s\" private=%d\n", en, (int)epriv);
            for (ItemCount k = 0; k < MIDIEntityGetNumberOfSources(ent); k++) endpointLine("src ", MIDIEntityGetSource(ent, k));
            for (ItemCount k = 0; k < MIDIEntityGetNumberOfDestinations(ent); k++) endpointLine("dest", MIDIEntityGetDestination(ent, k));
        }
    }
    if (!shown) printf("(no Akai/MPC device in the CoreMIDI setup)\n");
    printf("-- flat destination list (what v1/v2 search) --\n");
    for (ItemCount i = 0; i < MIDIGetNumberOfDestinations(); i++){
        MIDIEndpointRef e = MIDIGetDestination(i);
        char name[128], manu[128];
        midiStr(e, kMIDIPropertyName, name, sizeof name);
        midiStr(e, kMIDIPropertyManufacturer, manu, sizeof manu);
        printf("  [%lu] name=\"%s\" manufacturer=\"%s\"\n", (unsigned long)i, name, manu);
    }
    MIDIClientDispose(c);
}

static void screens(void){
    printf("\n== Displays ==\n");
    CGDirectDisplayID ids[16]; uint32_t n = 0; CGGetActiveDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++){
        CGRect b = CGDisplayBounds(ids[i]);
        printf("display %u  %.0fx%.0f @ %.0f,%.0f%s  vendor=0x%x model=0x%x\n", ids[i], b.size.width, b.size.height,
               b.origin.x, b.origin.y, CGDisplayIsMain(ids[i]) ? "  (main)" : "",
               CGDisplayVendorNumber(ids[i]), CGDisplayModelNumber(ids[i]));
    }
}

int main(void){
    usb(); hid(); midi(); screens();
    return 0;
}
