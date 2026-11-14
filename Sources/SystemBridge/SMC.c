#include "SystemBridge.h"
#include <IOKit/IOKitLib.h>
#include <string.h>
#include <math.h>

// AppleSMC's read-only user client protocol. Unsupported keys remain absent.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCLimits;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key; SMCVersion version; SMCLimits limits; SMCKeyInfo info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} SMCRequest;
static io_connect_t connection = 0;
static char keys[2048][5]; static int key_count = -1;
static uint32_t fourcc(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 | (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}
static void unpack(uint32_t v, char *s) {
    for (int i = 0; i < 4; i++) s[i] = (char)(v >> (24 - i * 8)); s[4] = 0;
}
static int call(SMCRequest *in, SMCRequest *out) {
    size_t size = sizeof(*out); memset(out, 0, size);
    return IOConnectCallStructMethod(connection, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS && out->result == 0;
}
static int read_key(const char *key, MSSensor *sensor) {
    SMCRequest in = {0}, out = {0}; in.key = fourcc(key); in.command = 9;
    if (!call(&in, &out) || out.info.size == 0 || out.info.size > 32) return 0;
    in.info = out.info; in.command = 5;
    if (!call(&in, &out)) return 0;
    memcpy(sensor->key, key, 5); unpack(in.info.type, sensor->type);
    uint8_t *b = out.bytes;
    if (strcmp(sensor->type, "flt ") == 0 && in.info.size == 4) {
        float f; memcpy(&f, b, 4); sensor->value = f;
    } else if (strcmp(sensor->type, "sp78") == 0) {
        sensor->value = (int16_t)((b[0] << 8) | b[1]) / 256.0;
    } else if (strcmp(sensor->type, "fpe2") == 0) {
        sensor->value = ((b[0] << 8) | b[1]) / 4.0;
    } else if (strcmp(sensor->type, "ui8 ") == 0) sensor->value = b[0];
    else if (strcmp(sensor->type, "ui16") == 0) sensor->value = (b[0] << 8) | b[1];
    else if (strcmp(sensor->type, "ui32") == 0) sensor->value = fourcc((char *)b);
    else return 0;
    return isfinite(sensor->value);
}
static int open_smc(void) {
    if (connection) return 1;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service); return result == KERN_SUCCESS;
}
int ms_sensors(MSSensor *output, int capacity) {
    if (!open_smc()) return -1;
    if (key_count < 0) {
        key_count = 0; MSSensor total = {0};
        if (!read_key("#KEY", &total)) { key_count = -1; return -1; }
        int count = total.value; if (count > 30000) count = 30000;
        for (int i = 0; i < count && key_count < 2048; i++) {
            SMCRequest in = {0}, out = {0}; in.command = 8; in.index = i;
            if (!call(&in, &out)) continue;
            char key[5]; unpack(out.key, key);
            if (key[0] == 'T' || key[0] == 'P' || (key[0] == 'F' && key[2] == 'A' && key[3] == 'c'))
                memcpy(keys[key_count++], key, 5);
        }
    }
    int count = 0;
    for (int i = 0; i < key_count && count < capacity; i++) {
        MSSensor sensor = {0};
        if (!read_key(keys[i], &sensor)) continue;
        if (sensor.key[0] == 'T' && (sensor.value < 0 || sensor.value > 150)) continue;
        if (sensor.key[0] == 'P' && (sensor.value < 0 || sensor.value > 2000 || strcmp(sensor.type, "flt ") != 0)) continue;
        output[count++] = sensor;
    }
    return count;
}
void ms_smc_close(void) {
    if (connection) IOServiceClose(connection);
    connection = 0; key_count = -1;
}
