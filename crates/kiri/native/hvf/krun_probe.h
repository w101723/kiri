#ifndef KIRI_KRUN_PROBE_H
#define KIRI_KRUN_PROBE_H

#include <stdint.h>

// Verifies that the signed Helper process can create a VM and vCPU directly.
int32_t kiri_hvf_check(void);

// Runs one VM in the current process. libkrun exits this process on guest
// poweroff. Configuration and early startup errors return a negative errno.
int32_t kiri_hvf_run(const char *directory, uint32_t memory_mib, uint8_t cpus,
                    const char *rosetta_directory);
// rosetta_directory: host path to the system Apple Linux translation runtime,
// exported read-only under the "rosetta" VirtioFS tag; NULL disables it.
int32_t kiri_hvf_run_helper(const char *directory, uint32_t memory_mib, uint8_t cpus,
                            const char *share_spec, const char *const *shares, uint8_t share_count,
                            const char *rosetta_directory);

#endif
