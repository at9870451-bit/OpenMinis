import 'dart:ffi';
import 'dart:io';

/// Runtime proof that the iSH kernel archives are linked into this binary.
///
/// `ISHHost.framework` (a local pod) force-loads `libish.a` and exposes
/// `amore_ish_link_probe`, so the symbol resolves through `dlsym` only when the
/// static libraries really made it into the app. On a bare Flutter build (or in
/// unit tests on macOS) the lookup returns null and the caller degrades.
class IshProbe {
  static String? _cached;

  /// e.g. "ish-static-libs-linked", or null when the host is absent.
  static String? linkedMarker() {
    if (_cached != null) return _cached;
    if (!Platform.isIOS) return null;
    try {
      final lib = DynamicLibrary.process();
      final fn = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'amore_ish_link_probe',
      );
      final ptr = fn();
      if (ptr == nullptr) return null;
      _cached = ptr.toDartString();
      return _cached;
    } catch (_) {
      // Symbol not present: the sandbox host is not part of this binary.
      return null;
    }
  }

  static bool get isLinked => linkedMarker() != null;
}
