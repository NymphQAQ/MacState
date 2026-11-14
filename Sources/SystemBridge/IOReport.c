#include "SystemBridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>

// Resolve this hardware-dependent interface at runtime so unsupported systems
// can still launch. No privileged helper, external command, or sampling sleep.
struct MSIOReport {
    void *library;
    CFTypeRef subscription;
    CFMutableDictionaryRef channels, subscribed;
    CFDictionaryRef previous;
    uint64_t timestamp;
    mach_timebase_info_data_t timebase;
    CFDictionaryRef (*all)(uint64_t, uint64_t);
    CFTypeRef (*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*sample)(CFTypeRef, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    CFStringRef (*group)(CFDictionaryRef), (*subgroup)(CFDictionaryRef), (*name)(CFDictionaryRef), (*unit)(CFDictionaryRef);
    int64_t (*integer)(CFDictionaryRef, int);
    int (*state_count)(CFDictionaryRef);
    CFStringRef (*state_name)(CFDictionaryRef, int);
    int64_t (*residency)(CFDictionaryRef, int);
};

static int equals(CFStringRef value, CFStringRef expected) { return value && CFEqual(value, expected); }
static CFArrayRef channel_array(CFDictionaryRef dict) {
    CFTypeRef value = dict ? CFDictionaryGetValue(dict, CFSTR("IOReportChannels")) : NULL;
    return value && CFGetTypeID(value) == CFArrayGetTypeID() ? value : NULL;
}

void ms_ioreport_destroy(MSIOReport *c) {
    if (!c) return;
    if (c->previous) CFRelease(c->previous);
    if (c->subscription) CFRelease(c->subscription);
    if (c->subscribed) CFRelease(c->subscribed);
    if (c->channels) CFRelease(c->channels);
    if (c->library) dlclose(c->library);
    free(c);
}

MSIOReport *ms_ioreport_create(void) {
    MSIOReport *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!c->library) goto failed;
#define RESOLVE(field, symbol) c->field = dlsym(c->library, symbol); if (!c->field) goto failed
    RESOLVE(all, "IOReportCopyAllChannels");
    RESOLVE(subscribe, "IOReportCreateSubscription");
    RESOLVE(sample, "IOReportCreateSamples");
    RESOLVE(delta, "IOReportCreateSamplesDelta");
    RESOLVE(group, "IOReportChannelGetGroup");
    RESOLVE(subgroup, "IOReportChannelGetSubGroup");
    RESOLVE(name, "IOReportChannelGetChannelName");
    RESOLVE(unit, "IOReportChannelGetUnitLabel");
    RESOLVE(integer, "IOReportSimpleGetIntegerValue");
    RESOLVE(state_count, "IOReportStateGetCount");
    RESOLVE(state_name, "IOReportStateGetNameForIndex");
    RESOLVE(residency, "IOReportStateGetResidency");
#undef RESOLVE
    CFDictionaryRef all = c->all(0, 0);
    CFArrayRef list = channel_array(all);
    if (!list) { if (all) CFRelease(all); goto failed; }
    c->channels = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(list, i);
        if (CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        CFStringRef group = c->group(item), name = c->name(item);
        int ane = name && CFStringHasPrefix(name, CFSTR("ANE")) && CFStringHasSuffix(name, CFSTR("Energy"));
        int energy = equals(group, CFSTR("Energy Model")) && (equals(name, CFSTR("GPU Energy")) || ane);
        int frequency = equals(group, CFSTR("GPU Stats")) && equals(c->subgroup(item), CFSTR("GPU Performance States")) && equals(name, CFSTR("GPUPH"));
        if (energy || frequency) CFArrayAppendValue(selected, item);
    }
    CFDictionarySetValue(c->channels, CFSTR("IOReportChannels"), selected);
    CFIndex count = CFArrayGetCount(selected);
    CFRelease(selected); CFRelease(all);
    if (!count) goto failed;
    c->subscription = c->subscribe(NULL, c->channels, &c->subscribed, 0, NULL);
    if (!c->subscription) goto failed;
    mach_timebase_info(&c->timebase);
    return c;
failed:
    ms_ioreport_destroy(c);
    return NULL;
}

int ms_ioreport_sample(MSIOReport *c, MSIOEnergy *out, MSGPUState *states, int capacity) {
    memset(out, 0, sizeof(*out));
    if (!c) return -1;
    CFDictionaryRef current = c->sample(c->subscription, c->channels, NULL);
    uint64_t now = mach_absolute_time();
    if (!current) { if (c->previous) CFRelease(c->previous); c->previous = NULL; return -1; }
    if (!c->previous) { c->previous = current; c->timestamp = now; return 0; }
    double elapsed = (double)(now - c->timestamp) * c->timebase.numer / c->timebase.denom / 1e9;
    CFDictionaryRef delta = elapsed > 0 && elapsed <= 30 ? c->delta(c->previous, current, NULL) : NULL;
    CFRelease(c->previous); c->previous = current; c->timestamp = now;
    if (!delta) return -1;
    out->elapsed = elapsed;
    CFArrayRef list = channel_array(delta), metadata = channel_array(c->channels);
    int used = 0;
    if (list && metadata && CFArrayGetCount(list) == CFArrayGetCount(metadata)) {
        for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(list, i), info = CFArrayGetValueAtIndex(metadata, i);
            CFStringRef name = c->name(info), unit = c->unit(info);
            if (equals(c->group(info), CFSTR("Energy Model"))) {
                int64_t raw = c->integer(item, 0);
                double scale = equals(unit, CFSTR("nJ")) ? 1e-9 : equals(unit, CFSTR("uJ")) || equals(unit, CFSTR("µJ")) ? 1e-6 : equals(unit, CFSTR("mJ")) ? 1e-3 : equals(unit, CFSTR("J")) ? 1 : 0;
                if (raw < 0 || !scale) continue;
                if (equals(name, CFSTR("GPU Energy"))) { out->gpu_valid = 1; out->gpu_watts += (double)raw * scale / elapsed; }
                if (name && CFStringHasPrefix(name, CFSTR("ANE"))) { out->ane_valid = 1; out->ane_watts += (double)raw * scale / elapsed; }
            } else if (equals(c->group(info), CFSTR("GPU Stats"))) {
                // A single GPU channel only: cross-device frequency tables must
                // not be merged. Power attribution separately checks device count.
                if (used) continue;
                int count = c->state_count(item);
                if (count < 1 || count > capacity) continue;
                for (int j = 0; j < count; j++) {
                    MSGPUState *state = &states[used++]; memset(state, 0, sizeof(*state));
                    CFStringRef label = c->state_name(item, j);
                    if (label) CFStringGetCString(label, state->name, sizeof(state->name), kCFStringEncodingUTF8);
                    state->residency = c->residency(item, j);
                }
            }
        }
    }
    CFRelease(delta);
    return used;
}
