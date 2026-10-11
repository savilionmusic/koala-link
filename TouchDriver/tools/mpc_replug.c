// mpc_replug.c — software "unplug and plug back in" for the MPC Touch.
//
//   mpc_replug            re-enumerate the controller only (09e8:0037: pads, knobs, audio, MIDI)
//   mpc_replug screen     re-enumerate the screen chip only (DisplayLink 17e9:ff00)
//   mpc_replug all        re-enumerate the MPC's internal hub (controller + touch panel + screen);
//                         macOS normally refuses this (the kernel hub driver owns the hub)
//
// "all" only acts if every device on that hub belongs to the MPC (Akai 09e8 or
// DisplayLink 17e9), so it can never reset a dock or another hub by mistake.
//
// Build: clang -O2 -Wall -Wno-deprecated-declarations -framework IOKit -framework CoreFoundation mpc_replug.c -o mpc_replug
#include <stdio.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

static long regNum(io_registry_entry_t e, CFStringRef key){
    long x = -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, key, NULL, 0);
    if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &x);
    if (v) CFRelease(v);
    return x;
}
static bool conformsHostDevice(io_registry_entry_t e){ return IOObjectConformsTo(e, "IOUSBHostDevice"); }

/// Nearest IOUSBHostDevice above `e` (the hub it hangs off). Caller releases.
static io_service_t parentHubDevice(io_service_t e){
    io_registry_entry_t cur = e; IOObjectRetain(cur);
    for (int i = 0; i < 6; i++){
        io_registry_entry_t p = 0;
        if (IORegistryEntryGetParentEntry(cur, kIOServicePlane, &p) != KERN_SUCCESS){ IOObjectRelease(cur); return 0; }
        IOObjectRelease(cur); cur = p;
        if (conformsHostDevice(cur)) return cur;
    }
    IOObjectRelease(cur); return 0;
}
/// True if every USB device directly below `hub` is Akai or DisplayLink.
static bool hubIsMpcOnly(io_service_t hub){
    long hubLoc = regNum(hub, CFSTR("locationID"));
    io_iterator_t it = 0; int n = 0; bool ok = true;
    IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it);
    io_service_t d;
    while ((d = IOIteratorNext(it))){
        io_service_t p = parentHubDevice(d);
        if (p && regNum(p, CFSTR("locationID")) == hubLoc && IOObjectIsEqualTo(p, hub)){
            long vid = regNum(d, CFSTR("idVendor")), pid = regNum(d, CFSTR("idProduct"));
            printf("  on this hub: %04lx:%04lx @ 0x%08lx\n", vid, pid, regNum(d, CFSTR("locationID")));
            if (vid != 0x09E8 && vid != 0x17E9) ok = false;
            n++;
        }
        if (p) IOObjectRelease(p);
        IOObjectRelease(d);
    }
    IOObjectRelease(it);
    return ok && n > 0;
}
static int reenumerate(io_service_t svc, const char *what){
    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    IOUSBDeviceInterface300 **dev = NULL;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score) != kIOReturnSuccess || !plug){
        printf("%s: no device interface\n", what); return 1;
    }
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300), (LPVOID *)&dev);
    (*plug)->Release(plug);
    if (!dev){ printf("%s: no device interface\n", what); return 1; }
    IOReturn kr = (*dev)->USBDeviceOpen(dev);
    const char *how = "open";
    if (kr == kIOReturnExclusiveAccess){ kr = (*dev)->USBDeviceOpenSeize(dev); how = "seize"; }
    if (kr != kIOReturnSuccess){ printf("%s: open failed 0x%x\n", what, kr); (*dev)->Release(dev); return 1; }
    kr = (*dev)->USBDeviceReEnumerate(dev, 0);
    printf("%s: re-enumerate (%s) → 0x%x%s\n", what, how, kr, kr == kIOReturnSuccess ? " ok" : "");
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return kr == kIOReturnSuccess ? 0 : 1;
}

int main(int argc, char **argv){
    bool all = argc > 1 && !strcmp(argv[1], "all");
    bool screen = argc > 1 && !strcmp(argv[1], "screen");
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostDevice");
    int v = screen ? 0x17E9 : 0x09E8, p = screen ? 0xFF00 : 0x0037;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v), pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR("idVendor"), vn); CFDictionarySetValue(m, CFSTR("idProduct"), pn);
    CFRelease(vn); CFRelease(pn);
    io_service_t ctrl = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!ctrl){ printf("MPC Touch %s not found on USB\n", screen ? "screen (17e9:ff00)" : "controller (09e8:0037)"); return 1; }
    int rc;
    if (screen) rc = reenumerate(ctrl, "screen 17e9:ff00");
    else if (!all) rc = reenumerate(ctrl, "controller 09e8:0037");
    else {
        io_service_t hub = parentHubDevice(ctrl);
        if (!hub){ printf("no hub above the controller\n"); IOObjectRelease(ctrl); return 1; }
        printf("MPC hub @ 0x%08lx\n", regNum(hub, CFSTR("locationID")));
        if (!hubIsMpcOnly(hub)){ printf("refusing: that hub has non-MPC devices on it\n"); IOObjectRelease(hub); IOObjectRelease(ctrl); return 1; }
        rc = reenumerate(hub, "MPC internal hub");
        IOObjectRelease(hub);
    }
    IOObjectRelease(ctrl);
    return rc;
}
