import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';

/// Admin queue for support tickets escalated from the in-app help chat
/// ("other party is not responding" reports) and other sources.
/// Read + resolve: an admin marks a ticket IN_PROGRESS / RESOLVED / CLOSED
/// and can attach a resolution note.
class AdminSupportTicketsScreen extends StatefulWidget {
  const AdminSupportTicketsScreen({super.key});

  @override
  State<AdminSupportTicketsScreen> createState() =>
      _AdminSupportTicketsScreenState();
}

class _AdminSupportTicketsScreenState extends State<AdminSupportTicketsScreen> {
  static const _statuses = ['ALL', 'OPEN', 'IN_PROGRESS', 'RESOLVED', 'CLOSED'];

  String _filter = 'OPEN';
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _tickets = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      // NOTE: support_tickets.user_id references auth.users(id), NOT profiles
      // (0001) — there is no FK support_tickets→profiles, so a PostgREST
      // embed like profiles(...) fails with PGRST200. Fetch profiles
      // separately and join in Dart instead.
      // Filters must come before transformers (.order/.limit) — the filter
      // builder type does not expose them afterwards.
      var query = client.from('support_tickets').select('*');
      if (_filter != 'ALL') query = query.eq('status', _filter);
      final rows = await query.order('created_at', ascending: false).limit(200);
      final tickets = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      // Resolve reporter names/phones in one extra query.
      final userIds = tickets
          .map((t) => t['user_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, Map<String, dynamic>> profilesById = {};
      if (userIds.isNotEmpty) {
        final profiles = await client
            .from('profiles')
            .select('id, full_name, phone')
            .inFilter('id', userIds);
        for (final p in (profiles as List)) {
          final pm = Map<String, dynamic>.from(p as Map);
          profilesById[pm['id'] as String] = pm;
        }
      }
      for (final t in tickets) {
        t['reporter'] = profilesById[t['user_id']];
      }

      if (!mounted) return;
      setState(() {
        _tickets = tickets;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load tickets: $e';
      });
    }
  }

  Future<void> _updateStatus(Map<String, dynamic> ticket, String status) async {
    try {
      await Supabase.instance.client.from('support_tickets').update({
        'status': status,
        if (status == 'RESOLVED' || status == 'CLOSED')
          'resolved_at': DateTime.now().toIso8601String(),
      }).eq('id', ticket['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ticket marked $status')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e')));
    }
  }

  Future<void> _resolveWithNote(Map<String, dynamic> ticket) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resolve with note'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'What was done to resolve this?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Resolve')),
        ],
      ),
    );
    if (ok != true) return;
    final note = ctrl.text.trim();
    try {
      await Supabase.instance.client.from('support_tickets').update({
        'status': 'RESOLVED',
        'resolved_at': DateTime.now().toIso8601String(),
        if (note.isNotEmpty) 'resolution_note': note,
      }).eq('id', ticket['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ticket resolved')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not update: $e')));
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'OPEN':
        return AppTheme.error;
      case 'IN_PROGRESS':
        return AppTheme.warning;
      case 'RESOLVED':
        return AppTheme.success;
      default:
        return AppTheme.textMuted;
    }
  }

  String _fmtTime(String? iso) {
    if (iso == null) return '—';
    try {
      return DateFormat('MMM d, HH:mm').format(DateTime.parse(iso).toLocal());
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Support Tickets')),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              children: [
                for (final s in _statuses)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(s == 'ALL' ? 'All' : s.replaceAll('_', ' ')),
                      selected: _filter == s,
                      onSelected: (_) {
                        setState(() => _filter = s);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _error != null
                    ? Center(
                        child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!,
                            textAlign: TextAlign.center,
                            style: AppTheme.bodyMedium),
                      ))
                    : _tickets.isEmpty
                        ? const Center(
                            child: Text('No tickets here',
                                style: AppTheme.bodyMedium))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _tickets.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final t = _tickets[i];
                                final profile =
                                    t['reporter'] as Map<String, dynamic>?;
                                final status = t['status'] as String? ?? 'OPEN';
                                final source = t['source'] as String? ?? '';
                                return ExpansionTile(
                                  tilePadding: const EdgeInsets.symmetric(
                                      horizontal: 16),
                                  childrenPadding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 12),
                                  title: Text(
                                    t['subject'] as String? ?? '(no subject)',
                                    style: AppTheme.bodyStrong,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${_fmtTime(t['created_at'] as String?)}'
                                    '  •  ${status.replaceAll('_', ' ')}'
                                    '${source == 'HELP_CHAT' ? '  •  via help chat' : ''}',
                                    style: AppTheme.caption,
                                  ),
                                  trailing: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: _statusColor(status)
                                          .withOpacity(0.12),
                                      borderRadius:
                                          BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      status.replaceAll('_', ' '),
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: _statusColor(status)),
                                    ),
                                  ),
                                  children: [
                                    _detailRow('Reporter',
                                        profile?['full_name'] as String? ?? '—'),
                                    if ((t['reporter_phone'] as String?)
                                            ?.isNotEmpty ==
                                        true)
                                      _detailRow('Reporter phone',
                                          t['reporter_phone'] as String),
                                    _detailRow('Profile phone',
                                        (profile?['phone'] as String?)?.isNotEmpty == true
                                            ? profile!['phone'] as String
                                            : '—'),
                                    if ((t['provider_name'] as String?)
                                            ?.isNotEmpty ==
                                        true)
                                      _detailRow('Other party',
                                          t['provider_name'] as String),
                                    if ((t['provider_city'] as String?)
                                            ?.isNotEmpty ==
                                        true)
                                      _detailRow('City',
                                          t['provider_city'] as String),
                                    if ((t['order_number'] as String?)
                                            ?.isNotEmpty ==
                                        true)
                                      _detailRow('Order number',
                                          t['order_number'] as String),
                                    if ((t['description'] as String?)
                                            ?.isNotEmpty ==
                                        true) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                            t['description'] as String,
                                            style: AppTheme.bodyMedium),
                                      ),
                                    ],
                                    if ((t['resolution_note'] as String?)
                                            ?.isNotEmpty ==
                                        true) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                            'Note: ${t['resolution_note']}',
                                            style: AppTheme.caption),
                                      ),
                                    ],
                                    const SizedBox(height: 12),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        if (status == 'OPEN')
                                          OutlinedButton(
                                            onPressed: () => _updateStatus(
                                                t, 'IN_PROGRESS'),
                                            child: const Text('Start work'),
                                          ),
                                        if (status == 'OPEN' ||
                                            status == 'IN_PROGRESS')
                                          FilledButton(
                                            onPressed: () =>
                                                _resolveWithNote(t),
                                            child: const Text('Resolve…'),
                                          ),
                                        if (status == 'RESOLVED')
                                          OutlinedButton(
                                            onPressed: () =>
                                                _updateStatus(t, 'CLOSED'),
                                            child: const Text('Close'),
                                          ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: AppTheme.caption),
          ),
          Expanded(
            child: Text(value, style: AppTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
