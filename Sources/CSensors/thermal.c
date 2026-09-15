#include "CSensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <notify.h>
#include <stdlib.h>
#include <string.h>

// --- Thermal pressure: how hard macOS is holding the chip back because of heat ---

int thermal_pressure_level(void) {
    static int token = -1;
    if (token < 0 && notify_register_check("com.apple.system.thermalpressurelevel", &token) != 0) return -1;
    uint64_t level = 0;
    if (notify_get_state(token, &level) != 0) return -1;
    return (int)level;
}

// --- Real CPU frequency: time spent at each speed step (IOReport), weighted by the step's MHz ---

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern int IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int);

static IOReportSubscriptionRef subscription;
static CFMutableDictionaryRef subscribed;
static CFDictionaryRef previous;
static double eSteps[32], pSteps[32];   // MHz per speed step
static int eCount, pCount;

/// The power manager lists each cluster's speed steps: voltage-states1 = E-cores, voltage-states5 = P-cores.
/// Older chips store Hz, M4/M5 store kHz.
static int load_steps(io_registry_entry_t pmgr, const char *key, double *steps) {
    CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFDataRef data = IORegistryEntryCreateCFProperty(pmgr, name, NULL, 0);
    CFRelease(name);
    if (!data) return 0;
    const uint32_t *values = (const uint32_t *)CFDataGetBytePtr(data);
    int count = (int)(CFDataGetLength(data) / 8);   // pairs of (frequency, voltage)
    if (count > 32) count = 32;
    uint32_t largest = 0;
    for (int i = 0; i < count; i++) if (values[i * 2] > largest) largest = values[i * 2];
    double divisor = largest > 100000000 ? 1e6 : 1e3;   // Hz or kHz → MHz
    for (int i = 0; i < count; i++) steps[i] = values[i * 2] / divisor;
    CFRelease(data);
    return count;
}

static bool open_frequency(void) {
    if (subscription) return true;
    io_registry_entry_t pmgr = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr");
    if (!pmgr) return false;
    eCount = load_steps(pmgr, "voltage-states1-sram", eSteps);
    pCount = load_steps(pmgr, "voltage-states5-sram", pSteps);
    IOObjectRelease(pmgr);
    if (!eCount || !pCount) return false;
    CFMutableDictionaryRef channels = IOReportCopyChannelsInGroup(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (!channels) return false;
    subscription = IOReportCreateSubscription(NULL, channels, &subscribed, 0, NULL);
    CFRelease(channels);
    return subscription != NULL;
}

/// The speed step a state stands for: names look like "V18P0", the number after V is the step.
static int step_of(CFStringRef state) {
    char name[32] = "";
    CFStringGetCString(state, name, sizeof name, kCFStringEncodingUTF8);
    return name[0] == 'V' ? atoi(name + 1) : -1;   // IDLE, DOWN, OFF → -1
}

bool cpu_frequencies(CPUFrequencies *out) {
    if (!open_frequency()) return false;
    CFDictionaryRef current = IOReportCreateSamples(subscription, subscribed, NULL);
    if (!current) return false;
    if (!previous) {   // first call: just the baseline
        previous = current;
        return false;
    }
    CFDictionaryRef delta = IOReportCreateSamplesDelta(previous, current, NULL);
    CFRelease(previous);
    previous = current;
    if (!delta) return false;

    double eWeighted = 0, eActive = 0, pWeighted = 0, pActive = 0;
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
        char channel[32] = "";
        CFStringGetCString(IOReportChannelGetChannelName(item), channel, sizeof channel, kCFStringEncodingUTF8);
        bool isP = strncmp(channel, "PCPU", 4) == 0, isE = strncmp(channel, "ECPU", 4) == 0;
        if (!isP && !isE) continue;
        for (int s = 0; s < IOReportStateGetCount(item); s++) {
            int step = step_of(IOReportStateGetNameForIndex(item, s));
            double time = (double)IOReportStateGetResidency(item, s);
            if (step < 0 || time <= 0) continue;
            if (isP && step < pCount) { pWeighted += pSteps[step] * time; pActive += time; }
            if (isE && step < eCount) { eWeighted += eSteps[step] * time; eActive += time; }
        }
    }
    CFRelease(delta);
    out->eMHz = eActive > 0 ? eWeighted / eActive : 0;
    out->pMHz = pActive > 0 ? pWeighted / pActive : 0;
    out->eMaxMHz = 0;
    out->pMaxMHz = 0;
    for (int i = 0; i < eCount; i++) if (eSteps[i] > out->eMaxMHz) out->eMaxMHz = eSteps[i];
    for (int i = 0; i < pCount; i++) if (pSteps[i] > out->pMaxMHz) out->pMaxMHz = pSteps[i];
    return true;
}
