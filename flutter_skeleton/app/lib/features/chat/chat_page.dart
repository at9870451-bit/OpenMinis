import 'package:flutter/material.dart';

import '../../core/theme/amore_theme.dart';
import '../../data/chat_models.dart';
import 'message_bubble.dart';

/// Conversation surface: message list + floating composer.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.messages,
    required this.onSend,
    required this.onOpenSidebar,
    this.placeholder = 'Message Amore',
    this.streaming = false,
  });

  final List<ChatMessage> messages;
  final ValueChanged<String> onSend;
  final VoidCallback onOpenSidebar;
  final String placeholder;
  final bool streaming;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _hasText => _controller.text.trim().isNotEmpty;

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AmoreTheme.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _navBar(),
            Expanded(
              child: widget.messages.isEmpty
                  ? _emptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: widget.messages.length,
                      itemBuilder: (context, i) =>
                          MessageBubble(message: widget.messages[i]),
                    ),
            ),
            _composer(),
          ],
        ),
      ),
    );
  }

  Widget _navBar() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AmoreTheme.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: widget.onOpenSidebar,
            icon: const Icon(Icons.menu, size: 22),
            color: AmoreTheme.textPrimary,
            tooltip: 'History',
          ),
          const Spacer(),
          const Text(
            'Amore',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AmoreTheme.textPrimary,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AmoreTheme.secondaryBackground,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.auto_awesome,
                size: 28, color: AmoreTheme.accent),
          ),
          const SizedBox(height: 16),
          const Text(
            'How can I help?',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: AmoreTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Ask anything, attach a file, or start with @',
            style: TextStyle(fontSize: 14, color: AmoreTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: AmoreTheme.background,
      child: Container(
        decoration: BoxDecoration(
          color: AmoreTheme.glass(0.82),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AmoreTheme.separator, width: 0.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 18,
              offset: Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _circle(Icons.add, onTap: () {}),
            const SizedBox(width: 4),
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.newline,
                style: const TextStyle(
                    fontSize: 16, color: AmoreTheme.textPrimary),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: 'Message Amore',
                  hintStyle: TextStyle(
                      fontSize: 16, color: AmoreTheme.textSecondary),
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            _hasText
                ? _sendButton()
                : _circle(Icons.mic_none, onTap: () {}),
          ],
        ),
      ),
    );
  }

  Widget _sendButton() {
    return GestureDetector(
      onTap: _send,
      child: Container(
        width: 34,
        height: 34,
        decoration: const BoxDecoration(
          color: AmoreTheme.accent,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.arrow_upward, size: 18, color: Colors.white),
      ),
    );
  }

  Widget _circle(IconData icon, {required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(17),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 18, color: AmoreTheme.textSecondary),
      ),
    );
  }
}
