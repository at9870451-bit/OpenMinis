import 'package:flutter_test/flutter_test.dart';
import 'package:amore/src/rust/frb_generated.dart';
import 'package:amore/src/rust/api/simple.dart';

/// Stage-1 acceptance test: passes only if the Dart -> Rust bridge is really
/// generated, linked and callable on this machine.
void main() {
  setUpAll(() async {
    // Loads the native library (libamore_core.dylib on macOS) and initialises
    // the frb dispatcher.
    await RustLib.init();
  });

  test('greet round-trips through Rust', () {
    expect(greet(name: 'Amore'), 'Hello, Amore! — from Rust');
  });

  test('digest_session parses JSON in Rust', () async {
    final d = await digestSession(
      json: '{"title":"迁移测试","messages":[{"content":"你好"},{"content":"hello"}]}',
    );
    expect(d.title, '迁移测试');
    expect(d.messageCount, 2);
    expect(d.charCount, 7);
  });
}
