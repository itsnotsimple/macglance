#include "CSensors.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout of the message the AppleSMC driver expects. Apple never documented it;
// this is the long-known reverse-engineered version (smcFanControl, Stats, iStat).
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

enum { kSMCUserClientCall = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static io_connect_t connection;

static uint32_t fourcc(const char *s) {
    return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3];
}

static bool call(SMCParam *in, SMCParam *out) {
    size_t size = sizeof(SMCParam);
    return IOConnectCallStructMethod(connection, kSMCUserClientCall, in, sizeof(SMCParam), out, &size) == KERN_SUCCESS
        && out->result == 0;
}

bool smc_open(void) {
    if (connection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

bool smc_read_float(const char *key, float *value) {
    if (strlen(key) != 4) return false;
    SMCParam in = {0}, out = {0};

    // 1) ask what type and size the key has
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (!call(&in, &out)) return false;
    if (out.keyInfo.dataType != fourcc("flt ") || out.keyInfo.dataSize != sizeof(float)) return false;

    // 2) read its bytes
    in.keyInfo.dataSize = sizeof(float);
    in.data8 = kSMCReadKey;
    if (!call(&in, &out)) return false;
    memcpy(value, out.bytes, sizeof(float));   // Apple Silicon SMC stores floats little-endian, like the CPU
    return true;
}

bool smc_read_known_float(const char *key, float *value) {
    if (strlen(key) != 4) return false;
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = sizeof(float);
    in.data8 = kSMCReadKey;
    if (!call(&in, &out)) return false;
    memcpy(value, out.bytes, sizeof(float));
    return true;
}

int smc_key_count(void) {
    SMCParam in = {0}, out = {0};
    in.key = fourcc("#KEY");   // a special key that holds the number of keys, as a big-endian uint32
    in.keyInfo.dataSize = 4;
    in.data8 = kSMCReadKey;
    if (!call(&in, &out)) return 0;
    return (int)((uint32_t)out.bytes[0] << 24 | (uint32_t)out.bytes[1] << 16 | (uint32_t)out.bytes[2] << 8 | out.bytes[3]);
}

bool smc_key_at_index(int index, char name[5]) {
    SMCParam in = {0}, out = {0};
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = (uint32_t)index;
    if (!call(&in, &out)) return false;
    name[0] = (char)(out.key >> 24);
    name[1] = (char)(out.key >> 16);
    name[2] = (char)(out.key >> 8);
    name[3] = (char)out.key;
    name[4] = 0;
    return true;
}
