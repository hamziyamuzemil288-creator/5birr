import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Msg {
  final String role; // 'user' | 'assistant'
  final String content;
  const _Msg(this.role, this.content);
}

class HelpChatScreen extends StatefulWidget {
  const HelpChatScreen({super.key});

  @override
  State<HelpChatScreen> createState() => _HelpChatScreenState();
}

class _HelpChatScreenState extends State<HelpChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _messages = [
    const _Msg('assistant', 'Hi! Ask me anything about how to use the app.'),
  ];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() {
      _messages.add(_Msg('user', text));
      _sending = true;
      _controller.clear();
    });
    _scrollToEnd();

    String reply;
    try {
      // Skip the local greeting so history starts with a user turn.
      final history = _messages
          .skip(1)
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();
      final res = await Supabase.instance.client.functions
          .invoke('repo-chat', body: {'messages': history});
      reply = (res.data as Map)['reply'] as String? ??
          'Sorry, something went wrong. Please try again.';
    } on FunctionException catch (e) {
      reply = e.status == 429
          ? "You've reached today's help limit. Please try again tomorrow."
          : 'Sorry, help is unavailable right now. Please try again.';
    } catch (_) {
      reply = 'Sorry, something went wrong. Please try again.';
    }

    if (!mounted) return;
    setState(() {
      _messages.add(_Msg('assistant', reply));
      _sending = false;
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == _messages.length) {
                  return const Padding(
                    padding: EdgeInsets.all(8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final m = _messages[i];
                final isUser = m.role == 'user';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.8,
                    ),
                    decoration: BoxDecoration(
                      color: isUser
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: SelectableText(m.content),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Ask a question…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
