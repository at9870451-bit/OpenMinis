import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Everything that CANNOT be reimplemented in Flutter.
///
/// The iSH Linux sandbox, the FileProvider extension, the Share extension, the
/// Widget and the Live Activity are native iOS targets. Flutter talks to them
/// through this single channel; the Swift side lives in the retained native
/// project and implements the same method names.
class NativeBridge {
  static const MethodChannel _channel = MethodChannel('amore/native');

  /// True when the app is running inside the native host that implements the
  /// channel (i.e. the merged project). In a bare Flutter build it is false and
  /// every call degrades to a documented fallback instead of crashing.
  Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Boot / query the embedded iSH sandbox.
  Future<SandboxStatus> sandboxStatus() async {
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>('sandbox.status');
      if (map == null) return SandboxStatus.unavailable;
      return SandboxStatus(
        available: map['available'] as bool? ?? false,
        booted: map['booted'] as bool? ?? false,
        rootfsPath: map['rootfsPath'] as String?,
      );
    } on MissingPluginException {
      return SandboxStatus.unavailable;
    } on PlatformException catch (e) {
      return SandboxStatus.unavailable.withError(e.message);
    }
  }

  /// Run a shell command inside the sandbox. Returns stdout+stderr.
  Future<String> runShell(String command) async {
    try {
      final out = await _channel.invokeMethod<String>('sandbox.exec', {
        'command': command,
      });
      return out ?? '';
    } on MissingPluginException {
      return '';
    }
  }

  /// Ask the native side to (re)register the FileProvider domain so the shared
  /// folders appear in the Files app.
  Future<void> registerFileProvider() async {
    try {
      await _channel.invokeMethod<void>('fileProvider.register');
    } on MissingPluginException {
      // Bare Flutter build: nothing to register.
    }
  }

  /// Start / stop a Live Activity (Dynamic Island). Native-only on iOS.
  Future<void> setLiveActivity({required bool active, String? title}) async {
    try {
      await _channel.invokeMethod<void>('liveActivity.set', {
        'active': active,
        'title': title,
      });
    } on MissingPluginException {
      // no-op
    }
  }
}

class SandboxStatus {
  const SandboxStatus({
    required this.available,
    required this.booted,
    this.rootfsPath,
    this.error,
  });

  final bool available;
  final bool booted;
  final String? rootfsPath;
  final String? error;

  static const unavailable = SandboxStatus(available: false, booted: false);

  SandboxStatus withError(String? message) =>
      SandboxStatus(available: available, booted: booted, rootfsPath: rootfsPath, error: message);
}

final nativeBridgeProvider = Provider<NativeBridge>((ref) => NativeBridge());
