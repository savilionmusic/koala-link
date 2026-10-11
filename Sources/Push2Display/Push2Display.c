#include "Push2Display.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <string.h>

#define PUSH2_VENDOR 0x2982
#define PUSH2_PRODUCT 0x1967
#define PUSH2_CHUNK 16384

static IOUSBInterfaceInterface300 **gIntf = NULL;
static UInt8 gPipe = 0;
static uint8_t gFrame[PUSH2_FRAME_BYTES];

static io_service_t displayInterface(void) {   // caller releases
    CFMutableDictionaryRef m = IOServiceMatching("IOUSBHostInterface");
    if (!m) return 0;
    int v = PUSH2_VENDOR, p = PUSH2_PRODUCT, cfg = 1, n = 0;
    CFNumberRef vn = CFNumberCreate(NULL, kCFNumberIntType, &v), pn = CFNumberCreate(NULL, kCFNumberIntType, &p);
    CFNumberRef cn = CFNumberCreate(NULL, kCFNumberIntType, &cfg), nn = CFNumberCreate(NULL, kCFNumberIntType, &n);
    // USB interface matching needs vendor + product + configuration + interface together.
    CFDictionarySetValue(m, CFSTR("idVendor"), vn);
    CFDictionarySetValue(m, CFSTR("idProduct"), pn);
    CFDictionarySetValue(m, CFSTR("bConfigurationValue"), cn);
    CFDictionarySetValue(m, CFSTR("bInterfaceNumber"), nn);
    CFRelease(vn); CFRelease(pn); CFRelease(cn); CFRelease(nn);
    return IOServiceGetMatchingService(kIOMainPortDefault, m);
}

int push2_display_is_open(void) { return gIntf != NULL && gPipe != 0; }

int push2_display_open(void) {
    if (push2_display_is_open()) return 0;
    io_service_t service = displayInterface();
    if (!service) return -1;
    IOCFPlugInInterface **plug = NULL; SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != kIOReturnSuccess || !plug) return -3;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (LPVOID *)&gIntf);
    (*plug)->Release(plug);
    if (!gIntf) return -3;
    // Never seize: if Live (or anything else) has the display, leave it alone.
    kr = (*gIntf)->USBInterfaceOpen(gIntf);
    if (kr != kIOReturnSuccess) {
        (*gIntf)->Release(gIntf); gIntf = NULL;
        return kr == kIOReturnExclusiveAccess ? -2 : -3;
    }
    UInt8 count = 0; gPipe = 0;
    (*gIntf)->GetNumEndpoints(gIntf, &count);
    for (UInt8 p = 1; p <= count && !gPipe; p++) {
        UInt8 direction, number, type, interval; UInt16 size;
        if ((*gIntf)->GetPipeProperties(gIntf, p, &direction, &number, &type, &size, &interval) == kIOReturnSuccess
            && direction == kUSBOut && type == kUSBBulk && number == 1) gPipe = p;
    }
    if (!gPipe) { push2_display_close(); return -3; }
    return 0;
}

void push2_display_close(void) {
    if (!gIntf) return;
    (*gIntf)->USBInterfaceClose(gIntf);
    (*gIntf)->Release(gIntf);
    gIntf = NULL; gPipe = 0;
}

void push2_frame_encode(const uint16_t *pixels, uint8_t *out) {
    static const uint8_t pattern[4] = { 0xE7, 0xF3, 0xE7, 0xFF };
    for (int y = 0; y < PUSH2_HEIGHT; y++) {
        uint8_t *line = out + y * PUSH2_LINE_BYTES;
        const uint16_t *row = pixels + y * PUSH2_WIDTH;
        for (int x = 0; x < PUSH2_WIDTH; x++) {
            line[x * 2] = (uint8_t)(row[x] & 0xFF);
            line[x * 2 + 1] = (uint8_t)(row[x] >> 8);
        }
        memset(line + PUSH2_WIDTH * 2, 0, PUSH2_LINE_BYTES - PUSH2_WIDTH * 2);
        for (int i = 0; i < PUSH2_LINE_BYTES; i++) line[i] ^= pattern[i & 3];
    }
}

int push2_display_send(const uint16_t *pixels) {
    if (!push2_display_is_open()) return -1;
    static uint8_t header[16] = { 0xFF, 0xCC, 0xAA, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    push2_frame_encode(pixels, gFrame);
    IOReturn kr = (*gIntf)->WritePipeTO(gIntf, gPipe, header, sizeof header, 500, 1000);
    for (int offset = 0; kr == kIOReturnSuccess && offset < PUSH2_FRAME_BYTES; offset += PUSH2_CHUNK)
        kr = (*gIntf)->WritePipeTO(gIntf, gPipe, gFrame + offset, PUSH2_CHUNK, 500, 1000);
    if (kr != kIOReturnSuccess) {
        // A stalled pipe gets one clear; anything else (unplugged) closes, and the app reopens later.
        if (kr == kIOUSBPipeStalled) { (*gIntf)->ClearPipeStallBothEnds(gIntf, gPipe); return -1; }
        push2_display_close();
        return -1;
    }
    return 0;
}

void push2_convert_rgba(const uint8_t *rgba, uint16_t *out, int count) {
    for (int i = 0; i < count; i++) {
        const uint8_t *p = rgba + i * 4;
        out[i] = (uint16_t)((p[0] >> 3) | ((p[1] >> 2) << 5) | ((p[2] >> 3) << 11));
    }
}

void push2_wave_columns(const float *lows, const float *highs, int count, double left, double span,
                        int columns, float *outLow, float *outHigh) {
    for (int c = 0; c < columns; c++) {
        outLow[c] = 0; outHigh[c] = 0;
        if (count <= 0) continue;
        double a = (left + span * c / columns) * count, b = (left + span * (c + 1) / columns) * count;
        // Include the previous bucket so sparse, zoomed-in columns stay connected (as the touch screen does).
        int i0 = (int)a - 1, i1 = (int)b + 1;
        if (i0 < 0) i0 = 0;
        if (i1 > count) i1 = count;
        if (i1 <= i0) i1 = i0 + 1 <= count ? i0 + 1 : count;
        float lo = 0, hi = 0;
        for (int i = i0; i < i1; i++) { if (lows[i] < lo) lo = lows[i]; if (highs[i] > hi) hi = highs[i]; }
        outLow[c] = lo; outHigh[c] = hi;
    }
}
