import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_models.dart';
import '../../data/chat_transport.dart';

/// Holds the conversation currently on screen and owns the streaming state.
///
/// Design note: the assistant message object is REPLACED in the list (same id)
/// rather than appended per token, so the list never grows during streaming —
/// that is what keeps the scroll position stable (the "no jumping" requirement).
class ChatState {
  ChatState({
    this.messages = const [],
    this.streaming = false,
    this.error,
  });

  final List<ChatMessage> messages;
  final bool streaming;
  final String? error;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? streaming,
    String? error,
    bool clearError = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        streaming: streaming ?? this.streaming,
        error: clearError ? null : (error ?? this.error),
      );
}

class ChatController extends StateNotifier<ChatState> {
  ChatController({ChatTransport? transport})
      : _transport = transport,
        super(ChatState());

  ChatTransport? _transport;
  CancelTokenHolder? _cancel;

  void configure(ChatTransport transport) => _transport = transport;

  Future<void> send(String text) async {
    if (text.trim().isEmpty || state.streaming) return;

    final now = DateTime.now();
    final userMsg = ChatMessage(
      id: 'u-${now.microsecondsSinceEpoch}',
      sessionId: 'local',
      role: 'user',
      text: text.trim(),
      createdAt: now,
    );
    final assistantId = 'a-${now.microsecondsSinceEpoch}';
    final assistantMsg = ChatMessage(
      id: assistantId,
      sessionId: 'local',
      role: 'assistant',
      text: '',
      createdAt: now,
      streaming: true,
    );

    state = state.copyWith(
      messages: [...state.messages, userMsg, assistantMsg],
      streaming: true,
      clearError: true,
    );

    final transport = _transport;
    if (transport == null) {
      _fail(assistantId, 'No model configured. Add a provider in Settings.');
      return;
    }

    final holder = CancelTokenHolder();
    _cancel = holder;
    final history = [
      for (final m in state.messages.where((m) => m.id != assistantId))
        {'role': m.role, 'content': m.text},
    ];

    try {
      await for (final delta in transport.stream(
        messages: history,
        cancelToken: holder.token,
      )) {
        _appendTo(assistantId, delta);
      }
      _finish(assistantId);
    } catch (e) {
      _fail(assistantId, '$e');
    }
  }

  void stop() {
    _cancel?.cancel();
    _cancel = null;
    final streamingMsg = state.messages.where((m) => m.streaming).toList();
    for (final m in streamingMsg) {
      _finish(m.id);
    }
  }

  void _appendTo(String id, String delta) {
    final next = [
      for (final m in state.messages)
        if (m.id == id) m.copyWith(text: m.text + delta) else m,
    ];
    state = state.copyWith(messages: next);
  }

  void _finish(String id) {
    final next = [
      for (final m in state.messages)
        if (m.id == id) m.copyWith(streaming: false) else m,
    ];
    state = state.copyWith(messages: next, streaming: false);
  }

  void _fail(String id, String message) {
    final next = [
      for (final m in state.messages)
        if (m.id == id)
          m.copyWith(text: '⚠️ $message', streaming: false)
        else
          m,
    ];
    state = state.copyWith(messages: next, streaming: false, error: message);
  }
}

class CancelTokenHolder {
  final token = CancelToken();
  void cancel() => token.cancel('user stopped');
}
