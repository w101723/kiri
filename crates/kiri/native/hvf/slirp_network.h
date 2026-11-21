/* SPDX-License-Identifier: Apache-2.0 */
/*
 * kiri_hvf_network -- phase-1 in-process libslirp adapter for libkrun.
 *
 * Creates one AF_UNIX SOCK_STREAM socketpair. One end is handed to the
 * caller (to register with libkrun via krun_add_net_unixstream); the other
 * end is driven by an internal pthread that runs a libslirp user-mode
 * network stack (IPv4 only: DHCP, DNS, NAT; host loopback access is
 * disabled; no external proxies or listeners are opened by this adapter).
 *
 * Wire protocol on the stream (both directions), matching libkrun's
 * Unixstream net backend:
 *
 *     [ 4-byte big-endian u32 frame length ][ Ethernet frame ]
 *
 * Only the libslirp public API (libslirp.h) and libc/pthread are used, so
 * the adapter can be compiled and tested in isolation from libkrun.
 */
#ifndef KIRI_HVF_SLIRP_NETWORK_H
#define KIRI_HVF_SLIRP_NETWORK_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Start the adapter.
 *
 * On success returns 0 and sets *guest_fd to the connected stream FD that
 * the caller transfers to libkrun (krun_add_net_unixstream fd argument).
 * Ownership of *guest_fd moves to the caller; kiri_hvf_network_stop() does
 * not close it.
 *
 * On failure returns -errno (e.g. -EMFILE, -ENOBUFS, -EAGAIN, -EINVAL,
 * -EALREADY) and *guest_fd is left untouched. No libslirp state or file
 * descriptors are leaked on failure.
 *
 * Not safe to call concurrently with itself; serialize calls externally.
 */
int kiri_hvf_network_start(int *guest_fd);

/*
 * Stop the adapter started by the previous kiri_hvf_network_start():
 * signal the worker thread, join it, tear down libslirp and close the
 * adapter's socketpair end. Safe to call when not running (no-op).
 * The FD returned from start() is closed by its owner (libkrun side),
 * never here.
 */
void kiri_hvf_network_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* KIRI_HVF_SLIRP_NETWORK_H */
