/*
 * Experimental libkrun 2.0 RAM reclamation laboratory, Apple Silicon only.
 *
 * This process boots an ISOLATED VM with caller-provided RAM-only initramfs:
 * no disk, no networking, no Docker sockets, no Mac host folder shares.
 *
 * Requires an independently verified, pinned, trusted ARM64 libkrun 2.0
 * dylib and a Linux ARM64 kernel with CONFIG_VIRTIO_MMIO,
 * CONFIG_VIRTIO_BALLOON and CONFIG_PAGE_REPORTING enabled.
 *
 *   clang -std=c11 -Wall -Wextra -Werror -arch arm64 \
 *      -o /tmp/kiri-libkrun-ram-lab scripts/moby/libkrun2-ram-lab.c
 *   /tmp/kiri-libkrun-ram-lab /absolute/trusted/libkrun.dylib \
 *      /absolute/mmio/Image /absolute/lab/initramfs.cpio
 *
 * To measure: compare the process resident footprint while the lab init
 * allocates/releases tmpfs pages. A successful boot ALONE proves nothing
 * about physical memory reclamation. This is deliberately not integrated
 * into Kiri.app or the production Docker engine.
 */

#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void *Handle;
typedef struct {
    const char *data;
    size_t len;
} KrunStr;

#define KRUN_STR(s) ((KrunStr){ (s), strlen(s) })
#define RAW_ARM64_IMAGE 1u

static void *required_symbol(void *lib, const char *name) {
    (void)dlerror();
    void *symbol = dlsym(lib, name);
    if (symbol == NULL) {
        const char *error = dlerror();
        fprintf(stderr, "Missing libkrun2 API %s: %s\n", name,
                error == NULL ? "not exported" : error);
        exit(2);
    }
    return symbol;
}

/* A symbol's pointer representation equals a function pointer on macOS.
 * memcpy avoids forbidden ISO C function-pointer casts under -Werror. */
#define REQUIRE(name) do {                                        \
    void *address = required_symbol(lib, #name);                  \
    _Static_assert(sizeof(name) == sizeof(address),              \
                   "Function pointer size must equal data pointer size"); \
    memcpy(&name, &address, sizeof(name));                        \
} while (0)

static int failed(Handle error, const char *stage) {
    if (error == NULL) { return 0; }
    fprintf(stderr, "libkrun2 error during %s (see libkrun stderr)\n", stage);
    return 1;
}

int main(int argc, char **argv) {
#if !defined(__APPLE__) || !defined(__aarch64__)
    (void)argc; (void)argv;
    fprintf(stderr, "The libkrun RAM lab runs on macOS arm64 only.\n");
    return 2;
#else
    if (argc != 4 || argv[1][0] != '/' || argv[2][0] != '/' || argv[3][0] != '/') {
        fprintf(stderr,
            "Usage: %s /absolute/libkrun.dylib /absolute/mmio/Image /absolute/lab/initramfs.cpio\n",
            argv[0]);
        return 2;
    }
    // Baseline and Replace use identical Guest/payload/allocator conditions.
    // This is an experimental knob, never exposed in Kiri's production UI.
    const char *mode_name = getenv("KIRI_LIBKRUN_REPORTING_MODE");
    if (mode_name == NULL || mode_name[0] == '\0') { mode_name = "replace"; }
    if (strcmp(mode_name, "replace") != 0 && strcmp(mode_name, "default") != 0) {
        fprintf(stderr, "KIRI_LIBKRUN_REPORTING_MODE must be default or replace\n");
        return 2;
    }
    const uint32_t mode = strcmp(mode_name, "replace") == 0 ? 1u : 0u;
    const char *workload = getenv("KIRI_LIBKRUN_WORKLOAD");
    if (workload == NULL || workload[0] == '\0') { workload = "tmpfs"; }
    if (strcmp(workload, "tmpfs") != 0 &&
        strcmp(workload, "anon-zram") != 0) {
        fprintf(stderr, "KIRI_LIBKRUN_WORKLOAD must be tmpfs or anon-zram\n");
        return 2;
    }
    // Never permit a "convenience" path to the user's existing writable
    // Kiri VM data disk. This runner has NO block-device API at all.
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) {
        fprintf(stderr, "Could not load trusted libkrun2 dylib: %s\n", dlerror());
        return 2;
    }

    // libkrun sends hvc0 to the log target when stdout is redirected
    // (the measurement harness runs without a host TTY). Enable that sink.
    uint64_t (*krun_init_log)(int, uint32_t, uint32_t, uint32_t, Handle *) = NULL;
    Handle (*krun_mmio_device_manager_new)(void) = NULL;
    void (*krun_mmio_device_manager_add)(Handle, Handle) = NULL;
    Handle (*krun_console_device_builder)(void) = NULL;
    uint64_t (*krun_console_builder_add_default_console)(
        Handle, int, int, int, Handle *) = NULL;
    Handle (*krun_console_builder_build)(Handle, Handle *) = NULL;
    Handle (*krun_balloon_device_new)(Handle *) = NULL;
    void (*krun_balloon_device_set_free_page_reporting_mode)(
        Handle, uint32_t) = NULL;
    Handle (*krun_rng_device_new)(Handle *) = NULL;
    Handle (*krun_payload_load_external)(
        KrunStr, uint32_t, KrunStr, KrunStr, Handle *) = NULL;
    Handle (*krun_vmm_builder_new)(void) = NULL;
    uint64_t (*krun_vmm_builder_vcpus)(Handle *, uint8_t, Handle *) = NULL;
    uint64_t (*krun_vmm_builder_ram_mib)(Handle *, uint32_t, Handle *) = NULL;
    void (*krun_vmm_builder_payload)(Handle *, Handle) = NULL;
    void (*krun_vmm_builder_devices)(Handle *, Handle) = NULL;
    Handle (*krun_vmm_builder_build)(Handle *, Handle *) = NULL;
    void (*krun_vmm_run)(Handle) = NULL;

    REQUIRE(krun_init_log);
    REQUIRE(krun_mmio_device_manager_new);
    REQUIRE(krun_mmio_device_manager_add);
    REQUIRE(krun_console_device_builder);
    REQUIRE(krun_console_builder_add_default_console);
    REQUIRE(krun_console_builder_build);
    REQUIRE(krun_balloon_device_new);
    REQUIRE(krun_balloon_device_set_free_page_reporting_mode);
    REQUIRE(krun_rng_device_new);
    REQUIRE(krun_payload_load_external);
    REQUIRE(krun_vmm_builder_new);
    REQUIRE(krun_vmm_builder_vcpus);
    REQUIRE(krun_vmm_builder_ram_mib);
    REQUIRE(krun_vmm_builder_payload);
    REQUIRE(krun_vmm_builder_devices);
    REQUIRE(krun_vmm_builder_build);
    REQUIRE(krun_vmm_run);

    Handle error = NULL;
    // Log level ERROR also captures kernel/Guest hvc0 lines: libkrun's
    // non-TTY console routes them to target "init_or_kernel" at ERROR level.
    // Without krun_init_log(), guest.log contains only this runner's stderr.
    // NO_ENV=1 keeps RUST_LOG from silently suppressing console output.
    uint64_t log_result = krun_init_log(-1, 1u, 2u, 1u, &error);
    if (failed(error, "console logger setup") || log_result != 0) {
        fprintf(stderr, "Could not enable libkrun hvc0 log sink (result=%llu)\n",
                (unsigned long long)log_result);
        return 1;
    }
    Handle devices = krun_mmio_device_manager_new();
    if (devices == NULL) {
        fprintf(stderr, "Could not create MMIO device manager\n");
        return 1;
    }
    Handle console_builder = krun_console_device_builder();
    krun_console_builder_add_default_console(
        console_builder, STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO, &error);
    if (failed(error, "console setup")) { return 1; }
    Handle console = krun_console_builder_build(console_builder, &error);
    if (failed(error, "console build") || console == NULL) { return 1; }
    krun_mmio_device_manager_add(devices, console); // takes ownership

    Handle balloon = krun_balloon_device_new(&error);
    if (failed(error, "balloon create") || balloon == NULL) { return 1; }
    krun_balloon_device_set_free_page_reporting_mode(
        balloon, mode);
    krun_mmio_device_manager_add(devices, balloon); // takes ownership

    Handle rng = krun_rng_device_new(&error);
    if (failed(error, "rng create") || rng == NULL) { return 1; }
    krun_mmio_device_manager_add(devices, rng); // takes ownership

    // No storage or networking devices are attached. The initrd must have
    // its own /init executable and in-RAM root, not Kiri's ext4 /dev/vda init.
    const char *cmdline = strcmp(workload, "anon-zram") == 0
        ? "console=hvc0 rdinit=/init panic=-1 loglevel=5 zswap.enabled=0 kiri.lab.workload=anon-zram"
        : "console=hvc0 rdinit=/init panic=-1 loglevel=5";
    Handle payload = krun_payload_load_external(
        KRUN_STR(argv[2]), RAW_ARM64_IMAGE, KRUN_STR(argv[3]),
        KRUN_STR(cmdline), &error);
    if (failed(error, "payload load") || payload == NULL) { return 1; }

    Handle builder = krun_vmm_builder_new();
    if (builder == NULL) { return 1; }
    krun_vmm_builder_vcpus(&builder, 2, &error);
    if (failed(error, "vcpus")) { return 1; }
    krun_vmm_builder_ram_mib(&builder, 2048, &error);
    if (failed(error, "RAM")) { return 1; }
    krun_vmm_builder_payload(&builder, payload);
    krun_vmm_builder_devices(&builder, devices);
    Handle vmm = krun_vmm_builder_build(&builder, &error);
    if (failed(error, "VMM build") || vmm == NULL) { return 1; }

    fprintf(stderr,
        "Experimental isolated libkrun2 VM: pid=%ld, 2048MiB max, free-page mode=%s, workload=%s.\n"
        "Compare macOS Physical footprint before, during and after Guest allocation.\n"
        "No Kiri Docker VM disk or container state is mounted.\n",
        (long)getpid(), mode_name, workload);
    fflush(stderr);
    krun_vmm_run(vmm);
    fprintf(stderr, "libkrun2 VM exited without a memory reclamation result.\n");
    dlclose(lib);
    return 0;
#endif
}
