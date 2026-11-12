import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:amore/data/chat_transport.dart';
import 'package:amore/features/chat/chat_controller.dart';

/// A fake transport used ONLY in tests. The app itself always talks to a real
/// endpoint (see SseChatTransport) — no fake data ships in the product.
class _FakeTransport implements ChatTransport {
  _FakeTransport(this.chunks, {this.delay = Duration.zero});

  final List<String> chunks;
  final Duration delay;

  @override
  Stream<String> stream({
    required List<Map<String, String>> messages,
    CancelToken? cancelToken,
  }) async* {
    for (final c in chunks) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      yield c;
    }
  }
}

void main() {
  test('streaming replaces the same message instead of appending', () async {
    final controller = ChatController(
      transport: _FakeTransport(['你', '好', '，', '世界']),
    );

    final future = controller.send('hi');
    // Immediately after send: user message + ONE assistant placeholder.
    expect(controller.state.messages.length, 2);
    expect(controller.state.streaming, isTrue);

    await future;

    // Length is still 2 — tokens were merged into the same bubble. This is the
    // "列表不跳动" requirement, asserted rather than eyeballed.
    expect(controller.state.messages.length, 2);
    expect(controller.state.messages.last.text, '你好，世界');
    expect(controller.state.streaming, isFalse);
    expect(controller.state.error, isNull);
  });

  test('empty input is ignored', () async {
    final controller = ChatController(transport: _FakeTransport(['x']));
    await controller.send('   ');
    expect(controller.state.messages, isEmpty);
  });

  test('missing transport surfaces a retryable error, never a silent answer',
      () async {
    final controller = ChatController();
    await controller.send('hi');
    expect(controller.state.messages.last.text, contains('No model configured'));
    expect(controller.state.streaming, isFalse);
    expect(controller.state.error, isNotNull);
  });
}
