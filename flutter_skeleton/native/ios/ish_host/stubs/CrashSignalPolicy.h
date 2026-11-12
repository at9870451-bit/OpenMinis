#ifndef AMORE_STUB_CRASH_SIGNAL_POLICY_H
#define AMORE_STUB_CRASH_SIGNAL_POLICY_H
#include <signal.h>
// The kernel re-raises the signal after chaining; nothing to decide here.
static inline void minis_signal_finish(int sig, void *info, void *ctx) {
    (void)sig; (void)info; (void)ctx;
}
#endif
