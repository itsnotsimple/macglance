#ifndef CSENSORS_H
#define CSENSORS_H

#include <stdbool.h>

/// Opens a connection to the SMC (System Management Controller), the chip that measures
/// power, temperatures and fans. Safe to call more than once. No root needed.
bool smc_open(void);

/// Reads a 4-letter SMC key that holds a float (type "flt "), e.g. "PSTR" = whole-system watts.
/// Returns false if the key does not exist on this Mac or is not a float.
bool smc_read_float(const char *key, float *value);

/// Like smc_read_float, but skips asking the key's type first: half the calls.
/// Only for keys already checked with smc_read_float, otherwise the value is garbage.
bool smc_read_known_float(const char *key, float *value);

/// How many keys this Mac's SMC has (about 2400 on an M5). Key names differ between chips,
/// so callers list them once and pick what they need.
int smc_key_count(void);

/// Name of the key at `index` (0 ..< smc_key_count()), as 4 letters plus a terminating zero.
bool smc_key_at_index(int index, char name[5]);

/// Temperature in °C from the HID sensor whose name starts with `prefix` ("NAND" = the SSD).
/// These sensors have readable names, unlike SMC keys. Returns NAN if there is no such sensor.
double hid_temperature(const char *prefix);

/// Health of the internal SSD, from its own NVMe SMART log.
typedef struct {
    int percentUsed;          // wear: 0 = new, 100 = rated life used up (it can keep working past it)
    int availableSpare;       // % of spare blocks left to replace worn ones
    int spareThreshold;       // below this the drive warns
    int criticalWarning;      // 0 = all good
    int temperature;          // °C
    double bytesWritten;      // over the drive's whole life
    double bytesRead;
    unsigned long long powerOnHours;
    unsigned long long powerCycles;
    unsigned long long unsafeShutdowns;   // power lost without a clean shutdown
    unsigned long long mediaErrors;
} SSDSmart;

/// Reads the SSD's health. False if the Mac's SSD doesn't offer NVMe SMART.
bool ssd_smart(SSDSmart *out);

/// macOS's thermal pressure: 0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping. -1 if unknown.
int thermal_pressure_level(void);

/// Average speed of each core cluster while working (idle time left out), and its top speed,
/// plus the same per core (in the order ECPU0, ECPU1… / PCPU0, PCPU1…). 0 = no work in the period.
typedef struct {
    double eMHz, eMaxMHz;   // efficiency cores
    double pMHz, pMaxMHz;   // performance ("Super" on M5) cores
    int eCount, pCount;
    double eCoreMHz[16];
    double pCoreMHz[16];
} CPUFrequencies;

/// Speeds since the previous call. False on the first call (baseline) or if the Mac doesn't say.
bool cpu_frequencies(CPUFrequencies *out);

#endif
