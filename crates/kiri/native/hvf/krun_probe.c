#include "krun_probe.h"
#include "slirp_network.h"

#include <Hypervisor/Hypervisor.h>
#include <errno.h>
#include <libkrun.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

int32_t kiri_hvf_check(void) {
    hv_return_t result = hv_vm_create(NULL);
    if (result != HV_SUCCESS) return result;

    hv_vcpu_t cpu;
    hv_vcpu_exit_t *cpu_exit;
    result = hv_vcpu_create(&cpu, &cpu_exit, NULL);
    if (result == HV_SUCCESS) result = hv_vcpu_destroy(cpu);
    hv_return_t destroy = hv_vm_destroy();
    return result == HV_SUCCESS ? destroy : result;
}

static int32_t run(const char *directory, uint32_t memory_mib, uint8_t cpus,
                   bool helper, const char *share_spec, const char *const *shares, uint8_t share_count,
                   const char *rosetta_directory, const char *docker_directory) {
    char kernel[PATH_MAX], initrd[PATH_MAX], data[PATH_MAX], seed[PATH_MAX], console[PATH_MAX];
    char docker[sizeof(((struct sockaddr_un *)0)->sun_path)], stop[sizeof(docker)],
         telemetry[sizeof(docker)], ports[sizeof(docker)];
    char cmdline[2048];
#define PATH_IN(buf, name) do { \
    int n = snprintf(buf, sizeof(buf), "%s/%s", directory, name); \
    if (n < 0 || (size_t)n >= sizeof(buf)) return -ENAMETOOLONG; \
} while (0)
    PATH_IN(kernel, helper ? "guest/Image" : "Image");
    PATH_IN(initrd, helper ? "guest/initramfs.cpio" : "initramfs.cpio");
    PATH_IN(data, helper ? "vm/data.img" : "data.img");
    PATH_IN(seed, helper ? "vm/system.img" : "system.img");
    PATH_IN(console, helper ? "logs/console.log" : "console.log");
    PATH_IN(docker, helper ? "run/docker.sock" : "docker.sock");
    PATH_IN(stop, helper ? "run/shutdown.sock" : "shutdown.sock");
    PATH_IN(telemetry, helper ? "run/memory.sock" : "memory.sock");
    if (helper) PATH_IN(ports, "run/ports.sock");
#undef PATH_IN
    int length = snprintf(cmdline, sizeof(cmdline),
                          "console=hvc0 rdinit=/init panic=-1 kiri.moby_boot_time=%lld%s%s%s%s",
                          (long long)time(NULL), helper ? " kiri.moby_share_layout=per-directory" : "",
                          rosetta_directory ? " kiri.moby_hvf_rosetta=1" : "",
                          share_count ? " kiri.moby_shares=" : "", share_spec);
    if (length < 0 || length >= (int)sizeof(cmdline) || share_count > 16) return -EINVAL;

    int32_t ctx_id = krun_create_ctx();
    if (ctx_id < 0) return ctx_id;
    uint32_t ctx = (uint32_t)ctx_id;
    int32_t result;
    int network_fd = -1;
    uint8_t mac[] = {0x02, 0x4b, 0x69, 0x72, 0x69, 0x01};
#define CHECK(call) do { \
    result = (call); \
    if (result < 0) { fprintf(stderr, "%s failed: %d\n", #call, result); goto cleanup; } \
} while (0)
    CHECK(krun_set_log_level(2));
    CHECK(krun_set_vm_config(ctx, cpus, memory_mib));
    CHECK(krun_set_kernel(ctx, kernel, KRUN_KERNEL_FORMAT_RAW, initrd, cmdline));
    CHECK(krun_add_disk3(ctx, "kiri-moby", data, KRUN_DISK_FORMAT_RAW, false, false, KRUN_SYNC_FULL));
    CHECK(krun_add_disk3(ctx, "kiri-system", seed, KRUN_DISK_FORMAT_RAW, true, false, KRUN_SYNC_FULL));
    CHECK(krun_set_console_output(ctx, console));
    CHECK(krun_disable_implicit_vsock(ctx));
    CHECK(krun_add_vsock(ctx, 0));
    CHECK(krun_add_vsock_port2(ctx, 2375, docker, true));
    CHECK(krun_add_vsock_port2(ctx, 2376, stop, true));
    CHECK(krun_add_vsock_port2(ctx, 2378, telemetry, true));
    if (helper) CHECK(krun_add_vsock_port2(ctx, 2377, ports, true));
    for (uint8_t i = 0; i < share_count; i++) {
        char tag[16];
        snprintf(tag, sizeof(tag), "kiri-s%u", (unsigned)i);
        CHECK(krun_add_virtiofs(ctx, tag, shares[i]));
    }
    if (rosetta_directory) CHECK(krun_add_virtiofs3(ctx, "rosetta", rosetta_directory, 0, true));
    if (docker_directory) CHECK(krun_add_virtiofs3(ctx, "docker", docker_directory, 0, true));
    CHECK(krun_set_reset_exit_code(ctx, 70));
    CHECK(kiri_hvf_network_start(&network_fd));
    // No checksum or segmentation offloads: the NAT peer receives Ethernet frames.
    CHECK(krun_add_net_unixstream(ctx, NULL, network_fd, mac, 0, 0));
    // krun_start_enter consumes the context even when startup returns an error.
    result = krun_start_enter(ctx);
    kiri_hvf_network_stop();
    return result;

cleanup:
    if (network_fd >= 0) close(network_fd);
    kiri_hvf_network_stop();
    krun_free_ctx(ctx);
    return result;
#undef CHECK
}

int32_t kiri_hvf_run(const char *directory, uint32_t memory_mib, uint8_t cpus,
                    const char *rosetta_directory, const char *docker_directory) {
    return run(directory, memory_mib, cpus, false, "", NULL, 0, rosetta_directory, docker_directory);
}

int32_t kiri_hvf_run_helper(const char *directory, uint32_t memory_mib, uint8_t cpus,
                            const char *share_spec, const char *const *shares, uint8_t share_count,
                            const char *rosetta_directory, const char *docker_directory) {
    return run(directory, memory_mib, cpus, true, share_spec, shares, share_count,
               rosetta_directory, docker_directory);
}
