// Thin C shim over IOKit's NVMe SMART plug-in interface.
//
// The interface is CFPlugIn COM (a vtable of function pointers reached through
// a double pointer), which is painful to drive from Swift. This shim keeps the
// COM dance in C and hands Swift plain buffers; all parsing and all policy live
// on the Swift side so they stay unit-testable without a device (ADR-0001).
#ifndef CNVME_SMART_H
#define CNVME_SMART_H

#include <stdint.h>

#define NL_IDENTIFY_SIZE 4096
#define NL_SMART_LOG_SIZE 512
#define NL_STRING_MAX 128

/// One NVMe controller that advertises SMART capability.
///
/// `identifyStatus` / `logPageStatus` are raw `IOReturn` values. A device may
/// advertise the capability and still fail both calls — an empty USB NVMe caddy
/// does exactly that — so the caller must check them rather than assume the
/// buffers are meaningful.
typedef struct {
    char bsdName[NL_STRING_MAX];
    int32_t identifyStatus;
    int32_t logPageStatus;
    uint8_t identify[NL_IDENTIFY_SIZE];
    uint8_t smartLog[NL_SMART_LOG_SIZE];
} nl_nvme_sample;

/// One physical block storage device, whether or not SMART can be read from it.
typedef struct {
    char bsdName[NL_STRING_MAX];
    char productName[NL_STRING_MAX];
    char serialNumber[NL_STRING_MAX];
    /// IOKit "Physical Interconnect": "Apple Fabric", "PCI-Express", "USB",
    /// "Secure Digital", "Virtual Interface", ...
    char physicalInterconnect[NL_STRING_MAX];
    /// IOKit "Physical Interconnect Location": "Internal", "External", "File".
    char physicalInterconnectLocation[NL_STRING_MAX];
    /// Whether the device carries the "NVMe SMART Capable" property. Necessary
    /// but not sufficient: see nl_nvme_sample.
    uint8_t smartCapable;
} nl_drive;

/// Number of NVMe controllers advertising SMART capability. Negative on failure.
int32_t nl_nvme_count(void);

/// Fills `out` for the controller at `index`. Returns 0 on success, negative if
/// the index does not exist or the plug-in could not be opened. A zero return
/// does NOT mean the data is valid — check the status fields.
int32_t nl_nvme_sample_at(int32_t index, nl_nvme_sample *out);

/// Number of physical block storage devices. Negative on failure.
int32_t nl_drive_count(void);

/// Fills `out` for the drive at `index`. Returns 0 on success.
int32_t nl_drive_at(int32_t index, nl_drive *out);

#endif /* CNVME_SMART_H */
