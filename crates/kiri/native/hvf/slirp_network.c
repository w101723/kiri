/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Phase-1 libslirp C adapter. See slirp_network.h for the contract.
 *
 * Single in-process pthread running one libslirp (4.9.7) instance,
 * bridged to the VMM side by an AF_UNIX SOCK_STREAM socketpair with
 * 4-byte big-endian length-prefixed Ethernet framing.
 *
 * The worker thread never performs a blocking socket operation:
 *  - guest->adapter reads use recv(MSG_DONTWAIT) with a stateful,
 *    partial-read-tolerant frame assembler;
 *  - adapter->guest frames go through a bounded nonblocking output queue
 *    drained with send(MSG_DONTWAIT); frames are dropped (not blocked on)
 *    once the queue budget is exhausted, which only happens when the
 *    libkrun side is not reading -- TCP retransmits at a lower pace.
 * kiri_hvf_network_stop() wakes the thread through a self-pipe, so it
 * cannot hang behind a stalled guest socket either.
 */
#include "slirp_network.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>

#include <libslirp.h>

#if defined(SLIRP_CHECK_VERSION)
#if !SLIRP_CHECK_VERSION(4, 9, 7)
#error "kiri_hvf_network requires libslirp >= 4.9.7 (SlirpConfig v6 callbacks)"
#endif
#endif

#define KIRI_LOG(fmt, ...) \
    fprintf(stderr, "kiri-slirp: " fmt "\n", ##__VA_ARGS__)

/* Hard bound on one Ethernet frame in either direction. libslirp's default
 * MTU/MRU is 1500 (+ Ethernet overhead); anything larger is rejected so a
 * corrupt or hostile stream can never drive an unbounded allocation or
 * unbounded queueing. */
#define KIRI_MAX_FRAME 65535u

#define KIRI_FRAME_HDR_LEN 4

/* Bounded output queue: drop new frames once either cap is hit. */
#define KIRI_OUT_MAX_BYTES (4u * 1024u * 1024u)
#define KIRI_OUT_MAX_ENTRIES 1024u

/* Max libslirp pollable sockets + guest socketpair end + quit pipe. */
#define KIRI_MAX_POLLFDS 256

/* Fixed poll indices not owned by libslirp. */
#define KIRI_FD_GUEST 0
#define KIRI_FD_QUIT 1

/* Virtual network: 10.0.2.0/24, gateway .2 (as libkrun's other net
 * backends expose), DHCP pool starting at .15, DNS at .3. */
#define KIRI_GUEST_NETMASK "255.255.255.0"

struct kiri_out_entry {
    struct kiri_out_entry *next;
    size_t len; /* total framed bytes: 4 + payload */
    size_t off; /* bytes already handed to the socket */
    uint8_t data[];
};

struct kiri_timer {
    bool active;
    SlirpTimerCb cb;
    void *cb_opaque;
    int64_t expire_ms; /* virtual clock (CLOCK_MONOTONIC) ms */
};

struct kiri_net {
    Slirp *slirp;
    int fd;     /* adapter's socketpair end; the other end went to caller */
    int quit_r; /* self-pipe: stop() wakes poll() here */
    int quit_w;

    atomic_int quit;

    /* Bounded framing output queue (thread-local; stop() only touches it
     * after pthread_join). No lock needed: send_packet and the drain both
     * run on the worker thread. */
    struct kiri_out_entry *out_head;
    struct kiri_out_entry *out_tail;
    size_t out_bytes;
    unsigned out_count;

    /* Incremental, nonblocking frame reader (partial read handling). */
    uint8_t rx_hdr[KIRI_FRAME_HDR_LEN];
    size_t rx_hdr_have; /* 0..KIRI_FRAME_HDR_LEN */
    uint32_t rx_len;    /* frame length, valid once hdr complete */
    uint8_t *rx_buf;    /* static KIRI_MAX_FRAME buffer */
    size_t rx_have;     /* bytes of the frame body received so far */

    /* libslirp timers (IPv6 RA only; IPv6 is disabled, kept for API
     * completeness). libslirp creates at most one of each id. */
    struct kiri_timer timers[SLIRP_TIMER_NUM];

    /* Per-iteration poll set for slirp_pollfds_fill / poll. */
    struct pollfd fds[KIRI_MAX_POLLFDS];
    int nfds;
};

static struct kiri_net g_net; /* phase-1 singleton */
static pthread_t g_thread;
static int g_started;         /* guarded by caller contract */

/* ------------------------------------------------------------------ */
/* time helpers                                                        */
/* ------------------------------------------------------------------ */

static int64_t kiri_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int64_t kiri_now_ms(void)
{
    return kiri_now_ns() / 1000000LL;
}

/* ------------------------------------------------------------------ */
/* bounded framing output queue                                        */
/* ------------------------------------------------------------------ */

static void kiri_out_free_entry(struct kiri_net *n, struct kiri_out_entry *e)
{
    n->out_bytes -= e->len;
    n->out_count--;
    free(e);
}

/* SlirpCb.send_packet: queue one length-prefixed Ethernet frame toward the
 * guest/libkrun side. Never blocks; drops under backpressure (the docs
 * allow dropping; TCP retransmits). Returns len to keep libslirp quiet,
 * -1 only for oversized/malformed frames, which libslirp handles by
 * dropping at the source. */
static slirp_ssize_t kiri_send_packet(const void *buf, size_t len,
                                      void *opaque)
{
    struct kiri_net *n = opaque;

    if (len == 0 || len > KIRI_MAX_FRAME)
        return -1;

    if (n->out_bytes + len + KIRI_FRAME_HDR_LEN > KIRI_OUT_MAX_BYTES ||
        n->out_count >= KIRI_OUT_MAX_ENTRIES) {
        /* Guest side is stalled; drop rather than block. */
        return (slirp_ssize_t)len;
    }

    struct kiri_out_entry *e =
        malloc(KIRI_FRAME_HDR_LEN + len + sizeof(*e));
    if (!e)
        return (slirp_ssize_t)len; /* drop, like backpressure */

    e->next = NULL;
    e->off = 0;
    e->len = KIRI_FRAME_HDR_LEN + len;
    e->data[0] = (uint8_t)(len >> 24);
    e->data[1] = (uint8_t)(len >> 16);
    e->data[2] = (uint8_t)(len >> 8);
    e->data[3] = (uint8_t)len;
    memcpy(e->data + KIRI_FRAME_HDR_LEN, buf, len);

    if (n->out_tail)
        n->out_tail->next = e;
    else
        n->out_head = e;
    n->out_tail = e;
    n->out_bytes += e->len;
    n->out_count++;
    return (slirp_ssize_t)len;
}

/* Hand queued frames to the socket without blocking. */
static void kiri_drain_output(struct kiri_net *n)
{
    while (n->out_head) {
        struct kiri_out_entry *e = n->out_head;
        ssize_t w = send(n->fd, e->data + e->off, e->len - e->off,
                         MSG_DONTWAIT);
        if (w > 0) {
            e->off += (size_t)w;
            if (e->off < e->len)
                return; /* socket full now; POLLOUT resumes us */
            n->out_head = e->next;
            if (!n->out_head)
                n->out_tail = NULL;
            kiri_out_free_entry(n, e);
            continue;
        }
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return;
        /* Hard error (EPIPE: peer gone). Drop the in-flight frame; the
         * EOF/HUP on the read side ends the loop shortly after. */
        n->out_head = e->next;
        if (!n->out_head)
            n->out_tail = NULL;
        kiri_out_free_entry(n, e);
    }
}

/* ------------------------------------------------------------------ */
/* framed input (partial-read tolerant, nonblocking)                   */
/* ------------------------------------------------------------------ */

/* Drain as many bytes as possible from the guest side, assembling frames
 * incrementally. Returns 0 to keep running, -1 when the adapter should
 * shut down (peer closed, protocol violation, IO error). */
static int kiri_read_guest_frames(struct kiri_net *n)
{
    // Yield back to poll so sustained guest TX cannot starve timers or stop.
    for (unsigned i = 0; i < 128 && !atomic_load(&n->quit); i++) {
        if (n->rx_len == 0) {
            /* Still collecting the 4-byte length header. */
            size_t want = KIRI_FRAME_HDR_LEN - n->rx_hdr_have;
            ssize_t r = recv(n->fd, n->rx_hdr + n->rx_hdr_have, want,
                             MSG_DONTWAIT);
            if (r > 0) {
                n->rx_hdr_have += (size_t)r;
                if (n->rx_hdr_have < KIRI_FRAME_HDR_LEN)
                    continue;
                n->rx_len = ((uint32_t)n->rx_hdr[0] << 24) |
                            ((uint32_t)n->rx_hdr[1] << 16) |
                            ((uint32_t)n->rx_hdr[2] << 8) |
                            (uint32_t)n->rx_hdr[3];
                n->rx_hdr_have = 0;
                if (n->rx_len == 0) {
                    KIRI_LOG("zero-length frame, stopping");
                    return -1; /* protocol violation */
                }
                if (n->rx_len > KIRI_MAX_FRAME) {
                    KIRI_LOG("oversized frame %u, stopping", n->rx_len);
                    return -1;
                }
                n->rx_have = 0;
                continue;
            }
            if (r == 0)
                return -1; /* peer (libkrun side) closed */
            if (errno == EINTR)
                continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return 0; /* everything available was consumed */
            KIRI_LOG("recv error: %s", strerror(errno));
            return -1;
        }

        /* Frame body in flight. */
        size_t want = (size_t)n->rx_len - n->rx_have;
        ssize_t r = recv(n->fd, n->rx_buf + n->rx_have, want,
                         MSG_DONTWAIT);
        if (r > 0) {
            n->rx_have += (size_t)r;
            if (n->rx_have < (size_t)n->rx_len)
                continue;
            uint32_t frame_len = n->rx_len;
            n->rx_len = 0;
            n->rx_have = 0;
            slirp_input(n->slirp, n->rx_buf, (int)frame_len);
            continue;
        }
        if (r == 0)
            return -1; /* truncated frame at EOF */
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return 0;
        KIRI_LOG("recv body error: %s", strerror(errno));
        return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* libslirp callbacks                                                  */
/* ------------------------------------------------------------------ */

static void kiri_guest_error(const char *msg, void *opaque)
{
    (void)opaque;
    KIRI_LOG("guest error: %s", msg);
}

static int64_t kiri_clock_get_ns(void *opaque)
{
    (void)opaque;
    return kiri_now_ns();
}

static void *kiri_timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque)
{
    struct kiri_net *n = opaque;
    /* The timer_new path is only used for the IPv6 RA timer, which is not
     * created while in6_enabled == false. Return a slot for any id so no
     * callback can be NULL-dereferenced. */
    struct kiri_timer *t = &n->timers[SLIRP_TIMER_RA];
    t->cb = cb;
    t->cb_opaque = cb_opaque;
    t->active = false;
    return t;
}

static void kiri_timer_free(void *timer, void *opaque)
{
    (void)opaque;
    struct kiri_timer *t = timer;
    if (t)
        t->active = false;
}

/* expire_time is an absolute virtual-clock value in ms. */
static void kiri_timer_mod(void *timer, int64_t expire_time, void *opaque)
{
    (void)opaque;
    struct kiri_timer *t = timer;
    if (!t)
        return;
    t->expire_ms = expire_time;
    t->active = true;
}

static void kiri_notify(void *opaque)
{
    (void)opaque; /* no guestfwd: kept non-NULL for safety */
}

/*
 * Config v6 poll-registration callbacks. The poll set is rebuilt from
 * scratch every iteration via slirp_pollfds_fill_socket(), so tracking
 * registration here is unnecessary -- but the callbacks themselves must
 * NOT be NULL: libslirp 4.9.7 calls slirp_register_poll_socket() /
 * slirp_unregister_poll_socket() unconditionally on socket paths
 * (e.g. udp_attach), and with cfg_version >= 6 a NULL check protects
 * only ... not the v1 path: with NULL fields it falls back to the
 * deprecated cb->register_poll_fd, also NULL here -> segfault. Provide
 * them.
 */
static void kiri_register_poll_socket(slirp_os_socket socket, void *opaque)
{
    (void)socket;
    (void)opaque;
}

static void kiri_unregister_poll_socket(slirp_os_socket socket, void *opaque)
{
    (void)socket;
    (void)opaque;
}

/* ------------------------------------------------------------------ */
/* poll integration                                                    */
/* ------------------------------------------------------------------ */

static int kiri_add_poll(slirp_os_socket fd, int events, void *opaque)
{
    struct kiri_net *n = opaque;

    if (n->nfds >= KIRI_MAX_POLLFDS) {
        KIRI_LOG("too many poll fds");
        return -1;
    }
    short pe = 0;
    if (events & SLIRP_POLL_IN)
        pe |= POLLIN;
    if (events & SLIRP_POLL_OUT)
        pe |= POLLOUT;
    if (events & SLIRP_POLL_PRI)
        pe |= POLLPRI;
    n->fds[n->nfds].fd = (int)fd;
    n->fds[n->nfds].events = pe;
    n->fds[n->nfds].revents = 0;
    return n->nfds++;
}

static int kiri_get_revents(int idx, void *opaque)
{
    struct kiri_net *n = opaque;
    if (idx < 0 || idx >= n->nfds)
        return 0;
    short re = n->fds[idx].revents;
    int ev = 0;
    if (re & POLLIN)
        ev |= SLIRP_POLL_IN;
    if (re & POLLOUT)
        ev |= SLIRP_POLL_OUT;
    if (re & POLLPRI)
        ev |= SLIRP_POLL_PRI;
    if (re & POLLERR)
        ev |= SLIRP_POLL_ERR;
    if (re & POLLHUP)
        ev |= SLIRP_POLL_HUP;
    return ev;
}

static int64_t kiri_next_timer_deadline(struct kiri_net *n)
{
    int64_t best = -1;
    for (int i = 0; i < SLIRP_TIMER_NUM; i++) {
        if (n->timers[i].active &&
            (best < 0 || n->timers[i].expire_ms < best))
            best = n->timers[i].expire_ms;
    }
    return best;
}

static void kiri_fire_due_timers(struct kiri_net *n)
{
    int64_t now = kiri_now_ms();
    for (int i = 0; i < SLIRP_TIMER_NUM; i++) {
        struct kiri_timer *t = &n->timers[i];
        if (t->active && now >= t->expire_ms) {
            t->active = false;
            if (t->cb)
                t->cb(t->cb_opaque);
        }
    }
}

/* ------------------------------------------------------------------ */
/* worker thread                                                       */
/* ------------------------------------------------------------------ */

static void *kiri_net_thread(void *arg)
{
    struct kiri_net *n = arg;
    int running = 1;

    while (running && !atomic_load(&n->quit)) {
        /* fixed indices: 0 = guest socketpair end, 1 = quit pipe */
        n->nfds = 2;
        n->fds[KIRI_FD_GUEST].fd = n->fd;
        n->fds[KIRI_FD_GUEST].events = POLLIN |
            (n->out_head ? POLLOUT : 0);
        n->fds[KIRI_FD_GUEST].revents = 0;
        n->fds[KIRI_FD_QUIT].fd = n->quit_r;
        n->fds[KIRI_FD_QUIT].events = POLLIN;
        n->fds[KIRI_FD_QUIT].revents = 0;

        uint32_t timeout = UINT32_MAX;
        slirp_pollfds_fill_socket(n->slirp, &timeout, kiri_add_poll, n);

        int poll_ms = (timeout == UINT32_MAX) ? -1 : (int)timeout;
        int64_t deadline = kiri_next_timer_deadline(n);
        if (deadline >= 0) {
            int64_t left = deadline - kiri_now_ms();
            if (left < 0)
                left = 0;
            if (poll_ms < 0 || left < poll_ms)
                poll_ms = (int)left;
        }

        int rc = poll(n->fds, (nfds_t)n->nfds, poll_ms);
        if (rc < 0 && errno != EINTR) {
            KIRI_LOG("poll failed: %s", strerror(errno));
            break;
        }

        /* EINTR (rc<0) or a stop request: skip/handle politely. */
        slirp_pollfds_poll(n->slirp, rc < 0, kiri_get_revents, n);
        kiri_fire_due_timers(n);

        if (n->fds[KIRI_FD_QUIT].revents & POLLIN)
            break;

        if (running && (n->fds[KIRI_FD_GUEST].revents & POLLIN)) {
            if (kiri_read_guest_frames(n) < 0)
                running = 0;
        }
        /* Always attempt a drain: frames may have been queued while
         * libslirp or slirp_input was running, independent of POLLOUT
         * level-triggered reporting. */
        if (running)
            kiri_drain_output(n);
        if ((n->fds[KIRI_FD_GUEST].revents & (POLLHUP | POLLERR)) &&
            running) {
            /* Peer closed: one last drain of buffered input, then stop. */
            kiri_read_guest_frames(n);
            running = 0;
        }
    }

    atomic_store(&n->quit, 1);
    return NULL;
}

/* ------------------------------------------------------------------ */
/* config                                                              */
/* ------------------------------------------------------------------ */

static void kiri_fill_config(SlirpConfig *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->version = 6;

    cfg->restricted = 0;        /* NAT to the internet allowed (IPv4) */
    cfg->in_enabled = true;     /* IPv4 */
    cfg->in6_enabled = false;   /* phase 1: IPv4 only */

    inet_pton(AF_INET, "10.0.2.0", &cfg->vnetwork);
    inet_pton(AF_INET, KIRI_GUEST_NETMASK, &cfg->vnetmask);
    inet_pton(AF_INET, "10.0.2.2", &cfg->vhost);
    inet_pton(AF_INET, "10.0.2.15", &cfg->vdhcp_start);
    inet_pton(AF_INET, "10.0.2.3", &cfg->vnameserver);

    cfg->vhostname = "kiri";
    cfg->vdomainname = "lan";

    /* TFTP / bootfile / dnssearch unused: left NULL/empty. */
    cfg->if_mtu = 0;            /* libslirp default (1500) */
    cfg->if_mru = 0;

    cfg->disable_host_loopback = true; /* guest may not reach 127.0.0.1 */
    cfg->enable_emu = false;

    cfg->disable_dns = false;   /* built-in DNS proxy (10.0.2.3) */
    cfg->disable_dhcp = false;  /* built-in DHCP server */

    /* version >= 2: explicit NULL outbound bind addresses */
    cfg->outbound_addr = NULL;
    cfg->outbound_addr6 = NULL;
    /* version >= 5: mfr_id / oob_eth_addr zeroed by memset (no NC-SI) */
}

/* ------------------------------------------------------------------ */
/* public API                                                          */
/* ------------------------------------------------------------------ */

static int kiri_set_nonblock(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl < 0)
        return -1;
    return fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

int kiri_hvf_network_start(int *guest_fd)
{
    if (!guest_fd)
        return -EINVAL;
    if (g_started)
        return -EALREADY;

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0)
        return -errno;

    /* Generous socket buffers on the adapter end; failures are advisory. */
    int bufsz = 4 * 1024 * 1024;
    (void)setsockopt(sv[0], SOL_SOCKET, SO_SNDBUF, &bufsz, sizeof(bufsz));
    (void)setsockopt(sv[0], SOL_SOCKET, SO_RCVBUF, &bufsz, sizeof(bufsz));

    int qp[2];
    if (pipe(qp) < 0) {
        int err = errno;
        close(sv[0]);
        close(sv[1]);
        return -err;
    }
    (void)kiri_set_nonblock(qp[0]);
    (void)kiri_set_nonblock(qp[1]);

    memset(&g_net, 0, sizeof(g_net));
    atomic_init(&g_net.quit, 0);
    g_net.fd = sv[0];
    g_net.quit_r = qp[0];
    g_net.quit_w = qp[1];

    uint8_t *rxbuf = malloc(KIRI_MAX_FRAME);
    if (!rxbuf) {
        int err = errno;
        close(qp[0]);
        close(qp[1]);
        close(sv[0]);
        close(sv[1]);
        return -err;
    }
    g_net.rx_buf = rxbuf;

    SlirpConfig cfg;
    kiri_fill_config(&cfg);

    static const SlirpCb cbs = {
        .send_packet = kiri_send_packet,
        .guest_error = kiri_guest_error,
        .clock_get_ns = kiri_clock_get_ns,
        .timer_new = kiri_timer_new,
        .timer_free = kiri_timer_free,
        .timer_mod = kiri_timer_mod,
        /* Deprecated v1 poll hooks: unused at config version 6 because
         * the version-6 socket hooks below are non-NULL. */
        .notify = kiri_notify,
        /* .init_completed and .timer_new_opaque: NULL by design; both are
         * NULL-checked by libslirp at version >= 4. */
        .register_poll_socket = kiri_register_poll_socket,
        .unregister_poll_socket = kiri_unregister_poll_socket,
    };

    g_net.slirp = slirp_new(&cfg, &cbs, &g_net);
    if (!g_net.slirp) {
        free(rxbuf);
        close(qp[0]);
        close(qp[1]);
        close(sv[0]);
        close(sv[1]);
        return -EINVAL;
    }

    int rc = pthread_create(&g_thread, NULL, kiri_net_thread, &g_net);
    if (rc != 0) {
        slirp_cleanup(g_net.slirp);
        g_net.slirp = NULL;
        free(rxbuf);
        close(qp[0]);
        close(qp[1]);
        close(sv[0]);
        close(sv[1]);
        return -rc;
    }

    g_started = 1;
    *guest_fd = sv[1];
    return 0;
}

void kiri_hvf_network_stop(void)
{
    if (!g_started)
        return;
    g_started = 0;

    /* Never blocks: a single byte into the self-pipe wakes poll(). */
    atomic_store(&g_net.quit, 1);
    ssize_t written;
    do {
        written = write(g_net.quit_w, "q", 1);
    } while (written < 0 && errno == EINTR);

    pthread_join(g_thread, NULL);

    if (g_net.slirp) {
        slirp_cleanup(g_net.slirp);
        g_net.slirp = NULL;
    }
    if (g_net.fd >= 0) {
        close(g_net.fd);
        g_net.fd = -1;
    }
    if (g_net.quit_r >= 0) {
        close(g_net.quit_r);
        g_net.quit_r = -1;
    }
    if (g_net.quit_w >= 0) {
        close(g_net.quit_w);
        g_net.quit_w = -1;
    }
    while (g_net.out_head) {
        struct kiri_out_entry *e = g_net.out_head;
        g_net.out_head = e->next;
        free(e);
    }
    g_net.out_tail = NULL;
    free(g_net.rx_buf);
    g_net.rx_buf = NULL;
}
