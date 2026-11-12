import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Real SSE transport for OpenAI-compatible `/chat/completions` streaming.
/// No fake data: if no endpoint/key is configured the caller surfaces an error.
class SseChatTransport {
  SseChatTransport({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  final String baseUrl;
  final String apiKey;
  final String model;
  final Dio _dio;

  /// Emits content deltas as they arrive. Throwing on HTTP/transport failure is
  /// deliberate — the UI turns it into a retryable message, never a silent
  /// empty answer.
  Stream<String> stream({
    required List<Map<String, String>> messages,
    CancelToken? cancelToken,
  }) async* {
    final response = await _dio.post<ResponseBody>(
      '$baseUrl/chat/completions',
      data: {
        'model': model,
        'messages': messages,
        'stream': true,
      },
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
      ),
      cancelToken: cancelToken,
    );

    final body = response.data;
    if (body == null) {
      throw StateError('empty response body');
    }

    var buffer = '';
    await for (final chunk in body.stream) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      while (true) {
        final idx = buffer.indexOf('\n');
        if (idx < 0) break;
        final line = buffer.substring(0, idx).trim();
        buffer = buffer.substring(idx + 1);
        if (line.isEmpty || !line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') return;
        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          final choices = json['choices'];
          if (choices is List && choices.isNotEmpty) {
            final delta = (choices.first as Map)['delta'];
            if (delta is Map && delta['content'] is String) {
              yield delta['content'] as String;
            }
          }
        } catch (_) {
          // A malformed keep-alive chunk must not abort the whole stream.
        }
      }
    }
  }
}
