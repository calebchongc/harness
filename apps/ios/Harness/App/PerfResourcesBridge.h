#ifndef HARNESS_PERF_RESOURCES_BRIDGE_H
#define HARNESS_PERF_RESOURCES_BRIDGE_H

#include <stdint.h>

// Returns 1 on success, 0 when the own-process disk counter is unavailable.
int HarnessReadDiskWriteBytes(uint64_t *bytes);

#endif
