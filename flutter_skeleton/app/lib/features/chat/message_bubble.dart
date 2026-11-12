import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import '../../data/chat_models.dart';

/// User messages are right-aligned light-grey bubbles; assistant messages are
/// plain text on the page background (ChatGPT behaviour).
class MessageBubble extends StatelessWidget {
  const MessageBubble({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(top: 6, bottom: 6, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AmoreTheme.secondaryBackground,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            message.text,
            style: const TextStyle(
              fontSize: 16,
              height: 1.35,
              color: AmoreTheme.textPrimary,
            ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10, bottom: 10, right: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.text.isEmpty && message.streaming ? '…' : message.text,
            style: const TextStyle(
              fontSize: 16,
              height: 1.45,
              color: AmoreTheme.textPrimary,
            ),
          ),
          if (message.streaming)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: AmoreTheme.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
