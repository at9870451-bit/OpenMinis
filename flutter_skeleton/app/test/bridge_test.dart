import 'package:flutter_test/flutter_test.dart';
import 'package:amore/src/rust/api/simple.dart';

/// This is the stage-1 acceptance test: it only passes if the Dart -> Rust
/// bridge is genuinely generated, linked and callable.
void main() {
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
