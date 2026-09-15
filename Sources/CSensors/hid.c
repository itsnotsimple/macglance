#include "CSensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>

// Private HID event API that Apple Silicon Macs use for their named temperature sensors.
// Same calls as Stats, macmon and other monitors; no root needed.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

enum { kTemperatureEvent = 15 };   // kIOHIDEventTypeTemperature; its value field is (type << 16)

static CFArrayRef sensors;   // all temperature sensors, listed once
static IOHIDServiceClientRef found;   // the sensor the last lookup matched, so later reads skip the search
static char foundPrefix[32];

static void list_sensors(void) {
    if (sensors) return;
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return;
    int page = 0xff00, usage = 5;   // Apple's vendor page, "temperature sensor"
    CFNumberRef pageNumber = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNumber = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {pageNumber, usageNumber};
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, matching);
    sensors = IOHIDEventSystemClientCopyServices(client);   // kept for the app's lifetime, like the client
    CFRelease(matching);
    CFRelease(pageNumber);
    CFRelease(usageNumber);
}

static double read_sensor(IOHIDServiceClientRef sensor) {
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(sensor, kTemperatureEvent, 0, 0);
    if (!event) return NAN;
    double value = IOHIDEventGetFloatValue(event, kTemperatureEvent << 16);
    CFRelease(event);
    return value;
}

double hid_temperature(const char *prefix) {
    if (found && strcmp(foundPrefix, prefix) == 0) return read_sensor(found);
    list_sensors();
    if (!sensors) return NAN;
    for (CFIndex i = 0; i < CFArrayGetCount(sensors); i++) {
        IOHIDServiceClientRef sensor = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(sensors, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(sensor, CFSTR("Product"));
        char buffer[64] = "";
        if (name) {
            CFStringGetCString(name, buffer, sizeof buffer, kCFStringEncodingUTF8);
            CFRelease(name);
        }
        if (strncmp(buffer, prefix, strlen(prefix)) != 0) continue;
        found = sensor;   // stays valid: `sensors` keeps it alive
        strlcpy(foundPrefix, prefix, sizeof foundPrefix);
        return read_sensor(sensor);
    }
    return NAN;
}
