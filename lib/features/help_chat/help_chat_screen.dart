import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Human-support contact points shown whenever the assistant can't help.
/// Mirrors the constants in supabase/functions/repo-chat/index.ts.
const String _kSupportWhatsAppDisplay = '0917686990';
const String _kSupportWhatsAppUrl = 'https://wa.me/251917686990';
const String _kSupportEmail = 'muktarbiya329@gmail.com';

class _Msg {
  final String role; // 'user' | 'assistant'
  final String content;
  final bool handoff; // true → render tappable WhatsApp/email actions
  const _Msg(this.role, this.content, {this.handoff = false});
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
    const _Msg(
        'assistant',
        'Hi! 👋 I\'m the Aliob assistant. I can help with registering, buying '
        'and orders, escrow and payments, wallet recharges, fees, points, '
        'and rides.\n\nWhat can I help you with today?'),
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
    bool handoff = false;
    try {
      // Skip the local greeting so history starts with a user turn.
      final history = _messages
          .skip(1)
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();
      final res = await Supabase.instance.client.functions
          .invoke('repo-chat', body: {'messages': history});
      final data = res.data as Map?;
      reply = data?['reply'] as String? ??
          'Sorry, something went wrong. Please try again.';
      handoff = data?['handoff'] == true;
    } on FunctionException catch (e) {
      reply = e.status == 429
          ? "You've reached today's help limit. Please try again tomorrow."
          : 'Sorry, help is unavailable right now. Please try again.';
    } catch (_) {
      reply = 'Sorry, something went wrong. Please try again.';
    }

    if (!mounted) return;
    setState(() {
      _messages.add(_Msg('assistant', reply, handoff: handoff));
      _sending = false;
    });
    _scrollToEnd();
  }

  Future<void> _launchSupportLink(String raw) async {
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $raw — the address is copied in the message above.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open $raw — the address is shown in the message above.')),
        );
      }
    }
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

  /// Tappable contact chip rendered under handoff messages.
  Widget _supportButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
    );
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SelectableText(m.content),
                        if (m.handoff) ...[
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _supportButton(
                                icon: Icons.chat,
                                label: 'WhatsApp $_kSupportWhatsAppDisplay',
                                onTap: () =>
                                    _launchSupportLink(_kSupportWhatsAppUrl),
                              ),
                              _supportButton(
                                icon: Icons.email_outlined,
                                label: 'Email us',
                                onTap: () => _launchSupportLink(
                                    'mailto:$_kSupportEmail'),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
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
