import 'package:flutter_test/flutter_test.dart';

import 'package:amore/core/native/capabilities.dart';
import 'package:amore/core/native/native_bridge.dart';

/// Stage-5 acceptance test: the bridge must degrade gracefully when the native
/// host is absent (bare Flutter build), and the capability manifest must cover
/// every native-only feature so none can be silently dropped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bridge reports unavailable instead of throwing', () async {
    final bridge = NativeBridge();
    expect(await bridge.isAvailable(), isFalse);
    final status = await bridge.sandboxStatus();
    expect(status.available, isFalse);
    expect(await bridge.runShell('echo hi'), '');
  });

  test('capability manifest covers native-only features', () {
    final names = kCapabilities.map((c) => c.name).toList();
    for (final required in [
      'Linux sandbox (iSH)',
      'FileProvider',
      'Share extension',
      'Widget',
      'Live Activity',
      'iCloud sync',
    ]) {
      expect(names.contains(required), isTrue, reason: 'missing $required');
    }
    // Camera and files must NOT be marked native-only — they are plugin work.
    final camera = kCapabilities.firstWhere((c) => c.name == 'Camera');
    expect(camera.layer, CapabilityLayer.plugin);
  });
}
