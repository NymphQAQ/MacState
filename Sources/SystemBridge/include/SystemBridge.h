#ifndef SYSTEM_BRIDGE_H
#define SYSTEM_BRIDGE_H
#include <stdint.h>

typedef struct {
    int32_t pid, parent, uid, threads, responsible;
    char name[256], path[4096];
    uint64_t start, start_abstime_ns, cpu_ns, memory, resident, read_bytes, write_bytes, wakeups, energy_nj;
    int readable, energy_available;
} MSProcess;
int ms_processes(MSProcess **output);
void ms_free(void *pointer);
int ms_cpu(uint64_t *ticks, int capacity);
typedef struct {
    uint64_t total, used, active, inactive, wired, compressed, free, purgeable, swap;
    uint64_t pageins, pageouts;
    int pressure;
} MSMemory;
int ms_memory(MSMemory *output);
typedef struct { char name[64], address[128]; uint64_t received, sent; int up; } MSNetwork;
int ms_network(MSNetwork *output, int capacity);
uint64_t ms_sysctl(const char *key);
typedef struct { char key[5], type[5]; double value; } MSSensor;
int ms_sensors(MSSensor *output, int capacity);
void ms_smc_close(void);
typedef struct MSIOReport MSIOReport;
typedef struct { char name[64]; int64_t residency; } MSGPUState;
typedef struct { double elapsed, gpu_watts, ane_watts; int gpu_valid, ane_valid; } MSIOEnergy;
MSIOReport *ms_ioreport_create(void);
void ms_ioreport_destroy(MSIOReport *context);
int ms_ioreport_sample(MSIOReport *context, MSIOEnergy *output, MSGPUState *states, int capacity);
#endif
