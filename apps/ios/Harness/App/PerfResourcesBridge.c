#include "PerfResourcesBridge.h"
#include <sys/resource.h>
#include <unistd.h>

// Apple demonstrates this iOS prototype shim in WWDC22 session 10106.
// The public rusage_info_v2 layout is in sys/resource.h; iOS omits the libproc.h declaration.
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

int HarnessReadDiskWriteBytes(uint64_t *bytes) {
    struct rusage_info_v2 usage = {0};
    if (bytes == 0 || proc_pid_rusage(getpid(), RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) {
        return 0;
    }
    *bytes = usage.ri_diskio_byteswritten;
    return 1;
}
