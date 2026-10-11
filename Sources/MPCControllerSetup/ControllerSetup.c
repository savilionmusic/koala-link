// Adapted from outputs/mpc-touch-research/controller_init.c (approved sequence).
#define MPC_CONTROLLER_INIT_LIBRARY
#include "ControllerSetup.h"
// Bounded MPC Touch research initialization; no persistent service.
// Mirrors the saved Koala startup commands. Sends only to Public/Private on
// the MPC Touch device, never to the external MIDI Port entity.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMIDI/CoreMIDI.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

// The application owns this session for its whole lifetime, as the verified
// bank helper does. Creation/disposal is not repeated for each LED update.
// All calls are serialized by MIDIInput.controllerQueue.
static MIDIClientRef controller_client;
static MIDIPortRef controller_port;

void controller_shutdown(void) {
    if (controller_port) MIDIPortDispose(controller_port);
    if (controller_client) MIDIClientDispose(controller_client);
    controller_port = 0; controller_client = 0;
}

static void get_name(MIDIObjectRef object, char *buf, size_t n) {
    CFStringRef value = NULL;
    buf[0] = 0;
    if (MIDIObjectGetStringProperty(object, kMIDIPropertyName, &value) == noErr && value) {
        CFStringGetCString(value, buf, (CFIndex)n, kCFStringEncodingUTF8);
        CFRelease(value);
    }
}

static int send_bytes(MIDIPortRef port, MIDIEndpointRef destination,
                      const char *name, const Byte *bytes, size_t count) {
    union { MIDIPacketList list; Byte bytes[1024]; } buffer;
    MIDIPacket *packet = MIDIPacketListInit(&buffer.list);
    if (!MIDIPacketListAdd(&buffer.list, sizeof(buffer), packet, 0, count, bytes)) return 1;
    OSStatus status = MIDISend(port, destination, &buffer.list);
    printf("out=\"%s\" status=%d bytes=", name, (int)status);
    for (size_t i = 0; i < count; ++i) printf("%02x%s", bytes[i], i + 1 == count ? "\n" : " ");
    fflush(stdout);
    usleep(20000);
    return status != noErr;
}

static int find_destinations(MIDIEndpointRef *public_out, MIDIEndpointRef *private_out) {
    *public_out = 0; *private_out = 0;
    for (ItemCount d = 0; d < MIDIGetNumberOfDevices(); ++d) {
        MIDIDeviceRef device = MIDIGetDevice(d);
        char name[256];
        get_name(device, name, sizeof(name));
        if (strcmp(name, "MPC Touch") != 0) continue;
        for (ItemCount e = 0; e < MIDIDeviceGetNumberOfEntities(device); ++e) {
            MIDIEntityRef entity = MIDIDeviceGetEntity(device, e);
            get_name(entity, name, sizeof(name));
            if (!MIDIEntityGetNumberOfDestinations(entity)) continue;
            if (strcmp(name, "Public") == 0) *public_out = MIDIEntityGetDestination(entity, 0);
            if (strcmp(name, "Private") == 0) *private_out = MIDIEntityGetDestination(entity, 0);
        }
    }
    return *public_out && *private_out ? 0 : 1;
}

static int controller_send(int pad_bank, int qlink_bank, int initialize) {
    if (pad_bank < 0 || pad_bank > 3 || qlink_bank < 0 || qlink_bank > 3) return 1;
    MIDIEndpointRef public_out = 0, private_out = 0;
    for (ItemCount d = 0; d < MIDIGetNumberOfDevices(); ++d) {
        MIDIDeviceRef device = MIDIGetDevice(d);
        char name[256];
        get_name(device, name, sizeof(name));
        if (strcmp(name, "MPC Touch") != 0) continue;
        for (ItemCount e = 0; e < MIDIDeviceGetNumberOfEntities(device); ++e) {
            MIDIEntityRef entity = MIDIDeviceGetEntity(device, e);
            get_name(entity, name, sizeof(name));
            if (!MIDIEntityGetNumberOfDestinations(entity)) continue;
            if (strcmp(name, "Public") == 0) public_out = MIDIEntityGetDestination(entity, 0);
            if (strcmp(name, "Private") == 0) private_out = MIDIEntityGetDestination(entity, 0);
        }
    }
    if (!public_out || !private_out) {
        fprintf(stderr, "MPC Touch Public/Private destination unavailable\n");
        return 1;
    }
    if (!controller_client) {
        OSStatus status = MIDIClientCreate(CFSTR("MPC Touch controller session"), NULL, NULL, &controller_client);
        if (status != noErr) { controller_client = 0; return 1; }
        status = MIDIOutputPortCreate(controller_client, CFSTR("MPC Touch controller output"), &controller_port);
        if (status != noErr) { controller_shutdown(); return 1; }
    }
    MIDIPortRef port = controller_port;

    const Byte unlock[] = {0xf0,0x47,0x7f,0x37,0x62,0x00,0x01,0x65,0xf7};
    const Byte gate[] = {0xf0,0x47,0x00,0x37,0x64,0x00,0x01,0x01,0xf7};
    const Byte backlight[] = {0xf0,0x47,0x00,0x37,0x64,0x00,0x03,0x00,0x01,0x01,0xf7};
    int failed = 0;
    if (initialize) {
    failed |= send_bytes(port, public_out, "Public", unlock, sizeof(unlock));
    failed |= send_bytes(port, public_out, "Public", gate, sizeof(gate));
    failed |= send_bytes(port, public_out, "Public", backlight, sizeof(backlight));

    const Byte boot[][2] = {{0x31,1},{0x34,2},{0x43,2},{0x7a,1},{0x36,1},
                            {0x52,2},{0x51,1},{0x49,1},{0x50,1},{0x53,1},{0x35,1}};
    for (size_t i = 0; i < sizeof(boot)/sizeof(boot[0]); ++i) {
        Byte cc[] = {0xb0, boot[i][0], boot[i][1]};
        failed |= send_bytes(port, public_out, "Public", cc, sizeof(cc));
    }
    }
    // Indicator baseline for selected banks. This does not implement selection;
    // bank state and message remapping belong to the future controller layer.
    for (unsigned p = 0; p < 2; ++p) {
        MIDIEndpointRef destination = p ? private_out : public_out;
        const char *name = p ? "Private" : "Public";
        for (unsigned i = 0; i < 4; ++i) {
            Byte pad[] = {0xb0,(Byte)(0x23+i),(Byte)(i == (unsigned)pad_bank ? 3 : 0)};
            Byte qlink[] = {0xb0,(Byte)(0x5a+i),(Byte)(i == (unsigned)qlink_bank ? 2 : 0)};
            failed |= send_bytes(port, destination, name, pad, sizeof(pad));
            failed |= send_bytes(port, destination, name, qlink, sizeof(qlink));
        }
    }
    printf("initialization_complete send_errors=%d\n", failed);
    return failed ? 1 : 0;
}

int controller_initialize(int pad_bank, int qlink_bank) {
    return controller_send(pad_bank, qlink_bank, 1);
}
int controller_refresh_banks(int pad_bank, int qlink_bank) {
    return controller_send(pad_bank, qlink_bank, 0);
}
// Opt-in experiment: MPC Software sets its controllers' Q-Link values with
// Ch. 1 CC 0x10+knob (LiveXplore captures of the Live/X). If the Touch honours
// it, a knob re-centred to 64 can never reach its 0/127 stop.
int controller_send_qlink_value(int knob, int value) {
    if (knob < 0 || knob > 3 || value < 0 || value > 127 || !controller_port) return 1;
    MIDIEndpointRef public_out = 0, private_out = 0;
    if (find_destinations(&public_out, &private_out)) return 1;
    // Public only: a burst of these on the Private port was followed by the
    // controller's MIDI and audio locking up (2026-09-27, no USB re-enumeration).
    Byte cc[] = {0xb0, (Byte)(0x10 + knob), (Byte)value};
    return send_bytes(controller_port, public_out, "Public", cc, sizeof(cc));
}

// Button LED in the same `B0 note value` form the accepted startup uses for
// Shift, Play, Rec… (0 off, 1 dim, 2 lit). Used for FULL LEVEL (0x27) and 16 LEVEL (0x28).
int controller_set_button_light(int note, int value) {
    if (note < 0 || note > 127 || value < 0 || value > 127 || !controller_port) return 1;
    MIDIEndpointRef public_out = 0, private_out = 0;
    if (find_destinations(&public_out, &private_out)) return 1;
    // Public only, exactly like the accepted startup's button LEDs; nothing
    // undocumented goes to the Private port.
    Byte cc[] = {0xb0, (Byte)note, (Byte)value};
    return send_bytes(controller_port, public_out, "Public", cc, sizeof(cc));
}

#ifndef MPC_CONTROLLER_INIT_LIBRARY
int main(void) { return controller_initialize(0, 0); }
#endif
