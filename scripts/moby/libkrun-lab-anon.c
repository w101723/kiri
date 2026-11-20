/*
 * RAM-only libkrun compression/restore test workload (Linux ARM64).
 * The process keeps anonymous pages MAPPED while asking Linux to page them
 * out to a strictly in-RAM zram swap device. It then faults pages back in,
 * verifies their bytes, and releases the allocation. No disk or network.
 *
 * A host Free Page Reporting improvement during ANON_IDLE, without a free()
 * or process exit, is the essential test (not the final idle footprint).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/swap.h>
#include <unistd.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif
#define PAGE_BYTES 4096u
#define ALLOC_MIB 384u
#define ALLOC_BYTES ((size_t)ALLOC_MIB * 1024u * 1024u)

static unsigned long swap_free_kib(void) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (f == NULL) { perror("/proc/meminfo"); exit(2); }
    char line[160];
    unsigned long value = 0;
    int found = 0;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (sscanf(line, "SwapFree: %lu kB", &value) == 1) {
            found = 1;
            break;
        }
    }
    fclose(f);
    if (!found) { fprintf(stderr, "SwapFree missing\n"); exit(2); }
    return value;
}

static void report_stats(void) {
    FILE *f = fopen("/sys/block/zram0/mm_stat", "r");
    if (f != NULL) {
        char buf[256];
        if (fgets(buf, sizeof(buf), f) != NULL) {
            printf("KIRI-LIBKRUN-MEMLAB ZRAM_MM_STAT %s", buf);
            if (strchr(buf, '\n') == NULL) { putchar('\n'); }
        }
        fclose(f);
    }
    printf("KIRI-LIBKRUN-MEMLAB SWAP_FREE_KIB %lu\n", swap_free_kib());
    fflush(stdout);
}

static uint8_t pattern(size_t page) {
    return (uint8_t)(0x31u + (page * 47u) % 199u);
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    // Alpine's BusyBox includes mkswap but omits swapon; use Linux syscall
    // directly so the RAM-only initrd needs no additional shared libraries.
    if (swapon("/dev/zram0", 0) != 0) {
        fprintf(stderr, "swapon /dev/zram0 failed: %s\\n", strerror(errno));
        return 2;
    }
    const unsigned long initial_swap = swap_free_kib();
    if (initial_swap < ALLOC_MIB * 1024u) {
        fprintf(stderr, "Not enough zram swap: %lu KiB\n", initial_swap);
        return 2;
    }
    printf("KIRI-LIBKRUN-MEMLAB ANON_READY\n");
    report_stats();

    uint8_t *mem = mmap(NULL, ALLOC_BYTES, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mem == MAP_FAILED) { perror("mmap anon"); return 2; }
    const size_t pages = ALLOC_BYTES / PAGE_BYTES;
    for (size_t i = 0; i < pages; i++) {
        memset(mem + i * PAGE_BYTES, pattern(i), PAGE_BYTES);
    }
    printf("KIRI-LIBKRUN-MEMLAB ANON_ALLOCATED %uMiB\n", ALLOC_MIB);
    report_stats();
    sleep(12);

    if (madvise(mem, ALLOC_BYTES, MADV_PAGEOUT) != 0) {
        fprintf(stderr, "MADV_PAGEOUT failed: %s\n", strerror(errno));
        return 3;
    }
    printf("KIRI-LIBKRUN-MEMLAB ANON_PAGEOUT\n");
    sleep(3);
    const unsigned long after_swap = swap_free_kib();
    if (initial_swap <= after_swap || initial_swap - after_swap < 64u * 1024u) {
        fprintf(stderr, "Insufficient anonymous swap-out: %lu -> %lu KiB free\n",
                initial_swap, after_swap);
        report_stats();
        return 4;
    }
    printf("KIRI-LIBKRUN-MEMLAB ANON_SWAP_CONFIRMED %luKiB\n",
           initial_swap - after_swap);
    report_stats();
    printf("KIRI-LIBKRUN-MEMLAB ANON_IDLE\n");
    sleep(24);

    volatile uint8_t *probe = mem;
    for (size_t i = 0; i < pages; i++) {
        const size_t offset = i * PAGE_BYTES;
        const uint8_t expected = pattern(i);
        if (probe[offset] != expected || probe[offset + 2048u] != expected ||
            probe[offset + PAGE_BYTES - 1u] != expected) {
            fprintf(stderr, "Anonymous memory corrupted after zram restore: page %zu\n", i);
            return 5;
        }
    }
    printf("KIRI-LIBKRUN-MEMLAB ANON_RESTORED\n");
    report_stats();
    sleep(16);

    if (munmap(mem, ALLOC_BYTES) != 0) { perror("munmap"); return 6; }
    printf("KIRI-LIBKRUN-MEMLAB ANON_FREED\n");
    report_stats();
    while (1) { sleep(30); }
    return 0;
}
