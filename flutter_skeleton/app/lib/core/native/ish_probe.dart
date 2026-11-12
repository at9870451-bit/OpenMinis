import 'dart:ffi';
import 'dart:io';

/// Runtime proof that the iSH kernel archives are linked into this binary.
///
/// `ISHHost.framework` (a local pod) force-loads `libish.a` and exposes
/// `amore_ish_link_probe`, so the symbol resolves only when the static
/// libraries really made it into the app. On a bare Flutter build (or in unit
/// tests on macOS) the lookup returns null and the caller degrades.
class IshProbe {
  static String? _cached;
  static bool _probed = false;

  /// e.g. "ish-static-libs-linked", or null when the host is absent.
  static String? linkedMarker() {
    if (_probed) return _cached;
    _probed = true;
    if (!Platform.isIOS) return null;
    try {
      final fn = DynamicLibrary.process()
          .lookup<NativeFunction<Pointer<Int8> Function()>>(
              'amore_ish_link_probe')
          .asFunction<Pointer<Int8> Function()>();
      final ptr = fn();
      if (ptr == nullptr) return null;
      _cached = _readCString(ptr);
      return _cached;
    } catch (_) {
      // Symbol not present: the sandbox host is not part of this binary.
      return null;
    }
  }

  static bool get isLinked => linkedMarker() != null;

  /// Reads a NUL-terminated UTF-8 string without depending on package:ffi.
  static String _readCString(Pointer<Int8> ptr) {
    final bytes = <int>[];
    var i = 0;
    while (true) {
      final byte = ptr.elementAt(i).value;
      if (byte == 0) break;
      bytes.add(byte & 0xFF);
      i++;
      if (i > 4096) break; // defensive: never loop on a bad pointer
    }
    return String.fromCharCodes(bytes);
  }
}
