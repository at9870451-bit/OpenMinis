import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/chat_models.dart';
import '../../data/chat_repository.dart';
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
  ChatController({ChatTransport? transport, ChatRepository? repository})
      : _transport = transport,
        _repository = repository,
        super(ChatState());

  ChatTransport? _transport;
  ChatRepository? _repository;
  CancelTokenHolder? _cancel;

  /// Currently opened session (null = a brand new, unsaved chat).
  String? sessionId;

  void configure(ChatTransport transport) => _transport = transport;

  void attachRepository(ChatRepository repository) => _repository = repository;

  /// Load a conversation from the database.
  Future<void> openSession(String id) async {
    sessionId = id;
    final repo = _repository;
    if (repo == null) return;
    final loaded = await repo.messages(id);
    state = ChatState(messages: loaded);
  }

  /// Start a fresh conversation (no row written until the first message).
  void newChat() {
    sessionId = null;
    state = ChatState();
  }

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

    final repo = _repository;
    var sid = sessionId;
    if (repo != null) {
      sid ??= 's-${now.microsecondsSinceEpoch}';
      sessionId = sid;
      await repo.createSession(sid, title: text.trim());
      await repo.upsertMessage(userMsg.copyWithSession(sid, 0));
      await repo.upsertMessage(assistantMsg.copyWithSession(sid, 1));
    }

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

  /// Drops the trailing assistant reply (and its question) and asks again —
  /// the behaviour of the SwiftUI "重新生成" action.
  Future<void> regenerateLast() async {
    if (state.streaming) return;
    final msgs = [...state.messages];
    while (msgs.isNotEmpty && msgs.last.role == 'assistant') {
      msgs.removeLast();
    }
    if (msgs.isEmpty || msgs.last.role != 'user') return;
    final question = msgs.removeLast().text;
    state = state.copyWith(messages: msgs);
    await send(question);
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
    final repo = _repository;
    final sid = sessionId;
    if (repo != null && sid != null) {
      final msg = next.firstWhere((m) => m.id == id, orElse: () => next.last);
      unawaited(repo.upsertMessage(msg));
      unawaited(repo.touchSession(sid));
    }
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
