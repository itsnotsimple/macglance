#include "CSensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

// Apple's own NVMe SMART interface (the SDK header NVMeSMARTLibExternal.h): the same health
// numbers `smartctl` shows, readable without root. Only one program can have it open at a time,
// so it's opened for each reading and closed right after (kept open, it locked out smartctl,
// DriveDx and other apps for as long as MacGlance ran).
static bool open_smart(IOCFPlugInInterface ***plugin, IONVMeSMARTInterface ***smart) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    CFMutableDictionaryRef property = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(property, CFSTR("NVMe SMART Capable"), kCFBooleanTrue);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), property);
    CFRelease(property);
    io_service_t disk = IOServiceGetMatchingService(kIOMainPortDefault, matching);   // the internal SSD
    if (!disk) return false;
    SInt32 score = 0;
    kern_return_t result = IOCreatePlugInInterfaceForService(disk, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
                                                             plugin, &score);
    IOObjectRelease(disk);
    if (result != KERN_SUCCESS || !*plugin) return false;
    (**plugin)->QueryInterface(*plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)smart);
    if (*smart) return true;
    IODestroyPlugInInterface(*plugin);
    return false;
}

bool ssd_smart(SSDSmart *out) {
    IOCFPlugInInterface **plugin = NULL;
    IONVMeSMARTInterface **smart = NULL;
    if (!open_smart(&plugin, &smart)) return false;
    NVMeSMARTData data = {0};
    IOReturn read = (*smart)->SMARTReadData(smart, &data);
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    if (read != kIOReturnSuccess) return false;
    out->percentUsed = data.PERCENTAGE_USED;
    out->availableSpare = data.AVAILABLE_SPARE;
    out->spareThreshold = data.AVAILABLE_SPARE_THRESHOLD;
    out->criticalWarning = data.CRITICAL_WARNING;
    out->temperature = (int)data.TEMPERATURE - 273;   // the drive reports Kelvin
    // NVMe counts data in units of 1000 × 512 bytes
    out->bytesWritten = (double)data.DATA_UNITS_WRITTEN[0] * 512000.0;
    out->bytesRead = (double)data.DATA_UNITS_READ[0] * 512000.0;
    out->powerOnHours = data.POWER_ON_HOURS[0];
    out->powerCycles = data.POWER_CYCLES[0];
    out->unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];
    out->mediaErrors = data.MEDIA_ERRORS[0];
    return true;
}
