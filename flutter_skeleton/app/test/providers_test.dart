import 'package:flutter_test/flutter_test.dart';

import 'package:amore/src/rust/api/providers.dart';
import 'package:amore/src/rust/frb_generated.dart';

/// Stage-4 acceptance test: the provider catalog and request builder are served
/// by Rust, and the shapes match what the HTTP layer expects.
void main() {
  setUpAll(() async => RustLib.init());

  test('catalog comes from Rust', () async {
    final providers = await listProviders();
    expect(providers.length, greaterThanOrEqualTo(6));
    expect(providers.any((p) => p.id == 'openAI'), isTrue);
    expect(providers.any((p) => p.id == 'anthropic'), isTrue);
  });

  test('openAI request is built in Rust', () async {
    final spec = await buildChatRequest(
      providerId: 'openAI',
      apiKey: 'sk-test',
      model: 'gpt-4o',
      turns: [ChatTurn(role: 'user', content: 'hi')],
      stream: true,
    );
    expect(spec.url, 'https://api.openai.com/v1/chat/completions');
    expect(spec.headers.any((h) => h.name == 'Authorization'), isTrue);
    expect(spec.bodyJson.contains('"stream":true'), isTrue);
  });

  test('stream deltas are parsed in Rust', () async {
    final delta = await parseStreamDelta(
      providerId: 'openAI',
      line: 'data: {"choices":[{"delta":{"content":"你好"}}]}',
    );
    expect(delta, '你好');
  });

  test('missing key is rejected, never silently sent', () async {
    expect(
      () => buildChatRequest(
        providerId: 'openAI',
        apiKey: '',
        model: 'gpt-4o',
        turns: [],
        stream: true,
      ),
      throwsA(isA<Object>()),
    );
  });
}
