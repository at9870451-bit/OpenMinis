#include "ISHHost.h"
#include <stdio.h>

const char *amore_ish_link_probe(void) {
    return "ish-static-libs-linked";
}

long amore_ish_vdso_size(void) {
    // The real host reads Resources/libvdso.so.elf; here we only verify the
    // bundle lookup path compiles and links inside the Flutter runner.
    FILE *f = fopen("libvdso.so.elf", "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fclose(f);
    return n;
}

// MARK: - Host diagnostics shims
//
// ISHKernel.m records two counters into the app's diagnostics pipeline. The
// Flutter runner has no such pipeline, so these are no-ops — but they must
// exist or the kernel object fails to link.

void minis_diag_note_guest_fork(void) {}
void minis_diag_note_task_info_call(void) {}
