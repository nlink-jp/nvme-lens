#include "include/CNvmeSmart.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

static void copy_cfstring(CFStringRef value, char *out, size_t capacity) {
    out[0] = '\0';
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    CFStringGetCString(value, out, (CFIndex)capacity, kCFStringEncodingUTF8);
}

/// Reads a string out of a nested IOKit dictionary property, e.g.
/// "Protocol Characteristics" -> "Physical Interconnect".
static void copy_nested_string(io_object_t service, CFStringRef dictKey, CFStringRef valueKey,
                               char *out, size_t capacity) {
    out[0] = '\0';
    CFTypeRef dict = IORegistryEntrySearchCFProperty(service, kIOServicePlane, dictKey,
                                                     kCFAllocatorDefault,
                                                     kIORegistryIterateRecursively);
    if (!dict) return;
    if (CFGetTypeID(dict) == CFDictionaryGetTypeID()) {
        CFStringRef value = CFDictionaryGetValue((CFDictionaryRef)dict, valueKey);
        copy_cfstring(value, out, capacity);
    }
    CFRelease(dict);
}

static void copy_bsd_name(io_object_t service, char *out, size_t capacity) {
    out[0] = '\0';
    CFTypeRef name = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
                                                     CFSTR(kIOBSDNameKey), kCFAllocatorDefault,
                                                     kIORegistryIterateRecursively);
    if (!name) return;
    copy_cfstring((CFStringRef)name, out, capacity);
    CFRelease(name);
}

/// Matching dictionary for every IOService carrying the "NVMe SMART Capable"
/// property. The header recommends matching on the property rather than on a
/// class name, because the providing class differs between the internal
/// controller and external ones.
static CFMutableDictionaryRef smart_capable_matching(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOService");
    if (!matching) return NULL;
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!properties) {
        CFRelease(matching);
        return NULL;
    }
    CFDictionarySetValue(properties, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFBooleanTrue);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), properties);
    CFRelease(properties);
    return matching;
}

static int32_t count_matching(CFMutableDictionaryRef matching) {
    if (!matching) return -1;
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return -1;
    }
    int32_t count = 0;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        count++;
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

/// Returns the service at `index`, or IO_OBJECT_NULL. Caller releases.
static io_object_t service_at(CFMutableDictionaryRef matching, int32_t index) {
    if (!matching || index < 0) {
        if (matching) CFRelease(matching);
        return IO_OBJECT_NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    io_object_t found = IO_OBJECT_NULL;
    io_object_t service;
    int32_t position = 0;
    while ((service = IOIteratorNext(iterator))) {
        if (position == index) {
            found = service;
            break;
        }
        IOObjectRelease(service);
        position++;
    }
    IOObjectRelease(iterator);
    return found;
}

int32_t nl_nvme_count(void) { return count_matching(smart_capable_matching()); }

int32_t nl_nvme_sample_at(int32_t index, nl_nvme_sample *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    out->identifyStatus = kIOReturnNotFound;
    out->logPageStatus = kIOReturnNotFound;

    io_object_t service = service_at(smart_capable_matching(), index);
    if (service == IO_OBJECT_NULL) return -1;

    copy_bsd_name(service, out->bsdName, sizeof(out->bsdName));

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || !plugin) {
        IOObjectRelease(service);
        return -1;
    }

    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),
                                           (LPVOID *)&smart);
    if (hr != S_OK || !smart) {
        IODestroyPlugInInterface(plugin);
        IOObjectRelease(service);
        return -1;
    }

    out->identifyStatus = (*smart)->GetIdentifyData(smart, out->identify, 0);
    // inNumDWords is zero-based: 512 bytes is 128 dwords, so 127.
    out->logPageStatus = (*smart)->GetLogPage(smart, out->smartLog, 0x02, 127);

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    IOObjectRelease(service);
    return 0;
}

int32_t nl_drive_count(void) { return count_matching(IOServiceMatching("IOBlockStorageDevice")); }

int32_t nl_drive_at(int32_t index, nl_drive *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));

    io_object_t service = service_at(IOServiceMatching("IOBlockStorageDevice"), index);
    if (service == IO_OBJECT_NULL) return -1;

    copy_bsd_name(service, out->bsdName, sizeof(out->bsdName));
    copy_nested_string(service, CFSTR("Device Characteristics"), CFSTR("Product Name"),
                       out->productName, sizeof(out->productName));
    copy_nested_string(service, CFSTR("Device Characteristics"), CFSTR("Serial Number"),
                       out->serialNumber, sizeof(out->serialNumber));
    copy_nested_string(service, CFSTR("Protocol Characteristics"), CFSTR("Physical Interconnect"),
                       out->physicalInterconnect, sizeof(out->physicalInterconnect));
    copy_nested_string(service, CFSTR("Protocol Characteristics"),
                       CFSTR("Physical Interconnect Location"),
                       out->physicalInterconnectLocation,
                       sizeof(out->physicalInterconnectLocation));

    CFTypeRef capable = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault,
        kIORegistryIterateRecursively);
    if (capable) {
        out->smartCapable =
            (CFGetTypeID(capable) == CFBooleanGetTypeID() && CFBooleanGetValue(capable)) ? 1 : 0;
        CFRelease(capable);
    }

    IOObjectRelease(service);
    return 0;
}
