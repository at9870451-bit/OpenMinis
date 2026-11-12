#ifndef AMORE_STUB_CRASH_SIGNAL_HANDLER_H
#define AMORE_STUB_CRASH_SIGNAL_HANDLER_H
// Minimal stand-in for the host app's CrashSignalHandler. The Flutter runner has
// no crash-chain machinery; the kernel only needs the two symbols to link.
#include <signal.h>
#include <stdint.h>
static inline void minis_crash_signal_record(int sig, void *info, void *ctx, const char *tag) {
    (void)sig; (void)info; (void)ctx; (void)tag;
}
#endif
