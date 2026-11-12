/// Local message model — mirrors `messages` in the legacy schema.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
    this.sortOrder = 0,
    this.streaming = false,
  });

  final String id;
  final String sessionId;
  final String role; // user | assistant
  final String text;
  final DateTime createdAt;
  final int sortOrder;
  final bool streaming;

  bool get isUser => role == 'user';

  ChatMessage copyWith({String? text, bool? streaming}) => ChatMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        text: text ?? this.text,
        createdAt: createdAt,
        sortOrder: sortOrder,
        streaming: streaming ?? this.streaming,
      );
}

class ChatSessionSummary {
  ChatSessionSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
}
