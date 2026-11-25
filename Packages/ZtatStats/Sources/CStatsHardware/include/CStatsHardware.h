//
//  CStatsHardware.h
//  CStatsHardware
//
//  ZTAT-PATCH: Consolidated and deduplicated bridging header combining upstream
//  CPU/bridge.h, GPU/bridge.h, Sensors/bridge.h, and Disk/header.h for pure SwiftPM.
//

#ifndef CStatsHardware_h
#define CStatsHardware_h

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <libproc.h>
#include <stdint.h>

// MARK: - Apple Silicon HID Sensors (Sensors/bridge.h)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;

#ifdef __LP64__
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif

#define IOHIDEventFieldBase(type)   ((type) << 16)
#define kIOHIDEventTypeTemperature  15
#define kIOHIDEventTypePower        25

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

NSDictionary *AppleSiliconSensors(int32_t page, int32_t usage, int32_t type);
void AppleSiliconSensorsReset(void);

// MARK: - IOReport (CPU/bridge.h, GPU/bridge.h, Sensors/bridge.h)

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

CFDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef a, CFStringRef b, uint64_t c, uint64_t d, uint64_t e);
void IOReportMergeChannels(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef null);
IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef b, CFMutableDictionaryRef *c, uint64_t d, CFTypeRef e);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef a, CFMutableDictionaryRef b, CFTypeRef c);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef a, CFDictionaryRef b, CFTypeRef c);
CFStringRef IOReportChannelGetGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef a);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef a);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef a);
int32_t IOReportChannelGetFormat(CFDictionaryRef a);
int32_t IOReportStateGetCount(CFDictionaryRef a);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef a, int32_t b);
int64_t IOReportStateGetResidency(CFDictionaryRef a, int32_t b);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef a, int32_t b);

// MARK: - NVMe SMART Interface (Disk/header.h)

struct nvme_smart_log {
    UInt8  critical_warning;
    UInt8  temperature[2];
    UInt8  avail_spare;
    UInt8  spare_thresh;
    UInt8  percent_used;
    UInt8  rsvd6[26];
    UInt8  data_units_read[16];
    UInt8  data_units_written[16];
    UInt8  host_reads[16];
    UInt8  host_writes[16];
    UInt8  ctrl_busy_time[16];
    UInt32 power_cycles[4];
    UInt32 power_on_hours[4];
    UInt32 unsafe_shutdowns[4];
    UInt32 media_errors[4];
    UInt8  num_err_log_entries[16];
    UInt32 warning_temp_time;
    UInt32 critical_comp_time;
    UInt16 temp_sensor[8];
    UInt32 thm_temp1_trans_count;
    UInt32 thm_temp2_trans_count;
    UInt32 thm_temp1_total_time;
    UInt32 thm_temp2_total_time;
    UInt8  rsvd232[280];
};

typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;

    UInt16 version;
    UInt16 revision;

    IOReturn (*SMARTReadData)(void *interface, struct nvme_smart_log *NVMeSMARTData);
} IONVMeSMARTInterface;

#endif /* CStatsHardware_h */
