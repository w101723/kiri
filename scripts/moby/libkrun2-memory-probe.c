/*
 * Kiri/libkrun v2 experimental ABI capability probe (macOS Apple Silicon).
 *
 * Does not boot a VM, change Kiri's active VMM, touch any disk, load guest
 * content or claim host physical-memory reclaim. It checks that a user-
 * supplied libkrun 2.x dylib has the required free-page reporting symbols.
 *
 * Build: clang -std=c11 -Wall -Wextra -Werror -arch arm64 -o /tmp/kiri-libkrun-probe \
 *              scripts/moby/libkrun2-memory-probe.c
 * Run:   /tmp/kiri-libkrun-probe /absolute/path/to/libkrun.dylib
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

static int verify_symbol(void *library, const char *symbol) {
    (void)dlerror(); // clear a previous lookup error
    if (dlsym(library, symbol) == NULL) {
        const char *error = dlerror();
        fprintf(stderr, "MISSING: %s%s%s\n", symbol, error ? ": " : "",
                error ? error : "");
        return 0;
    }
    printf("FOUND: %s\n", symbol);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') {
        fprintf(stderr, "Usage: %s /absolute/path/to/libkrun.dylib\n", argv[0]);
        return 2;
    }

    // Loading a library executes its initializers. Only use a trusted,
    // independently pinned, code-signed dylib; never read a random path.
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "Cannot load libkrun: %s\n", dlerror());
        return 1;
    }
    const char *required[] = {
        "krun_balloon_device_new",
        "krun_balloon_device_set_free_page_reporting_mode",
        "krun_balloon_device_destroy",
        "krun_vmm_builder_new",
        "krun_payload_load_external"
    };
    int ok = 1;
    for (size_t i = 0; i < sizeof(required)/sizeof(required[0]); i++) {
        if (!verify_symbol(library, required[i])) {
            ok = 0;
        }
    }
    dlclose(library);
    if (!ok) {
        fprintf(stderr,
                "libkrun v2 Replace-mode prerequisites missing; do not switch Kiri VM.\n");
        return 1;
    }
    printf("libkrun v2 ABI symbols available. Free-page replacement NOT yet tested.\n");
    printf("Next gate: isolated ARM64 Guest boot + macOS physical memory measurements.\n");
    return 0;
}
