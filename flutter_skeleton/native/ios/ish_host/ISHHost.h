#ifndef ISH_HOST_H
#define ISH_HOST_H

/// Returns a marker string once the iSH archives are linked into the process.
/// The Dart side uses it as a cheap "is the sandbox host present?" probe.
const char *amore_ish_link_probe(void);

/// Number of bytes reserved for the guest VDSO that ships in the app bundle
/// (0 when the resource is missing). Proves the resource pipeline works too.
long amore_ish_vdso_size(void);

#endif
