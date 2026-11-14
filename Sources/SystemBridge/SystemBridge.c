#include "SystemBridge.h"
#include <stdlib.h>
#include <string.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <pthread.h>

static int32_t (*responsibility_pid)(int32_t);
static pthread_once_t responsibility_once = PTHREAD_ONCE_INIT;
static void load_responsibility(void) {
    responsibility_pid = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
}

void ms_free(void *pointer) { free(pointer); }
uint64_t ms_sysctl(const char *key) {
    uint64_t value = 0; size_t size = sizeof(value);
    if (sysctlbyname(key, &value, &size, NULL, 0) != 0) return 0;
    return value;
}

int ms_processes(MSProcess **output) {
    pthread_once(&responsibility_once, load_responsibility);
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    *output = NULL;
    int capacity = proc_listallpids(NULL, 0) + 256;
    if (capacity <= 256) return -1;
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    MSProcess *rows = calloc(capacity, sizeof(MSProcess));
    if (!pids || !rows) { free(pids); free(rows); return -1; }
    int count = proc_listallpids(pids, capacity * sizeof(pid_t)), used = 0;
    for (int i = 0; i < count && i < capacity; i++) {
        if (pids[i] < 0) continue;
        MSProcess *row = &rows[used++]; row->pid = pids[i]; row->uid = -1;
        // XPC helpers may have launchd as their parent. Read the system's
        // responsibility relationship when available; never infer from focus.
        if (responsibility_pid) {
            int32_t responsible = responsibility_pid(row->pid);
            if (responsible > 0) row->responsible = responsible;
        }
        proc_name(row->pid, row->name, sizeof(row->name));
        proc_pidpath(row->pid, row->path, sizeof(row->path));
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(row->pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) == sizeof(bsd)) {
            row->uid = bsd.pbi_uid; row->parent = bsd.pbi_ppid;
            row->start = bsd.pbi_start_tvsec * 1000000 + bsd.pbi_start_tvusec;
            if (!row->name[0]) strlcpy(row->name, bsd.pbi_comm, sizeof(row->name));
        }
        struct proc_taskinfo task = {0};
        if (proc_pidinfo(row->pid, PROC_PIDTASKINFO, 0, &task, sizeof(task)) == sizeof(task)) {
            row->threads = task.pti_threadnum;
        }
        struct rusage_info_v6 usage = {0};
        int success = proc_pid_rusage(row->pid, RUSAGE_INFO_V6, (rusage_info_t *)&usage);
        // V6 success distinguishes an unavailable counter from a valid zero.
        // A V4 fallback must not silently become zero-energy telemetry.
        row->energy_available = success == 0;
        if (success != 0) success = proc_pid_rusage(row->pid, RUSAGE_INFO_V4, (rusage_info_t *)&usage);
        if (success == 0) {
            row->readable = 1;
            row->start_abstime_ns = (uint64_t)((__uint128_t)usage.ri_proc_start_abstime * timebase.numer / timebase.denom);
            // rusage CPU times are Mach absolute ticks, not nanoseconds on ARM.
            row->cpu_ns = (uint64_t)(((__uint128_t)usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom);
            row->memory = usage.ri_phys_footprint; row->resident = usage.ri_resident_size;
            row->read_bytes = usage.ri_diskio_bytesread; row->write_bytes = usage.ri_diskio_byteswritten;
            row->wakeups = usage.ri_interrupt_wkups; row->energy_nj = usage.ri_energy_nj;
            if (!row->start) row->start = usage.ri_proc_start_abstime;
        }
        if (!row->name[0]) strlcpy(row->name, row->pid == 0 ? "kernel_task" : "受保护进程", sizeof(row->name));
    }
    free(pids); *output = rows; return used;
}

int ms_cpu(uint64_t *ticks, int capacity) {
    natural_t cores = 0; processor_info_array_t info = NULL; mach_msg_type_number_t count = 0;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return -1;
    int n = cores < capacity ? cores : capacity;
    for (int i = 0; i < n * CPU_STATE_MAX; i++) ticks[i] = (uint32_t)info[i];
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
    return n;
}

int ms_memory(MSMemory *out) {
    vm_statistics64_data_t vm = {0}; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return 0;
    uint64_t page = vm_kernel_page_size;
    out->total = ms_sysctl("hw.memsize");
    out->active = vm.active_count * page; out->inactive = vm.inactive_count * page;
    out->wired = vm.wire_count * page; out->compressed = vm.compressor_page_count * page;
    out->free = vm.free_count * page; out->purgeable = vm.purgeable_count * page;
    uint64_t app = (vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0) * page;
    out->used = app + out->wired + out->compressed;
    out->pageins = vm.pageins; out->pageouts = vm.pageouts;
    out->pressure = (int)ms_sysctl("kern.memorystatus_vm_pressure_level");
    struct xsw_usage swap = {0}; size_t size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) out->swap = swap.xsu_used;
    return 1;
}

int ms_network(MSNetwork *out, int capacity) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return -1;
    int count = 0;
    for (struct ifaddrs *item = interfaces; item && count < capacity; item = item->ifa_next) {
        if (!item->ifa_addr || item->ifa_addr->sa_family != AF_LINK || !item->ifa_data) continue;
        if (item->ifa_flags & IFF_LOOPBACK) continue;
        MSNetwork *row = &out[count++]; memset(row, 0, sizeof(*row));
        strlcpy(row->name, item->ifa_name, sizeof(row->name));
        struct if_data *data = item->ifa_data;
        row->received = data->ifi_ibytes; row->sent = data->ifi_obytes;
        row->up = (item->ifa_flags & IFF_UP) && (item->ifa_flags & IFF_RUNNING);
        for (struct ifaddrs *ip = interfaces; ip; ip = ip->ifa_next) {
            if (!ip->ifa_addr || strcmp(ip->ifa_name, item->ifa_name) != 0) continue;
            if (ip->ifa_addr->sa_family == AF_INET) {
                inet_ntop(AF_INET, &((struct sockaddr_in *)ip->ifa_addr)->sin_addr, row->address, sizeof(row->address));
                break;
            }
        }
    }
    freeifaddrs(interfaces); return count;
}
