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
